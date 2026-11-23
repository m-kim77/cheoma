import Accelerate
import AVFoundation
import Foundation

/// whisper.cpp(whisper-cli)로 받아쓴다. 섞어 말한 한국어 · 영어 용어에 가장 정확했다.
/// 들은 소리를 16 kHz 모노로 모아 두었다가, 키를 떼면 whisper-cli를 한 번 돌린다.
/// M5 Max · large-v3-turbo q5_0에서 1–6초 말에 모델 읽기까지 0.35–0.42초가 걸린다.
/// whisper-server를 띄워 두면 0.12–0.15초지만 모델이 0.9 GB 메모리를 늘 차지해서, 말할 때마다 whisper-cli를 띄운다.
/// 한꺼번에 옮기므로 중간 글(onPartial)은 알리지 않는다
final class WhisperEngine: DictationEngine, @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// 이보다 짧은 소리는 뒤에 조용한 소리를 붙인다 (whisper.cpp는 1초보다 짧은 입력을 건너뛸 수 있다)
    static let minimumSeconds = 1.0
    /// 이보다 긴 소리는 버린다 (두 번 눌러 켜 둔 채 잊은 경우)
    static let maximumSeconds = 300.0
    /// whisper-cli가 쓸 CPU 스레드 (계산은 대부분 GPU가 한다)
    static let threads = 4

    /// 도구와 모델을 찾는 곳 (테스트에서 바꾼다)
    struct Locations {
        var toolDirectories: [String]
        var modelDirectories: [URL]

        static var standard: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Locations(toolDirectories: WhisperEngine.toolDirectories(path: ProcessInfo.processInfo.environment["PATH"]),
                             modelDirectories: WhisperEngine.modelDirectories(home: home))
        }
    }

    let locations: Locations

    private let lock = NSLock()
    private var isListening = false
    private var converter: StreamingAudioConverter?
    private var samples: [Float] = []
    private var listeningOptions: DictationEngineOptions?
    /// cancel할 때마다 늘린다. 돌던 whisper-cli의 결과를 버린다
    private var generation = 0
    /// 돌고 있는 whisper-cli (cancel · shutdown이 끝낸다)
    private var running: [Process] = []
    /// 디스크 캐시에 올려 둔 모델 파일
    private var warmedModelPath: String?

    private var whisperFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
    }

    init(locations: Locations = .standard) {
        self.locations = locations
    }

    deinit {
        for process in running where process.isRunning { process.terminate() }
    }

    // MARK: 쓸 수 있는지

    func availability(options: DictationEngineOptions) async -> DictationAvailability {
        switch resolve(options) {
        case .success: return .ready
        case .failure(let error): return .unavailable(error.message)
        }
    }

    /// whisper-cli와 모델 파일을 찾는다. 없으면 화면에 보여 줄 이유
    private func resolve(_ options: DictationEngineOptions) -> Result<(tool: String, model: URL), DictationError> {
        guard let tool = Self.findTool("whisper-cli", in: locations.toolDirectories) else {
            return .failure(.engineUnavailable("whisper-cli가 없습니다. brew install whisper-cpp로 설치하십시오"))
        }
        let explicit = options.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return .failure(.engineUnavailable("whisper 모델 파일이 없습니다: \(explicit)"))
            }
            return .success((tool, url))
        }
        guard let model = Self.findModel(in: locations.modelDirectories) else {
            return .failure(.engineUnavailable("whisper 모델 파일(ggml-*.bin)을 찾을 수 없습니다. ~/models에 넣거나 설정에서 선택하십시오"))
        }
        return .success((tool, model))
    }

    // MARK: 미리 올려 두기

    /// 모델 파일을 한 번 읽어 디스크 캐시에 올려 둔다. 첫 받아쓰기에서 모델 읽는 시간이 줄어든다
    func prepare(options: DictationEngineOptions) async {
        guard case .success(let found) = resolve(options) else { return }
        let path = found.model.path
        let shouldWarm = lock.withLock { () -> Bool in
            guard warmedModelPath != path else { return false }
            warmedModelPath = path
            return true
        }
        guard shouldWarm else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                if let handle = FileHandle(forReadingAtPath: path) {
                    while let chunk = try? handle.read(upToCount: 16 << 20), !chunk.isEmpty {}
                    try? handle.close()
                }
                continuation.resume()
            }
        }
    }

    /// 돌고 있는 whisper-cli를 끝낸다 (앱을 끝낼 때 · 엔진을 바꾸거나 끌 때)
    func shutdown() {
        cancel()
    }

    // MARK: 듣기

    func begin(format: AVAudioFormat, options: DictationEngineOptions,
               onPartial: @escaping @Sendable (String) -> Void) async throws {
        if case .failure(let error) = resolve(options) { throw error }
        guard let converter = StreamingAudioConverter(from: format, to: whisperFormat) else {
            throw DictationError.engineUnavailable("오디오를 whisper 형식으로 변환하지 못했습니다")
        }
        lock.withLock {
            self.converter = converter
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(Int(Self.sampleRate * 30))
            listeningOptions = options
            isListening = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, let converter, let converted = converter.convert(buffer) else { return }
        appendSamples(converted)
    }

    /// 잠근 채로 부른다
    private func appendSamples(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let room = Int(Self.sampleRate * Self.maximumSeconds) - samples.count
        let count = min(Int(buffer.frameLength), room)
        guard count > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
    }

    func finish() async throws -> String {
        let taken = lock.withLock { () -> (audio: [Float], options: DictationEngineOptions, generation: Int)? in
            guard isListening, let options = listeningOptions else { return nil }
            if let tail = converter?.flush() { appendSamples(tail) }
            let audio = samples
            isListening = false
            converter = nil
            samples = []
            listeningOptions = nil
            return (audio, options, generation)
        }
        guard let taken else { return "" }
        // 조용하기만 하면 whisper가 지어낸 말("시청해 주셔서 감사합니다")을 내놓는다. 돌리지 않는다
        guard Self.hasSpeechEnergy(taken.audio) else { return "" }
        let found: (tool: String, model: URL)
        switch resolve(taken.options) {
        case .success(let value): found = value
        case .failure(let error): throw error
        }

        let audio = Self.padded(taken.audio, sampleRate: Self.sampleRate, minimumSeconds: Self.minimumSeconds)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Cheoma-dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try Self.wavData(samples: audio, sampleRate: Int(Self.sampleRate)).write(to: file)
        } catch {
            throw DictationError.engineUnavailable("녹음을 저장하지 못했습니다")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let arguments = Self.cliArguments(model: found.model.path, audio: file.path,
                                          language: Self.whisperLanguage(for: taken.options.localeIdentifier),
                                          prompt: Self.prompt(from: taken.options.vocabulary), threads: Self.threads)
        let seconds = Double(audio.count) / Self.sampleRate
        let output = try await run(found.tool, arguments, timeout: 15 + seconds, generation: taken.generation)
        return Self.cleanTranscript(output)
    }

    func cancel() {
        let processes = lock.withLock { () -> [Process] in
            generation += 1
            isListening = false
            converter = nil
            samples = []
            listeningOptions = nil
            return running
        }
        for process in processes where process.isRunning { process.terminate() }
    }

    // MARK: whisper-cli 돌리기

    private func run(_ tool: String, _ arguments: [String], timeout: TimeInterval, generation: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(with: Result { try runBlocking(tool, arguments, timeout: timeout, generation: generation) })
            }
        }
    }

    private func runBlocking(_ tool: String, _ arguments: [String], timeout: TimeInterval, generation: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // 이미 취소됐으면 띄우지 않는다. 띄운 것은 cancel이 끝낼 수 있게 적어 둔다
        let started = lock.withLock { () -> Bool in
            guard self.generation == generation else { return false }
            do { try process.run() } catch { return false }
            running.append(process)
            return true
        }
        guard started else {
            if self.lock.withLock({ self.generation }) != generation { throw CancellationError() }
            throw DictationError.engineUnavailable("whisper-cli를 실행하지 못했습니다")
        }
        defer { lock.withLock { running.removeAll { $0 === process } } }

        // 출력이 파이프 버퍼보다 크면 자식이 쓰기에서 멈추므로 기다리는 동안 따로 읽는다 (stderr에는 Metal 초기화 기록이 많다)
        let output = PipeReader(outPipe.fileHandleForReading)
        let errors = PipeReader(errPipe.fileHandleForReading)
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        let text = output.text(waitingUntil: .now() + 1)
        let errorText = errors.text(waitingUntil: .now() + 0.5)

        if lock.withLock({ self.generation }) != generation { throw CancellationError() }
        if timedOut { throw DictationError.engineUnavailable("whisper 처리 시간 초과") }
        guard process.terminationStatus == 0 else {
            let reason = Self.lastMeaningfulLine(errorText) ?? "종료 코드 \(process.terminationStatus)"
            throw DictationError.engineUnavailable("whisper-cli 실패: \(reason)")
        }
        return text
    }

    /// 파이프를 끝까지(EOF) 읽어서 모아 둔다
    private final class PipeReader: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    lock.withLock { data.append(chunk) }
                }
                done.signal()
            }
        }

        func text(waitingUntil deadline: DispatchTime) -> String {
            _ = done.wait(timeout: deadline)
            return lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}

// MARK: - 찾기 · 인자 · 글 다듬기 (테스트에서도 쓴다)

extension WhisperEngine {
    /// Homebrew 자리를 먼저 보고 PATH를 본다 (Finder에서 연 앱의 PATH에는 Homebrew가 없다)
    static func toolDirectories(path: String?) -> [String] {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin"]
        for item in (path ?? "").split(separator: ":").map(String.init) where !item.isEmpty && !directories.contains(item) {
            directories.append(item)
        }
        return directories
    }

    static func findTool(_ name: String, in directories: [String]) -> String? {
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 모델 파일을 찾는 곳. 앞쪽이 먼저다
    static func modelDirectories(home: URL) -> [URL] {
        [home.appendingPathComponent("models", isDirectory: true),
         home.appendingPathComponent("Library/Application Support/Cheoma/models", isDirectory: true),
         home.appendingPathComponent(".cache/whisper", isDirectory: true)]
    }

    /// ggml-*.bin 가운데 가장 나은 것: large-v3-turbo > large-v3 > large > medium > small > base > tiny.
    /// 영어 전용(.en) 모델과 음성 구간 모델(vad)은 한국어에 못 쓰므로 맨 뒤로 보내거나 뺀다
    static func findModel(in directories: [URL]) -> URL? {
        var best: (rank: Int, order: Int, url: URL)?
        var order = 0
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() {
                let lower = name.lowercased()
                guard lower.hasPrefix("ggml-"), lower.hasSuffix(".bin"), !lower.contains("vad"), !lower.contains("silero") else { continue }
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
                let rank = modelRank(lower)
                order += 1
                if best == nil || rank < best!.rank || (rank == best!.rank && order < best!.order) {
                    best = (rank, order, url)
                }
            }
        }
        return best?.url
    }

    static func modelRank(_ name: String) -> Int {
        let sizes = ["large-v3-turbo", "large-v3", "large", "medium", "small", "base", "tiny"]
        var rank = sizes.firstIndex { name.contains($0) } ?? sizes.count
        if name.contains(".en.") || name.hasSuffix(".en.bin") || name.contains(".en-") { rank += 10 }
        return rank
    }

    /// "ko-KR" → "ko". 모르면 whisper가 알아서 고르게 "auto"
    static func whisperLanguage(for localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let code = Locale(identifier: trimmed).language.languageCode?.identifier.lowercased(),
              !code.isEmpty else { return "auto" }
        // whisper가 쓰는 이름이 다른 몇 언어
        switch code {
        case "nb", "nn": return "no"
        case "fil": return "tl"
        case "jv": return "jw"
        case "iw": return "he"
        default: return code
        }
    }

    /// 용어를 쉼표로 이은 첫 프롬프트. whisper가 이런 낱말이 나올 것을 알고 영어 철자로 쓴다.
    /// whisper.cpp는 프롬프트의 뒤쪽 토큰만(224개까지) 쓰고 앞쪽을 버린다. 그래서 앞의 용어(사용자 것)부터 고르되
    /// 토큰 수를 UTF-8 바이트로 어림해(토큰 하나에 2.5바이트쯤, 한글은 더 든다) 그 안에서만 넣고,
    /// 거꾸로 이어서 먼저 고른 용어가 잘리지 않는 끝(소리에 가장 가까운 곳)에 오게 한다
    static func prompt(from vocabulary: [String], maxBytes: Int = 500) -> String {
        var seen = Set<String>()
        var terms: [String] = []
        var bytes = 1
        for raw in vocabulary {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let added = term.utf8.count + (terms.isEmpty ? 0 : 2)
            guard bytes + added <= maxBytes else { break }
            terms.append(term)
            bytes += added
        }
        return terms.isEmpty ? "" : terms.reversed().joined(separator: ", ") + "."
    }

    static func cliArguments(model: String, audio: String, language: String, prompt: String, threads: Int) -> [String] {
        // -nt: 시각 없이 글만, -np: 결과 말고는 아무것도 찍지 않는다
        var arguments = ["-m", model, "-f", audio, "-l", language, "-nt", "-np", "-t", String(threads)]
        if !prompt.isEmpty { arguments += ["--prompt", prompt] }
        return arguments
    }

    /// whisper 출력에서 말이 아닌 것을 지운다: [BLANK_AUDIO] 같은 대괄호 표시, (음악) · (박수) 같은 소리 표시, ♪.
    /// 줄(구간)은 빈칸 하나로 잇는다
    static func cleanTranscript(_ output: String) -> String {
        var pieces: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine
            // 시각 표시 "[00:00:00.000 --> 00:00:02.000]"와 [BLANK_AUDIO] 같은 표시
            line = line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
            line = removeSoundLabels(in: line)
            line = line.replacingOccurrences(of: #"[♪♫♬♩]"#, with: " ", options: .regularExpression)
            let tidy = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !tidy.isEmpty { pieces.append(tidy) }
        }
        return pieces.joined(separator: " ")
    }

    /// 소리를 가리키는 낱말이 든 짧은 괄호 "(음악)", "(웃음)", "(upbeat music)"를 지운다. 말한 괄호는 남긴다
    private static func removeSoundLabels(in line: String) -> String {
        let soundWords = ["음악", "박수", "웃음", "침묵", "기침", "한숨", "숨소리", "잡음", "소음", "노래", "음향", "효과음", "무음",
                          "music", "applause", "laugh", "silence", "noise", "inaudible", "blank", "no speech", "sigh", "cough"]
        guard let regex = try? NSRegularExpression(pattern: #"[(（]([^()（）]*)[)）]"#) else { return line }
        var result = line
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let content = result[inner].lowercased().trimmingCharacters(in: .whitespaces)
            let words = content.split(whereSeparator: \.isWhitespace).count
            if content.isEmpty || (words <= 4 && soundWords.contains(where: { content.contains($0) })) {
                result.replaceSubrange(whole, with: " ")
            }
        }
        return result
    }

    /// 30 ms 구간 가운데 하나라도 RMS가 기준(약 -46 dBFS)을 넘으면 말소리가 있다고 본다
    static func hasSpeechEnergy(_ samples: [Float], sampleRate: Double = sampleRate, threshold: Float = 0.005) -> Bool {
        let window = max(1, Int(sampleRate * 0.03))
        guard !samples.isEmpty else { return false }
        return samples.withUnsafeBufferPointer { pointer -> Bool in
            var start = 0
            while start < pointer.count {
                let count = min(window, pointer.count - start)
                var rms: Float = 0
                vDSP_rmsqv(pointer.baseAddress! + start, 1, &rms, vDSP_Length(count))
                if rms >= threshold { return true }
                start += window
            }
            return false
        }
    }

    /// 짧은 소리 뒤에 조용한 소리를 붙여 최소 길이를 맞춘다
    static func padded(_ samples: [Float], sampleRate: Double, minimumSeconds: Double) -> [Float] {
        let minimum = Int(sampleRate * minimumSeconds)
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    /// 16비트 PCM 모노 WAV. whisper-cli가 바로 읽는다
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))              // fmt 덩어리 크기
        append(UInt16(1))               // PCM
        append(UInt16(1))               // 채널
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // 초당 바이트
        append(UInt16(2))               // 프레임당 바이트
        append(UInt16(16))              // 샘플당 비트
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        let pcm = samples.map { sample -> Int16 in
            let clipped = max(-1, min(1, sample))
            return Int16((clipped * Float(Int16.max)).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// 오류 출력에서 마지막으로 뜻 있는 줄 (Metal 초기화 기록은 건너뛴다)
    static func lastMeaningfulLine(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("ggml_") && !$0.hasPrefix("load_backend") && !$0.hasPrefix("whisper_") }
        return lines.last.map { String($0.prefix(160)) }
    }
}

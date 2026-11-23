import AVFoundation
import XCTest
@testable import Cheoma

/// 마이크와 같은 모양의 버퍼 (Float32, 채널 따로)
private func sineBuffer(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, seconds: Double,
                        amplitude: Float = 0.2, frequency: Double = 440) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let data = buffer.floatChannelData![channel]
        for index in 0..<Int(frames) {
            data[index] = amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }
    return buffer
}

/// 버퍼를 100 ms씩 잘라 마이크처럼 넣는다
private func feed(_ buffer: AVAudioPCMBuffer, to engine: DictationEngine) {
    let chunk = AVAudioFrameCount(buffer.format.sampleRate / 10)
    var start: AVAudioFrameCount = 0
    while start < buffer.frameLength {
        let count = min(chunk, buffer.frameLength - start)
        let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count)!
        piece.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            piece.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + Int(start), count: Int(count))
        }
        engine.append(piece)
        start += count
    }
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheoma-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class WhisperHelperTests: XCTestCase {
    func testLanguageFromLocale() {
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "ko-KR"), "ko")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "ko_KR"), "ko")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "en-US"), "en")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "ja-JP"), "ja")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "zh-Hans-CN"), "zh")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: "nb-NO"), "no")
        XCTAssertEqual(WhisperEngine.whisperLanguage(for: ""), "auto")
    }

    func testFindsBestModelAcrossDirectories() throws {
        let first = try temporaryDirectory("models-a")
        let second = try temporaryDirectory("models-b")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        for name in ["ggml-small.bin", "ggml-tiny.en.bin", "ggml-silero-v5.1.2.bin", "notes.txt", "model.bin"] {
            FileManager.default.createFile(atPath: first.appendingPathComponent(name).path, contents: Data([1]))
        }
        for name in ["ggml-base.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3.bin"] {
            FileManager.default.createFile(atPath: second.appendingPathComponent(name).path, contents: Data([1]))
        }
        let missing = first.appendingPathComponent("nothing-here", isDirectory: true)
        XCTAssertEqual(WhisperEngine.findModel(in: [missing, first, second])?.lastPathComponent, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(WhisperEngine.findModel(in: [first])?.lastPathComponent, "ggml-small.bin")
        XCTAssertNil(WhisperEngine.findModel(in: [missing]))

        // 같은 크기면 앞 폴더 것
        FileManager.default.createFile(atPath: first.appendingPathComponent("ggml-large-v3-turbo.bin").path, contents: Data([1]))
        XCTAssertEqual(WhisperEngine.findModel(in: [first, second])?.deletingLastPathComponent().standardizedFileURL,
                       first.standardizedFileURL)
        // 영어 전용 모델은 다른 것이 없을 때만
        XCTAssertLessThan(WhisperEngine.modelRank("ggml-tiny.bin"), WhisperEngine.modelRank("ggml-large-v3.en.bin"))
    }

    func testStandardPlaces() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(WhisperEngine.modelDirectories(home: home).map(\.path),
                       ["/Users/someone/models", "/Users/someone/Library/Application Support/Cheoma/models",
                        "/Users/someone/.cache/whisper"])
        XCTAssertEqual(WhisperEngine.toolDirectories(path: "/usr/bin:/opt/homebrew/bin::/bin"),
                       ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        XCTAssertEqual(WhisperEngine.toolDirectories(path: nil), ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    func testCleansWhisperOutput() {
        XCTAssertEqual(WhisperEngine.cleanTranscript(" [BLANK_AUDIO]\n"), "")
        XCTAssertEqual(WhisperEngine.cleanTranscript("\n (음악)\n 안녕하세요.\n"), "안녕하세요.")
        XCTAssertEqual(WhisperEngine.cleanTranscript("[00:00:00.000 --> 00:00:02.000]   GitHub에 push하고\n[00:00:02.000 --> 00:00:03.000]  PR 올려줘\n"),
                       "GitHub에 push하고 PR 올려줘")
        XCTAssertEqual(WhisperEngine.cleanTranscript("(웃음) 좋아요 (upbeat music)"), "좋아요")
        XCTAssertEqual(WhisperEngine.cleanTranscript("♪ 노래 ♪"), "노래")
        XCTAssertEqual(WhisperEngine.cleanTranscript("（박수） 네"), "네")
        // 말한 괄호는 남긴다
        XCTAssertEqual(WhisperEngine.cleanTranscript(" 함수(foo) 호출해 줘"), "함수(foo) 호출해 줘")
        XCTAssertEqual(WhisperEngine.cleanTranscript(" 이건 (아주 긴 설명이고 음악 이야기는 아니에요) 그래요"),
                       "이건 (아주 긴 설명이고 음악 이야기는 아니에요) 그래요")
    }

    func testPromptAndArguments() {
        XCTAssertEqual(WhisperEngine.prompt(from: []), "")
        // 앞의 것(사용자 용어)이 whisper.cpp가 남기는 끝에 온다
        XCTAssertEqual(WhisperEngine.prompt(from: [" GitHub ", "push", "github", "", "Claude  Code"]), "Claude Code, push, GitHub.")
        let long = (0..<200).map { "term\($0)" }
        let prompt = WhisperEngine.prompt(from: long, maxBytes: 50)
        XCTAssertLessThanOrEqual(prompt.utf8.count, 51)
        // 앞쪽 용어부터 고르고, whisper.cpp가 잘라 내지 않는 끝에 둔다
        XCTAssertTrue(prompt.hasSuffix("term1, term0."), prompt)
        XCTAssertFalse(prompt.contains("term199"))

        let arguments = WhisperEngine.cliArguments(model: "/m/ggml.bin", audio: "/t/a.wav", language: "ko", prompt: "GitHub.", threads: 4)
        XCTAssertEqual(arguments, ["-m", "/m/ggml.bin", "-f", "/t/a.wav", "-l", "ko", "-nt", "-np", "-t", "4", "--prompt", "GitHub."])
        XCTAssertFalse(WhisperEngine.cliArguments(model: "m", audio: "a", language: "ko", prompt: "", threads: 4).contains("--prompt"))
    }

    /// 한글 이름 40개를 넣어도 사용자 용어가 잘리지 않는 뒤쪽에 있고 바이트 어림 안에 든다 (토큰 224개쯤)
    func testPromptKeepsUserTermsAtTheEnd() {
        let names = ["김민준", "이서연", "박지호", "최수아", "정예준", "강하은", "조도윤", "윤지우"]
        let user = (0..<40).map { names[$0 % names.count] + "\($0)" }
        let glossary = DictationGlossary(userText: user.joined(separator: "\n"))
        let prompt = WhisperEngine.prompt(from: glossary.vocabulary)
        XCTAssertLessThanOrEqual(prompt.utf8.count, 500)
        XCTAssertTrue(prompt.hasSuffix("김민준0."), String(prompt.suffix(40)))
        let firstUserTerm = prompt.range(of: "김민준0")!.lowerBound
        if let builtIn = prompt.range(of: "Docker") { XCTAssertLessThan(builtIn.lowerBound, firstUserTerm) }
    }

    func testWavData() throws {
        let data = WhisperEngine.wavData(samples: [0, 1, -1, 2, 0.5], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 10)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            data[offset..<(offset + MemoryLayout<T>.size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }.littleEndian
        }
        XCTAssertEqual(integer(4, UInt32.self), 36 + 10)
        XCTAssertEqual(integer(20, UInt16.self), 1, "PCM")
        XCTAssertEqual(integer(22, UInt16.self), 1, "모노")
        XCTAssertEqual(integer(24, UInt32.self), 16_000)
        XCTAssertEqual(integer(34, UInt16.self), 16)
        XCTAssertEqual(integer(40, UInt32.self), 10)
        XCTAssertEqual([44, 46, 48, 50, 52].map { integer($0, Int16.self) }, [0, 32767, -32767, 32767, 16384])

        // AVAudioFile이 그대로 읽는다
        let directory = try temporaryDirectory("wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.wav")
        try WhisperEngine.wavData(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 16_000)
    }

    func testSpeechEnergyAndPadding() {
        XCTAssertFalse(WhisperEngine.hasSpeechEnergy([]))
        XCTAssertFalse(WhisperEngine.hasSpeechEnergy([Float](repeating: 0, count: 16_000)))
        XCTAssertFalse(WhisperEngine.hasSpeechEnergy([Float](repeating: 0.001, count: 16_000)))
        var quietThenLoud = [Float](repeating: 0, count: 16_000)
        for index in 8_000..<8_800 { quietThenLoud[index] = index % 2 == 0 ? 0.1 : -0.1 }
        XCTAssertTrue(WhisperEngine.hasSpeechEnergy(quietThenLoud))

        XCTAssertEqual(WhisperEngine.padded([1, 1], sampleRate: 10, minimumSeconds: 1), [1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(WhisperEngine.padded([Float](repeating: 1, count: 12), sampleRate: 10, minimumSeconds: 1).count, 12)
    }
}

final class StreamingAudioConverterTests: XCTestCase {
    private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// 48 kHz 마이크 버퍼를 100 ms씩 넣으면 16 kHz로 거의 같은 길이가 나온다 (변환기 지연은 flush로 거둔다)
    func testResamples48kTo16k() throws {
        let source = sineBuffer(seconds: 1)
        let converter = try XCTUnwrap(StreamingAudioConverter(from: source.format, to: whisperFormat))
        var frames: AVAudioFrameCount = 0
        var peak: Float = 0
        let chunk: AVAudioFrameCount = 4_800
        for start in stride(from: 0, to: source.frameLength, by: Int(chunk)) {
            let piece = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: chunk)!
            piece.frameLength = chunk
            piece.floatChannelData![0].update(from: source.floatChannelData![0] + Int(start), count: Int(chunk))
            if let output = converter.convert(piece) {
                XCTAssertEqual(output.format, whisperFormat)
                frames += output.frameLength
                for index in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][index])) }
            }
        }
        if let tail = converter.flush() { frames += tail.frameLength }
        XCTAssertEqual(Double(frames), 16_000, accuracy: 64)
        XCTAssertEqual(peak, 0.2, accuracy: 0.02, "소리 크기가 그대로다")
    }

    func testDownmixesStereoAndConvertsToInt16() throws {
        let source = sineBuffer(sampleRate: 44_100, channels: 2, seconds: 0.5)
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let converter = try XCTUnwrap(StreamingAudioConverter(from: source.format, to: int16))
        let output = try XCTUnwrap(converter.convert(source))
        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertEqual(output.format.commonFormat, .pcmFormatInt16)
        // 변환기가 잡고 있던 끝부분은 flush로 나온다
        let tail = converter.flush()?.frameLength ?? 0
        XCTAssertEqual(Double(output.frameLength + tail), 8_000, accuracy: 64)
    }

    func testSameFormatIsCopied() throws {
        let source = sineBuffer(sampleRate: 16_000, seconds: 0.1)
        let converter = try XCTUnwrap(StreamingAudioConverter(from: source.format, to: whisperFormat))
        let output = try XCTUnwrap(converter.convert(source))
        XCTAssertFalse(output === source, "마이크 버퍼를 그대로 들고 있지 않는다")
        XCTAssertEqual(output.frameLength, source.frameLength)
        XCTAssertEqual(output.floatChannelData![0][10], source.floatChannelData![0][10])
        XCTAssertNil(converter.flush())
    }

    /// 듣는 중에 마이크 형식이 바뀌어도 이어서 바꾼다
    func testFollowsFormatChange() throws {
        let first = sineBuffer(sampleRate: 48_000, seconds: 0.1)
        let converter = try XCTUnwrap(StreamingAudioConverter(from: first.format, to: whisperFormat))
        XCTAssertNotNil(converter.convert(first))
        let second = sineBuffer(sampleRate: 24_000, seconds: 0.1)
        let output = try XCTUnwrap(converter.convert(second))
        XCTAssertEqual(output.format, whisperFormat)
        XCTAssertEqual(converter.inputFormat, second.format)
    }
}

/// 가짜 whisper-cli(셸 스크립트)로 begin → append → finish 전체를 확인한다
final class WhisperEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try temporaryDirectory("whisper")
        FileManager.default.createFile(atPath: directory.appendingPathComponent("ggml-test.bin").path, contents: Data([1]))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func installTool(_ body: String) throws {
        let url = directory.appendingPathComponent("whisper-cli")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeEngine() -> WhisperEngine {
        WhisperEngine(locations: .init(toolDirectories: [directory.path], modelDirectories: [directory]))
    }

    private let options = DictationEngineOptions(localeIdentifier: "ko-KR", vocabulary: ["GitHub", "Claude Code"], whisperModelPath: "")

    func testAvailabilityReasons() async throws {
        let engine = makeEngine()
        guard case .unavailable(let noTool) = await engine.availability(options: options) else { return XCTFail() }
        XCTAssertTrue(noTool.contains("whisper-cli"))

        try installTool("exit 0")
        let ready = await engine.availability(options: options)
        XCTAssertEqual(ready, .ready)

        var explicit = options
        explicit.whisperModelPath = directory.appendingPathComponent("missing.bin").path
        guard case .unavailable(let noModel) = await engine.availability(options: explicit) else { return XCTFail() }
        XCTAssertTrue(noModel.contains("missing.bin"))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("ggml-test.bin"))
        guard case .unavailable(let none) = await engine.availability(options: options) else { return XCTFail() }
        XCTAssertTrue(none.contains("ggml"))
    }

    func testTranscribesThroughTool() async throws {
        // 받은 인자와 소리 파일을 남기고, whisper처럼 앞 빈칸 · [BLANK_AUDIO]가 섞인 글을 낸다
        try installTool("""
        dir="$(dirname "$0")"
        printf '%s\\n' "$@" > "$dir/args.txt"
        cp "$4" "$dir/input.wav"
        echo "ggml_metal_init: 기록" >&2
        printf ' [BLANK_AUDIO]\\n 안녕하세요.\\n'
        """)
        let engine = makeEngine()
        let speech = sineBuffer(seconds: 0.5)
        try await engine.begin(format: speech.format, options: options) { _ in XCTFail("whisper는 중간 글이 없다") }
        feed(speech, to: engine)
        let text = try await engine.finish()
        XCTAssertEqual(text, "안녕하세요.")

        let arguments = try String(contentsOf: directory.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments[0...1], ["-m", directory.appendingPathComponent("ggml-test.bin").path])
        XCTAssertTrue(arguments.contains("ko"))
        XCTAssertEqual(arguments.last, "Claude Code, GitHub.")
        // 0.5초는 1초로 늘려서 16 kHz 모노로 넘긴다
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("input.wav"))
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 64)
        // 임시 소리 파일은 지운다
        XCTAssertFalse(FileManager.default.fileExists(atPath: arguments[3]))
    }

    func testSilenceSkipsTool() async throws {
        try installTool("touch \"$(dirname \"$0\")/ran\"; echo '시청해 주셔서 감사합니다.'")
        let engine = makeEngine()
        let silence = sineBuffer(seconds: 1, amplitude: 0)
        try await engine.begin(format: silence.format, options: options) { _ in }
        feed(silence, to: engine)
        let text = try await engine.finish()
        XCTAssertEqual(text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
    }

    func testReportsToolFailure() async throws {
        try installTool("echo 'ggml_metal_init: 기록' >&2; echo 'error: failed to open model' >&2; exit 3")
        let engine = makeEngine()
        let speech = sineBuffer(seconds: 0.3)
        try await engine.begin(format: speech.format, options: options) { _ in }
        feed(speech, to: engine)
        do {
            _ = try await engine.finish()
            XCTFail("실패해야 한다")
        } catch let error as DictationError {
            XCTAssertTrue(error.message.contains("failed to open model"), error.message)
        }
    }

    func testCancelStopsRunningTool() async throws {
        // exec: 셸 대신 sleep이 그 프로세스가 되어, 끝내면 남는 것이 없다 (whisper-cli도 프로세스 하나다)
        try installTool("exec sleep 5")
        let engine = makeEngine()
        let speech = sineBuffer(seconds: 0.3)
        try await engine.begin(format: speech.format, options: options) { _ in }
        feed(speech, to: engine)
        let started = Date()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            DictationEngines.shutdown(engine)
        }
        do {
            _ = try await engine.finish()
            XCTFail("버린 결과를 돌려주면 안 된다")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        }
    }

    func testFinishWithoutBeginAndCancelledListening() async throws {
        try installTool("echo 글")
        let engine = makeEngine()
        let empty = try await engine.finish()
        XCTAssertEqual(empty, "")
        let speech = sineBuffer(seconds: 0.3)
        try await engine.begin(format: speech.format, options: options) { _ in }
        feed(speech, to: engine)
        engine.cancel()
        let afterCancel = try await engine.finish()
        XCTAssertEqual(afterCancel, "")
    }
}

final class AppleSpeechHelperTests: XCTestCase {
    func testContextualStrings() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 이상") }
        let picked = AppleSpeechEngine.contextualStrings(from: ["GitHub", " Claude  Code ", "github", "", "fix crash on launch", "tmux"])
        XCTAssertEqual(picked, ["GitHub", "Claude Code", "tmux"])
        let many = AppleSpeechEngine.contextualStrings(from: (0..<150).map { "term\($0)" })
        XCTAssertEqual(many.count, 100)
        XCTAssertEqual(many.first, "term0")
    }

    func testJoiningText() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 이상") }
        XCTAssertEqual(AppleSpeechEngine.join("안녕하세요.", "반가워요", withSpace: true), "안녕하세요. 반가워요")
        XCTAssertEqual(AppleSpeechEngine.join("안녕하세요. ", "반가워요", withSpace: true), "안녕하세요. 반가워요")
        XCTAssertEqual(AppleSpeechEngine.join("こんにちは。", "元気", withSpace: false), "こんにちは。元気")
        XCTAssertEqual(AppleSpeechEngine.join("", "글", withSpace: true), "글")
        XCTAssertEqual(AppleSpeechEngine.tidy("  GitHub에   push  "), "GitHub에 push")
        XCTAssertTrue(AppleSpeechEngine.joinsWithSpace(Locale(identifier: "ko-KR")))
        XCTAssertFalse(AppleSpeechEngine.joinsWithSpace(Locale(identifier: "ja-JP")))
        XCTAssertTrue(AppleSpeechEngine.sameLocale(Locale(identifier: "ko_KR"), Locale(identifier: "ko-KR")))
    }

    /// 결과 흐름이 끝나지 않아도 정한 시간만 기다린다
    func testBoundedWaitReturnsOnTime() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 이상") }
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let endless = Task { for await _ in stream {} }
        let start = Date()
        await AppleSpeechEngine.wait(for: endless, upTo: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        continuation.finish()
        let quick = Task {}
        let quickStart = Date()
        await AppleSpeechEngine.wait(for: quick, upTo: 5)
        XCTAssertLessThan(Date().timeIntervalSince(quickStart), 1.0)
    }

    func testFactory() {
        if #available(macOS 26.0, *) {
            XCTAssertTrue(DictationEngines.make(.apple) is AppleSpeechEngine)
        } else {
            XCTAssertNil(DictationEngines.make(.apple))
        }
        XCTAssertTrue(DictationEngines.make(.whisper) is WhisperEngine)
    }

    func testCommandArguments() {
        let parsed = DictationTestCommand.parse(["a.wav", "--engine", "whisper", "--vocab", "GitHub, Claude Code ,", "b.wav",
                                                 "--locale", "en-US", "--fast", "--cancel-at", "1.5"])
        XCTAssertEqual(parsed.files, ["a.wav", "b.wav"])
        XCTAssertEqual(parsed.engine, .whisper)
        XCTAssertEqual(parsed.vocabulary, ["GitHub", "Claude Code"])
        XCTAssertEqual(parsed.localeIdentifier, "en-US")
        XCTAssertFalse(parsed.paced)
        XCTAssertEqual(parsed.cancelAt, 1.5)
        XCTAssertEqual(DictationTestCommand.parse(["x.wav"]).engine, .apple)
    }
}

/// 실제 엔진으로 짧은 말을 옮겨 본다. 언어 모델 · whisper · 한국어 목소리가 없으면 건너뛴다
final class DictationEngineIntegrationTests: XCTestCase {
    private static var clip: URL?

    /// `say`로 "안녕하세요"를 파일로 만든다 (스피커로 내지 않는다)
    private func speechClip() throws -> URL {
        if let clip = Self.clip { return clip }
        let directory = try temporaryDirectory("say")
        let url = directory.appendingPathComponent("hello.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Yuna", "-o", url.path, "안녕하세요. 반갑습니다."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw XCTSkip("say를 쓸 수 없어요") }
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("한국어 목소리(Yuna)가 없어요")
        }
        Self.clip = url
        return url
    }

    private func transcribe(_ engine: DictationEngine, options: DictationEngineOptions) async throws -> (String, Int) {
        let file = try AVAudioFile(forReading: try speechClip())
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let counter = PartialCounter()
        try await engine.begin(format: buffer.format, options: options) { _ in counter.add() }
        feed(buffer, to: engine)
        let text = try await engine.finish()
        return (text, counter.count)
    }

    func testAppleSpeech() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 이상") }
        let engine = AppleSpeechEngine()
        defer { engine.shutdown() }
        let options = DictationEngineOptions(localeIdentifier: "ko-KR", vocabulary: [], whisperModelPath: "")
        guard await engine.availability(options: options) == .ready else { throw XCTSkip("한국어 Apple 음성 모델이 없어요") }
        let (text, partials) = try await transcribe(engine, options: options)
        XCTAssertTrue(text.contains("안녕하세요"), text)
        XCTAssertGreaterThan(partials, 0)
        // 다음 듣기도 된다 (분석기를 새로 쓴다)
        let (again, _) = try await transcribe(engine, options: options)
        XCTAssertTrue(again.contains("안녕하세요"), again)
    }

    func testWhisper() async throws {
        let engine = WhisperEngine()
        defer { engine.shutdown() }
        let options = DictationEngineOptions(localeIdentifier: "ko-KR", vocabulary: [], whisperModelPath: "")
        guard await engine.availability(options: options) == .ready else { throw XCTSkip("whisper-cli나 모델이 없어요") }
        let (text, partials) = try await transcribe(engine, options: options)
        XCTAssertTrue(text.contains("안녕하세요"), text)
        XCTAssertEqual(partials, 0)
    }

    private final class PartialCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
}

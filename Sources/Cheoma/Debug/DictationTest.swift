import AVFoundation
import Foundation

/// `Cheoma --dictation-test <소리 파일>… [--engine apple|whisper] [--locale ko-KR] [--vocab "a,b,c"]`:
/// 소리 파일을 마이크처럼 파일 그대로의 형식으로 100 ms씩, 말하는 빠르기에 맞춰 엔진에 넣어 보고
/// 중간 글 수 · 최종 글 · 걸린 시간(begin, 마지막 버퍼 뒤 마무리, 전체)을 찍는다. 창을 열지 않고 마이크도 쓰지 않는다.
/// 그 밖의 옵션: --fast (기다리지 않고 넣기), --partials (중간 글을 모두 찍기),
/// --recognizer dictation|transcription (Apple 인식기 고르기), --model <ggml 파일> (whisper 모델),
/// --cancel-at <초> (넣다가 버리기), --cancel-during-finish <초> (글로 옮기는 중에 버리기),
/// --glossary (받아쓰기처럼 기본 용어집 낱말을 엔진에 알리고, 용어집을 적용한 글도 찍기. --vocab은 사용자 낱말로 앞에 둔다)
enum DictationTestCommand {
    struct Arguments: Equatable {
        var files: [String] = []
        var engine: DictationEngineKind = .apple
        var localeIdentifier = "ko-KR"
        var vocabulary: [String] = []
        var recognizer = "dictation"
        var modelPath = ""
        var paced = true
        var printsPartials = false
        /// 이만큼(초) 넣은 뒤 finish 대신 cancel한다
        var cancelAt: Double?
        /// finish를 부르고 이만큼(초) 뒤에 cancel한다 (글로 옮기는 중에 버리기)
        var cancelDuringFinish: Double?
        /// 받아쓰기와 같은 용어집 (기본 + --vocab)
        var usesGlossary = false
    }

    static func parse(_ arguments: [String]) -> Arguments {
        var result = Arguments()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--engine": if let raw = value(), let kind = DictationEngineKind(rawValue: raw) { result.engine = kind }
            case "--locale": if let raw = value() { result.localeIdentifier = raw }
            case "--vocab":
                if let raw = value() {
                    result.vocabulary = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            case "--recognizer": if let raw = value() { result.recognizer = raw }
            case "--model": if let raw = value() { result.modelPath = raw }
            case "--fast": result.paced = false
            case "--partials": result.printsPartials = true
            case "--cancel-at": result.cancelAt = value().flatMap(Double.init)
            case "--cancel-during-finish": result.cancelDuringFinish = value().flatMap(Double.init)
            case "--glossary": result.usesGlossary = true
            case let other where !other.hasPrefix("--"): result.files.append(other)
            default: break
            }
            index += 1
        }
        return result
    }

    static func run(arguments: [String]) {
        let parsed = parse(arguments)
        guard !parsed.files.isEmpty else {
            print("쓰는 법: Cheoma --dictation-test <소리 파일>… [--engine apple|whisper] [--locale ko-KR] [--vocab \"a,b,c\"]")
            print("        [--fast] [--partials] [--recognizer dictation|transcription] [--model <ggml 파일>]")
            print("        [--cancel-at <초>] [--cancel-during-finish <초>] [--glossary]")
            return
        }
        let done = DoneFlag()
        Task.detached {
            await runAll(parsed)
            done.set()
        }
        // 엔진이 메인 스레드에 일을 넘길 수 있어서 기다리는 동안 런루프를 돌린다
        while !done.isSet { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func makeEngine(_ parsed: Arguments) -> DictationEngine? {
        if parsed.engine == .apple, #available(macOS 26.0, *) {
            let recognizer = AppleSpeechEngine.Recognizer(rawValue: parsed.recognizer) ?? .dictation
            return AppleSpeechEngine(recognizer: recognizer)
        }
        return DictationEngines.make(parsed.engine)
    }

    private static func runAll(_ parsed: Arguments) async {
        guard let engine = makeEngine(parsed) else {
            print("\(parsed.engine.title) 엔진은 이 macOS에서 쓸 수 없어요 (macOS 26 이상)")
            return
        }
        defer { DictationEngines.shutdown(engine) }
        // 받아쓰기와 같이: --vocab 낱말을 사용자 용어집으로 앞에 두고 기본 용어집을 뒤에
        let glossary = parsed.usesGlossary ? DictationGlossary(userText: parsed.vocabulary.joined(separator: "\n")) : nil
        let options = DictationEngineOptions(localeIdentifier: parsed.localeIdentifier,
                                             vocabulary: glossary?.vocabulary ?? parsed.vocabulary,
                                             whisperModelPath: parsed.modelPath)
        var engineName = parsed.engine.title
        if #available(macOS 26.0, *), let apple = engine as? AppleSpeechEngine { engineName += " (\(apple.recognizer.rawValue))" }
        print("엔진 \(engineName) · 언어 \(options.localeIdentifier) · 용어 \(options.vocabulary.count)개"
              + (parsed.paced ? " · 말하는 빠르기로 넣기" : " · 빠르게 넣기"))

        var start = now()
        let availability = await engine.availability(options: options)
        print(String(format: "쓸 수 있는지 %@ (%.3f s)", describe(availability), now() - start))
        if #available(macOS 26.0, *), let apple = engine as? AppleSpeechEngine {
            print("언어 모델: \(await apple.assetReport(options: options))")
        }
        guard availability == .ready else { return }
        start = now()
        await engine.prepare(options: options)
        print(String(format: "미리 올려 두기 %.3f s", now() - start))

        for path in parsed.files {
            await runFile(path, engine: engine, options: options, parsed: parsed, glossary: glossary)
        }
    }

    private static func runFile(_ path: String, engine: DictationEngine, options: DictationEngineOptions, parsed: Arguments,
                                glossary: DictationGlossary?) async {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            print("== \(path): 읽지 못했어요 (\(error.localizedDescription))")
            return
        }
        // 마이크처럼 파일의 처리 형식(Float32, 파일의 샘플레이트 · 채널) 그대로 넣는다
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        print(String(format: "== %@ (%.2f s, %.0f Hz, %d ch)", (path as NSString).lastPathComponent, seconds,
                     format.sampleRate, format.channelCount))

        let partials = PartialLog(printing: parsed.printsPartials)
        let beginStart = now()
        do {
            try await engine.begin(format: format, options: options) { text in partials.add(text) }
        } catch {
            print("  begin 실패: \(message(error))")
            return
        }
        let beginEnd = now()
        partials.startClock(at: beginEnd)

        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var fed: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            guard buffer.frameLength > 0 else { break }
            engine.append(buffer)
            fed += AVAudioFramePosition(buffer.frameLength)
            if parsed.paced {
                let due = beginEnd + Double(fed) / format.sampleRate
                let wait = due - now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            if let cancelAt = parsed.cancelAt, Double(fed) / format.sampleRate >= cancelAt {
                engine.cancel()
                let count = partials.summary.count
                // 버린 뒤에 버퍼가 더 와도, 중간 글이 더 와도 안 된다
                engine.append(buffer)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let late = partials.summary.count - count
                print(String(format: "  %.1f s에서 버림 · 그 전 중간 글 %d번 · 버린 뒤 중간 글 %d번", cancelAt, count, late))
                return
            }
        }
        let released = now()
        if let delay = parsed.cancelDuringFinish {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                engine.cancel()
            }
        }
        do {
            let text = try await engine.finish()
            let end = now()
            let summary = partials.summary
            print(String(format: "  begin %.3f s · 중간 글 %d번%@ · 마지막 버퍼 뒤 마무리 %.3f s · 전체 %.3f s",
                         beginEnd - beginStart, summary.count,
                         summary.first.map { String(format: " (첫 글 %.2f s)", $0) } ?? "",
                         end - released, end - beginStart))
            print("  글: \(text.isEmpty ? "(없음)" : text)")
            if let glossary, !text.isEmpty { print("  용어집: \(DictationController.finalText(text, glossary: glossary))") }
        } catch is CancellationError {
            print(String(format: "  글로 옮기는 중에 버림 (%.3f s 뒤 돌아옴)", now() - released))
        } catch {
            print("  finish 실패: \(message(error))")
        }
    }

    private static func describe(_ availability: DictationAvailability) -> String {
        switch availability {
        case .ready: "됨"
        case .needsDownload: "언어 모델을 내려받아야 해요"
        case .unavailable(let reason): "안 됨: \(reason)"
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? DictationError)?.message ?? error.localizedDescription
    }

    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private final class DoneFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// 중간 글을 센다 (엔진의 스레드에서 불린다)
    private final class PartialLog: @unchecked Sendable {
        private let lock = NSLock()
        private let printing: Bool
        private var count = 0
        private var first: Double?
        private var clock: Double?

        init(printing: Bool) { self.printing = printing }

        func startClock(at time: Double) { lock.withLock { clock = time } }

        func add(_ text: String) {
            let time = now()
            let elapsed = lock.withLock { () -> Double in
                count += 1
                let elapsed = time - (clock ?? time)
                if first == nil { first = elapsed }
                return elapsed
            }
            if printing { print(String(format: "    ~%.2f  %@", elapsed, text)) }
        }

        var summary: (count: Int, first: Double?) { lock.withLock { (count, first) } }
    }
}

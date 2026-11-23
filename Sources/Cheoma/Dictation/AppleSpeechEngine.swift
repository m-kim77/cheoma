import AVFoundation
import Foundation
import os
import Speech

/// 설정의 엔진 종류로 엔진을 만든다
enum DictationEngines {
    /// Apple 음성 인식은 macOS 26부터 있다. 그 전에는 nil
    static func make(_ kind: DictationEngineKind) -> DictationEngine? {
        switch kind {
        case .apple:
            if #available(macOS 26.0, *) { return AppleSpeechEngine() }
            return nil
        case .whisper:
            return WhisperEngine()
        }
    }

    /// 엔진이 붙잡아 둔 것(돌고 있는 whisper 프로세스, 올려 둔 Apple 모델)을 놓는다. 앱을 끝낼 때 · 엔진을 바꾸거나 끌 때 부른다
    static func shutdown(_ engine: DictationEngine) {
        if let whisper = engine as? WhisperEngine { whisper.shutdown() }
        if #available(macOS 26.0, *), let apple = engine as? AppleSpeechEngine { apple.shutdown() }
    }
}

// MARK: - 소리 형식 바꾸기

/// 마이크 버퍼를 엔진이 받는 형식(샘플레이트 · 채널 · 샘플 종류)으로 바꾼다.
/// 샘플레이트 변환기는 앞 버퍼의 끝 샘플을 기억하므로 듣기 한 번 동안 같은 것을 계속 쓴다.
/// 스레드에 안전하지 않다. 부르는 쪽이 잠근다
final class StreamingAudioConverter {
    let outputFormat: AVAudioFormat
    private(set) var inputFormat: AVAudioFormat
    /// nil이면 형식이 같아서 복사만 한다
    private var converter: AVAudioConverter?

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        guard rebuild(for: inputFormat) else { return nil }
    }

    private func rebuild(for format: AVAudioFormat) -> Bool {
        inputFormat = format
        if format == outputFormat {
            converter = nil
            return true
        }
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else { return false }
        // 스테레오 마이크도 한 채널만 남기지 않고 섞어서 모노로 만든다
        converter.downmix = format.channelCount > outputFormat.channelCount
        self.converter = converter
        return true
    }

    /// 버퍼 하나를 바꾼다. 받은 버퍼는 건드리지 않고 새 버퍼를 돌려준다 (마이크가 버퍼를 다시 쓸 수 있어서)
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        // 듣는 중에 마이크가 바뀌어 형식이 달라지면 변환기를 새로 만든다
        if buffer.format != inputFormat, !rebuild(for: buffer.format) { return nil }
        guard let converter else { return buffer.copy() as? AVAudioPCMBuffer }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // 버퍼 하나만 건네고 "지금은 더 없음"이라고 한다. 끝(endOfStream)이라고 하면 변환기가 닫힌다
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// 변환기 안에 남은 끝 샘플을 꺼낸다. 듣기를 마칠 때 한 번 부른다
    func flush() -> AVAudioPCMBuffer? {
        guard let converter, inputFormat.sampleRate != outputFormat.sampleRate,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - Apple 음성 인식

/// Apple 음성 인식 (macOS 26 SpeechAnalyzer). 인식은 이 앱 밖의 시스템 프로세스에서 돈다.
/// 마이크 버퍼를 분석기 형식(16 kHz 모노 Int16)으로 바꿔 흘려 넣고, 바뀌어 가는 글을 바로바로 알린다.
/// 끝낸 분석기는 다시 못 쓰므로 듣기 한 번마다 새것을 쓴다. 다음 것은 미리 만들어 모델까지 올려 두어 begin이 바로 끝난다
@available(macOS 26.0, *)
final class AppleSpeechEngine: DictationEngine, @unchecked Sendable {
    /// 어느 인식기를 쓸지
    enum Recognizer: String, CaseIterable, Sendable {
        /// 받아쓰기용 (DictationTranscriber). 용어집 낱말(contextualStrings)을 듣고 영어 낱말을 영어로 쓰기도 한다
        case dictation
        /// 일반 전사용 (SpeechTranscriber). 조금 빠르지만 영어 낱말도 한글로 쓰고 용어집을 듣지 않는다
        case transcription
    }

    /// Apple이 듣는 용어 수와 한 용어의 낱말 수
    static let maxContextualStrings = 100
    static let maxWordsPerContextualString = 2
    /// 시작하는 동안 모아 둘 소리 (초)
    private static let maxPendingSeconds = 3.0

    let recognizer: Recognizer

    private let lock = NSLock()
    private var state = State.idle
    /// 키를 떼고 글로 옮기는 중인 듣기 (cancel이 버릴 수 있게)
    private var finishing: [Session] = []
    /// cancel할 때마다 늘린다. 시작하는 중에 취소됐는지 본다
    private var generation = 0
    /// 다음 듣기에 쓸 분석기 (만드는 중이거나 다 만든 것)
    private var warmTask: Task<Warm, Error>?
    private var warmKey: WarmKey?

    private enum State {
        case idle
        /// begin이 분석기를 기다리는 동안 온 버퍼. 첫 음절을 놓치지 않게 모아 두었다가 흘려 넣는다
        case starting(pending: [AVAudioPCMBuffer], frames: AVAudioFrameCount)
        case running(Session)
    }

    init(recognizer: Recognizer = .dictation) {
        self.recognizer = recognizer
    }

    deinit {
        warmTask?.cancel()
    }

    // MARK: 쓸 수 있는지

    func availability(options: DictationEngineOptions) async -> DictationAvailability {
        if recognizer == .transcription, !SpeechTranscriber.isAvailable {
            return .unavailable("이 Mac에서는 Apple 음성 인식을 사용할 수 없습니다")
        }
        let requested = Locale(identifier: options.localeIdentifier)
        guard let locale = await Self.supportedLocale(recognizer, equivalentTo: requested) else {
            return .unavailable("Apple 음성 인식이 이 언어(\(options.localeIdentifier))를 지원하지 않습니다")
        }
        // AssetInventory.status는 설치돼 있어도 .supported라고 할 때가 있다 (이 앱이 예약했는지에 따라). 설치된 언어 목록을 본다
        let installed = await Self.installedLocales(recognizer)
        if installed.contains(where: { Self.sameLocale($0, locale) }) { return .ready }
        return .needsDownload
    }

    /// 언어 모델을 내려받는다 (설정 화면의 내려받기 단추). progress는 0…1
    func downloadAssets(options: DictationEngineOptions, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let requested = Locale(identifier: options.localeIdentifier)
        guard let locale = await Self.supportedLocale(recognizer, equivalentTo: requested) else {
            throw DictationError.engineUnavailable("Apple 음성 인식이 이 언어(\(options.localeIdentifier))를 지원하지 않습니다")
        }
        let module = Transcriber.make(recognizer, locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.base]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            progress?(value.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// 언어 모델 상태를 한 줄로 (`--dictation-test`가 찍는다)
    func assetReport(options: DictationEngineOptions) async -> String {
        let requested = Locale(identifier: options.localeIdentifier)
        guard let locale = await Self.supportedLocale(recognizer, equivalentTo: requested) else { return "지원하지 않는 언어" }
        let installed = await Self.installedLocales(recognizer).contains { Self.sameLocale($0, locale) }
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
        let status = await AssetInventory.status(forModules: [Transcriber.make(recognizer, locale: locale).base])
        return "\(locale.identifier(.bcp47)) 설치 \(installed ? "됨" : "안 됨") · 예약 \(reserved) · AssetInventory \(status)"
    }

    // MARK: 미리 올려 두기

    func prepare(options: DictationEngineOptions) async {
        guard await availability(options: options) == .ready else { return }
        await reserveInstalledLocale(options.localeIdentifier)
        _ = try? await warmUp(key(for: options)).value
    }

    /// 설치된 언어를 이 앱 몫으로 예약해 둔다. 예약한 앱이 없는 언어 모델은 시스템이 지울 수 있다.
    /// 이미 설치된 것만 예약하므로 내려받기는 일어나지 않는다. 자리(최대 5개)가 없으면 그냥 둔다
    private func reserveInstalledLocale(_ identifier: String) async {
        guard let locale = await Self.supportedLocale(recognizer, equivalentTo: Locale(identifier: identifier)) else { return }
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { Self.sameLocale($0, locale) }),
              reserved.count < AssetInventory.maximumReservedLocales else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    private func key(for options: DictationEngineOptions) -> WarmKey {
        WarmKey(localeIdentifier: options.localeIdentifier,
                contextualStrings: recognizer == .dictation ? Self.contextualStrings(from: options.vocabulary) : [])
    }

    /// 다음 듣기에 쓸 분석기를 미리 만들고 모델까지 올려 둔다. 같은 것을 이미 만들고 있으면 그것을 돌려준다
    @discardableResult
    private func warmUp(_ key: WarmKey) -> Task<Warm, Error> {
        lock.withLock { warmTaskLocked(for: key) }
    }

    /// 잠근 채로 부른다
    private func warmTaskLocked(for key: WarmKey) -> Task<Warm, Error> {
        if let warmTask, warmKey == key { return warmTask }
        warmTask?.cancel()
        let recognizer = recognizer
        let task = Task(priority: .userInitiated) { try await Self.makeWarm(recognizer, key: key) }
        warmTask = task
        warmKey = key
        return task
    }

    /// 미리 만든 분석기를 가져간다 (한 번만 쓸 수 있어서 다음 듣기에는 새로 만든다). 만들다 실패했으면 한 번 더 해 본다
    private func takeWarm(_ key: WarmKey) async throws -> Warm {
        let task = lock.withLock { () -> Task<Warm, Error> in
            let task = warmTaskLocked(for: key)
            warmTask = nil
            warmKey = nil
            return task
        }
        if let warm = try? await task.value { return warm }
        return try await Self.makeWarm(recognizer, key: key)
    }

    private static func makeWarm(_ recognizer: Recognizer, key: WarmKey) async throws -> Warm {
        let requested = Locale(identifier: key.localeIdentifier)
        guard let locale = await supportedLocale(recognizer, equivalentTo: requested) else {
            throw DictationError.engineUnavailable("Apple 음성 인식이 이 언어(\(key.localeIdentifier))를 지원하지 않습니다")
        }
        let module = Transcriber.make(recognizer, locale: locale)
        // 모델을 앱이 끝날 때까지 붙잡아 둔다. 놓는 것은 shutdown
        let analyzer = SpeechAnalyzer(modules: [module.base],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.base]) else {
            throw DictationError.engineUnavailable("Apple 음성 인식에 맞는 오디오 형식이 없습니다")
        }
        if !key.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: key.contextualStrings]
            try? await analyzer.setContext(context)
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            throw DictationError.engineUnavailable("Apple 음성 인식을 준비하지 못했습니다: \(error.localizedDescription)")
        }
        return Warm(key: key, analyzer: analyzer, module: module, format: format, joinsWithSpace: joinsWithSpace(locale))
    }

    /// 올려 둔 모델과 미리 만든 분석기를 놓는다 (받아쓰기를 끄거나 엔진을 바꿀 때 · 앱을 끝낼 때)
    func shutdown() {
        cancel()
        let task = lock.withLock { () -> Task<Warm, Error>? in
            defer {
                warmTask = nil
                warmKey = nil
            }
            return warmTask
        }
        task?.cancel()
        Task { await SpeechModels.endRetention() }
    }

    // MARK: 듣기

    func begin(format: AVAudioFormat, options: DictationEngineOptions,
               onPartial: @escaping @Sendable (String) -> Void) async throws {
        cancelListening()
        let key = key(for: options)
        let myGeneration = lock.withLock { () -> Int in
            state = .starting(pending: [], frames: 0)
            return generation
        }
        do {
            var warm = try await takeWarm(key)
            // 미리 만든 뒤에 용어집이 바뀌었으면 새 용어를 넣는다
            if warm.key.contextualStrings != key.contextualStrings {
                let context = AnalysisContext()
                context.contextualStrings = [.general: key.contextualStrings]
                try? await warm.analyzer.setContext(context)
                warm.key = key
            }
            guard let converter = StreamingAudioConverter(from: format, to: warm.format) else {
                throw DictationError.engineUnavailable("오디오를 Apple 음성 인식 형식으로 변환하지 못했습니다")
            }
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let session = Session(warm: warm, input: input, converter: converter, onPartial: onPartial)
            session.resultsTask = Task { [weak self, session] in
                do {
                    try await session.warm.module.readResults { isFinal, text in
                        self?.handleResult(session, isFinal: isFinal, text: text)
                    }
                } catch {
                    // 취소하거나 분석기가 끝나면 여기로 온다
                }
            }

            // 시작하는 동안 취소됐으면 여기서 그만둔다. 아니면 모아 둔 소리부터 흘려 넣는다
            let started = lock.withLock { () -> Bool in
                guard generation == myGeneration, case .starting(let pending, _) = state else { return false }
                for buffer in pending {
                    if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
                }
                state = .running(session)
                return true
            }
            guard started else {
                tearDown(session)
                warmUp(key)
                throw CancellationError()
            }
            do {
                try await warm.analyzer.start(inputSequence: stream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DictationError.engineUnavailable("Apple 음성 인식을 시작하지 못했습니다: \(error.localizedDescription)")
            }
        } catch {
            let failed = lock.withLock { () -> Session? in
                guard generation == myGeneration else { return nil }
                generation += 1
                defer { state = .idle }
                if case .running(let session) = state { return session }
                return nil
            }
            if let failed {
                tearDown(failed)
                warmUp(key)
            }
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle:
            return
        case .starting(var pending, let frames):
            let limit = AVAudioFrameCount(buffer.format.sampleRate * Self.maxPendingSeconds)
            guard frames + buffer.frameLength <= limit, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            pending.append(copy)
            state = .starting(pending: pending, frames: frames + buffer.frameLength)
        case .running(let session):
            guard let converted = session.converter.convert(buffer) else { return }
            session.input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async throws -> String {
        let session = lock.withLock { () -> Session? in
            defer { state = .idle }
            guard case .running(let session) = state else { return nil }
            if let tail = session.converter.flush() { session.input.yield(AnalyzerInput(buffer: tail)) }
            session.input.finish()
            finishing.append(session)
            return session
        }
        guard let session else { return "" }
        // 마무리하는 동안 다음 분석기를 만들어 둔다 (곧바로 다시 눌러도 begin이 기다리지 않게)
        warmUp(session.warm.key)
        defer { lock.withLock { finishing.removeAll { $0 === session } } }
        do {
            try await session.warm.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            if lock.withLock({ session.isCancelled }) { throw CancellationError() }
            tearDown(session)
            throw DictationError.engineUnavailable("Apple 음성 인식이 중단되었습니다: \(error.localizedDescription)")
        }
        // 분석기가 끝나면 결과 흐름도 끝난다. 혹시 안 끝나도 오래 기다리지 않는다
        await Self.wait(for: session.resultsTask, upTo: 2)
        let (text, cancelled) = lock.withLock { () -> (String, Bool) in
            session.isClosed = true
            return (Self.join(session.finalized, session.volatile, withSpace: session.warm.joinsWithSpace), session.isCancelled)
        }
        if cancelled { throw CancellationError() }
        return Self.tidy(text)
    }

    /// 듣던 것도, 글로 옮기던 것도 버린다. 옮기던 finish는 CancellationError를 던진다
    func cancel() {
        let sessions = lock.withLock { () -> [Session] in
            defer { finishing.removeAll() }
            for session in finishing { session.isCancelled = true }
            return finishing
        }
        for session in sessions { tearDown(session) }
        cancelListening()
    }

    /// 듣던 것만 버린다. begin은 이것을 불러서, 앞의 말을 글로 옮기는 중이어도 그것은 그대로 둔다
    private func cancelListening() {
        let session = lock.withLock { () -> Session? in
            generation += 1
            defer { state = .idle }
            if case .running(let session) = state { return session }
            return nil
        }
        guard let session else { return }
        tearDown(session)
        warmUp(session.warm.key)
    }

    /// 결과를 알리지 않고 분석기를 멈춘다
    private func tearDown(_ session: Session) {
        lock.withLock { session.isClosed = true }
        session.input.finish()
        let analyzer = session.warm.analyzer
        let resultsTask = session.resultsTask
        Task {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
        }
    }

    private func handleResult(_ session: Session, isFinal: Bool, text: String) {
        let partial = lock.withLock { () -> String? in
            guard !session.isClosed else { return nil }
            if isFinal {
                session.finalized = Self.join(session.finalized, text, withSpace: session.warm.joinsWithSpace)
                session.volatile = ""
            } else {
                session.volatile = text
            }
            let partial = Self.tidy(Self.join(session.finalized, session.volatile, withSpace: session.warm.joinsWithSpace))
            guard partial != session.lastPartial else { return nil }
            session.lastPartial = partial
            return partial
        }
        if let partial { session.onPartial(partial) }
    }

    /// task가 끝나거나 seconds가 지날 때까지 기다린 뒤 task를 멈춘다.
    /// task 그룹은 모든 자식을 기다리고 `task.value`는 취소에 답하지 않아서, 먼저 끝난 쪽이 한 번만 깨우게 한다
    static func wait(for task: Task<Void, Never>?, upTo seconds: Double) async {
        guard let task else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable () -> Void = {
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                resume()
            }
            Task {
                await task.value
                timer.cancel()
                resume()
            }
        }
        task.cancel()
    }

    // MARK: 글 다듬기 (테스트에서도 쓴다)

    /// 용어집 낱말을 Apple이 받는 모양으로 고른다: 빈 것 · 겹친 것 · 세 낱말 이상은 빼고 앞의 100개
    static func contextualStrings(from vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in vocabulary {
            let words = raw.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty, words.count <= maxWordsPerContextualString else { continue }
            let term = words.joined(separator: " ")
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maxContextualStrings { break }
        }
        return result
    }

    /// 앞 글과 뒷 글을 잇는다. 띄어 쓰는 언어면 사이에 빈칸이 없을 때 하나 넣는다
    static func join(_ head: String, _ tail: String, withSpace: Bool) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        guard withSpace, head.last?.isWhitespace == false, tail.first?.isWhitespace == false else { return head + tail }
        return head + " " + tail
    }

    /// 빈칸을 하나로 줄이고 앞뒤 빈칸을 지운다
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 낱말 사이를 띄어 쓰지 않는 언어 (일본어 · 중국어 · 태국어 …)가 아니면 true
    static func joinsWithSpace(_ locale: Locale) -> Bool {
        let code = locale.language.languageCode?.identifier ?? ""
        return !["ja", "zh", "yue", "th", "lo", "my", "km"].contains(code)
    }

    static func sameLocale(_ a: Locale, _ b: Locale) -> Bool {
        a.identifier(.bcp47).lowercased() == b.identifier(.bcp47).lowercased()
    }

    private static func supportedLocale(_ recognizer: Recognizer, equivalentTo locale: Locale) async -> Locale? {
        switch recognizer {
        case .dictation: return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .transcription: return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    private static func installedLocales(_ recognizer: Recognizer) async -> [Locale] {
        switch recognizer {
        case .dictation: return await DictationTranscriber.installedLocales
        case .transcription: return await SpeechTranscriber.installedLocales
        }
    }
}

// MARK: - 분석기 · 듣기 한 번

/// 미리 만든 분석기가 무엇을 위한 것인지 (언어 · 넣어 둔 용어)
private struct WarmKey: Equatable, Sendable {
    var localeIdentifier: String
    var contextualStrings: [String]
}

@available(macOS 26.0, *)
private struct Warm: @unchecked Sendable {
    var key: WarmKey
    let analyzer: SpeechAnalyzer
    let module: Transcriber
    let format: AVAudioFormat
    let joinsWithSpace: Bool
}

/// 듣기 한 번. 글과 닫힘 표시는 엔진의 잠금 안에서만 바꾼다
@available(macOS 26.0, *)
private final class Session: @unchecked Sendable {
    let warm: Warm
    let input: AsyncStream<AnalyzerInput>.Continuation
    let converter: StreamingAudioConverter
    let onPartial: @Sendable (String) -> Void
    var resultsTask: Task<Void, Never>?
    /// 확정된 글
    var finalized = ""
    /// 아직 바뀔 수 있는 뒷부분
    var volatile = ""
    /// 마지막으로 알린 중간 글 (같은 글을 두 번 알리지 않는다)
    var lastPartial = ""
    /// 끝났거나 버렸다. 그 뒤로는 중간 글을 알리지 않는다
    var isClosed = false
    /// 글로 옮기는 중에 cancel로 버렸다
    var isCancelled = false

    init(warm: Warm, input: AsyncStream<AnalyzerInput>.Continuation, converter: StreamingAudioConverter,
         onPartial: @escaping @Sendable (String) -> Void) {
        self.warm = warm
        self.input = input
        self.converter = converter
        self.onPartial = onPartial
    }
}

/// 두 인식기는 결과 타입이 달라서 한곳에서 다룬다
@available(macOS 26.0, *)
private enum Transcriber: @unchecked Sendable {
    case dictation(DictationTranscriber)
    case transcription(SpeechTranscriber)

    static func make(_ recognizer: AppleSpeechEngine.Recognizer, locale: Locale) -> Transcriber {
        switch recognizer {
        case .dictation:
            // 문장 부호를 넣고, 바뀌어 가는 글(volatile)을 자주 알리고 자주 확정한다
            return .dictation(DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: []))
        case .transcription:
            return .transcription(SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults, .fastResults],
                                                    attributeOptions: []))
        }
    }

    var base: any SpeechModule {
        switch self {
        case .dictation(let module): return module
        case .transcription(let module): return module
        }
    }

    /// 결과를 끝까지 읽는다 (분석기가 끝나면 끝난다)
    func readResults(_ handle: (_ isFinal: Bool, _ text: String) -> Void) async throws {
        switch self {
        case .dictation(let module):
            for try await result in module.results { handle(result.isFinal, String(result.text.characters)) }
        case .transcription(let module):
            for try await result in module.results { handle(result.isFinal, String(result.text.characters)) }
        }
    }
}

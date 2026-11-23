import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import Cheoma

// 받아쓰기를 잇는 부분: 노치 단계, 설정 저장, 소리 모아 두기, 그리고 가짜 마이크 · 엔진으로 듣기 한 번의 흐름.
// 진짜 마이크 · 키 이벤트 · 클립보드는 쓰지 않는다

// MARK: - 노치

@MainActor
final class NotchDictationTests: XCTestCase {
    private let alert = NotchAlert(symbol: "bolt.fill", tint: .green, text: "충전 중")

    func testDictationSitsBetweenOpenAndAlert() {
        let model = NotchModel()
        model.show(alert)
        XCTAssertEqual(model.phase, .alert)
        model.dictation = DictationIndicator(stage: .listening)
        XCTAssertEqual(model.phase, .dictation)
        model.previewOpen(.overview)
        XCTAssertEqual(model.phase, .open)
        model.previewClose()
        XCTAssertEqual(model.phase, .dictation)
        model.dictation = nil
        // 받아쓰는 동안 기다린 알림이 다시 보인다
        XCTAssertEqual(model.phase, .alert)
    }

    /// 받아쓰는 동안 가려진 알림은 시간을 세지 않고, 귀가 사라지면 다시 보인다
    func testAlertWaitsBehindDictation() async throws {
        let model = NotchModel()
        model.show(alert, duration: 0.05)
        model.dictation = DictationIndicator(stage: .listening)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(model.alert)
        model.dictation = nil
        XCTAssertEqual(model.phase, .alert)
        try await Task.sleep(for: .milliseconds(150))
        // 다시 보여 줄 때는 적어도 2초
        XCTAssertEqual(model.phase, .alert)
        XCTAssertEqual(NotchModel.alertDurationAfterDictation, 2)
    }

    /// 귀가 사라진 뒤 다시 센 시간이 지나면 알림도 사라진다 (멈춘 채 남지 않는다)
    func testAlertEndsAfterDictationGoesAway() async throws {
        let model = NotchModel()
        model.alertDurationAfterDictation = 0.05
        model.show(alert, duration: 0.05)
        model.dictation = DictationIndicator(stage: .listening)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotNil(model.alert)
        model.dictation = nil
        let deadline = Date().addingTimeInterval(2)
        while model.alert != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.phase, .closed)
    }

    /// 펼친 대시보드는 받아쓰는 중에도 그대로 (귀는 대시보드 위쪽 띠에 그린다)
    func testOpenDashboardKeepsPhaseWhileDictating() {
        let model = NotchModel()
        model.previewOpen(.agents)
        model.dictation = DictationIndicator(stage: .listening, handsFree: true)
        XCTAssertEqual(model.phase, .open)
        XCTAssertEqual(model.shapeSize, model.openSize)
    }

    func testDictationOutranksHover() {
        let model = NotchModel()
        model.updateMouse(inHotZone: true, inOpenZone: true)
        XCTAssertEqual(model.phase, .hovering)
        model.dictation = DictationIndicator(stage: .transcribing)
        XCTAssertEqual(model.phase, .dictation)
        model.updateMouse(inHotZone: false, inOpenZone: false)
        XCTAssertEqual(model.phase, .dictation)
    }

    func testDictationEarsAreWiderThanAlertEars() {
        let model = NotchModel()
        model.notchSize = CGSize(width: 200, height: 32)
        model.dictation = DictationIndicator(stage: .listening)
        XCTAssertEqual(model.shapeSize, CGSize(width: 200 + NotchModel.dictationEarWidth * 2, height: 32))
        model.dictation = nil
        model.show(alert)
        XCTAssertEqual(model.shapeSize, CGSize(width: 200 + NotchModel.earWidth * 2, height: 32))
        XCTAssertGreaterThan(NotchModel.dictationEarWidth, NotchModel.earWidth)
    }

    func testIndicatorSeedsLiveState() {
        let model = NotchModel()
        model.dictation = DictationIndicator(stage: .listening, level: 0.5, text: "GitHub에")
        XCTAssertEqual(model.dictationLive.level, 0.5)
        XCTAssertEqual(model.dictationLive.text, "GitHub에")
        model.dictationLive.push(level: 1)
        XCTAssertEqual(model.dictationLive.levels, [0.5, 0.5, 1])
        model.dictationLive.push(level: 0.25)
        XCTAssertEqual(model.dictationLive.levels, [0.5, 1, 0.25])
    }

    /// 소리 크기 · 중간 글은 귀만 다시 그린다. NotchModel이 알리면 펼친 대시보드까지 다시 그린다
    func testLiveUpdatesDoNotPublishNotchModel() {
        let model = NotchModel()
        model.dictation = DictationIndicator(stage: .listening)
        var notchChanges = 0
        var liveChanges = 0
        let notchObservation = model.objectWillChange.sink { notchChanges += 1 }
        let liveObservation = model.dictationLive.objectWillChange.sink { liveChanges += 1 }
        for step in 0..<20 { model.dictationLive.push(level: Float(step % 5) / 4) }
        model.dictationLive.text = "도커"
        XCTAssertEqual(notchChanges, 0)
        XCTAssertGreaterThan(liveChanges, 0)
        notchObservation.cancel()
        liveObservation.cancel()
    }

    func testSameLevelDoesNotRedraw() {
        let live = DictationLiveState()
        live.push(level: 0)
        var changes = 0
        let observation = live.objectWillChange.sink { changes += 1 }
        // 조용한 동안 (0이 계속 오면) 다시 그리지 않는다
        for _ in 0..<10 { live.push(level: 0) }
        live.push(level: 0.001)
        XCTAssertEqual(changes, 0)
        observation.cancel()
    }
}

// MARK: - 설정 저장

final class DictationSettingsStorageTests: XCTestCase {
    private let suiteName = "io.github.m-kim77.cheoma.test.dictation-settings"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Apple 음성 인식이 없는 macOS에서는 처음부터 whisper
    func testPreferredEngine() {
        if #available(macOS 26.0, *) {
            XCTAssertEqual(DictationSettings().engine, .apple)
        } else {
            XCTAssertEqual(DictationSettings().engine, .whisper)
        }
    }

    func testDefaultsWhenNothingSaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(DictationSettings.load(from: defaults), DictationSettings())
        XCTAssertFalse(DictationSettings().isEnabled)
        XCTAssertEqual(DictationSettings().hotKey, .rightOption)
    }

    func testRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var settings = DictationSettings()
        settings.isEnabled = true
        settings.hotKey = .rightCommand
        settings.allowsHandsFree = false
        settings.engine = .whisper
        settings.localeIdentifier = "ja-JP"
        settings.prefersBuiltInMicrophone = false
        settings.pasteMethod = .menu
        settings.restoresClipboard = false
        settings.glossaryText = "도커 → Docker\nSwiftData"
        settings.whisperModelPath = "~/models/ggml-large-v3-turbo-q5_0.bin"
        settings.save(to: defaults)
        XCTAssertEqual(DictationSettings.load(from: defaults), settings)
    }

    func testUnknownValuesFallBackToDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("capsLock", forKey: "dictation.hotKey")
        defaults.set("cloud", forKey: "dictation.engine")
        defaults.set("", forKey: "dictation.locale")
        let settings = DictationSettings.load(from: defaults)
        XCTAssertEqual(settings.hotKey, .rightOption)
        XCTAssertEqual(settings.engine, DictationSettings().engine)
        XCTAssertEqual(settings.localeIdentifier, "ko-KR")
    }
}

// MARK: - 소리 모아 두기 · 신호

final class DictationBufferQueueTests: XCTestCase {
    func testQueuesUntilAttachThenPassesThroughInOrder() {
        let queue = DictationBufferQueue()
        let engine = FakeDictationEngine()
        queue.receive(DictationTestAudio.buffer(1))
        queue.receive(DictationTestAudio.buffer(2))
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(engine.appended, [])
        queue.attach(engine)
        XCTAssertEqual(queue.pendingCount, 0)
        queue.receive(DictationTestAudio.buffer(3))
        XCTAssertEqual(engine.appended, [1, 2, 3])
    }

    /// 마이크가 버퍼를 다시 써도 모아 둔 소리는 그대로다
    func testQueuedBuffersAreCopies() {
        let queue = DictationBufferQueue()
        let engine = FakeDictationEngine()
        let buffer = DictationTestAudio.buffer(1)
        queue.receive(buffer)
        buffer.floatChannelData![0][0] = 9
        queue.attach(engine)
        XCTAssertEqual(engine.appended, [1])
    }

    func testDiscardDropsEverything() {
        let queue = DictationBufferQueue()
        let engine = FakeDictationEngine()
        queue.receive(DictationTestAudio.buffer(1))
        queue.discard()
        queue.attach(engine)
        queue.receive(DictationTestAudio.buffer(2))
        XCTAssertEqual(engine.appended, [])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    /// 키를 뗀 뒤 엔진이 늦게 시작해도 그때까지 모아 둔 소리는 넘긴다 (뗀 뒤에 온 것은 넘기지 않는다)
    func testFinishInputKeepsQueuedAudio() {
        let queue = DictationBufferQueue()
        let engine = FakeDictationEngine()
        queue.receive(DictationTestAudio.buffer(1))
        XCTAssertTrue(queue.hasReceivedAudio)
        queue.finishInput()
        queue.receive(DictationTestAudio.buffer(2))
        queue.attach(engine)
        queue.receive(DictationTestAudio.buffer(3))
        XCTAssertEqual(engine.appended, [1])
        XCTAssertFalse(DictationBufferQueue().hasReceivedAudio)
    }

    func testStopsQueueingAtLimit() {
        let queue = DictationBufferQueue(maximumSeconds: 10)
        // 1초짜리 버퍼 12개 중 10초까지만
        for index in 0..<12 { queue.receive(DictationTestAudio.buffer(Float(index), frames: 48_000)) }
        XCTAssertEqual(queue.pendingCount, 10)
        // 기본은 한 번에 들을 수 있는 가장 긴 시간보다 길다 (앞 듣기를 기다리는 동안 말 가운데가 빠지지 않게)
        XCTAssertGreaterThan(DictationBufferQueue().maximumSeconds, DictationController.maximumDuration)
    }

    func testConcurrentReceiveKeepsOrderAcrossAttach() {
        let queue = DictationBufferQueue()
        let engine = FakeDictationEngine()
        let feeder = DispatchQueue(label: "feeder")
        let done = expectation(description: "다 넣음")
        feeder.async {
            for index in 0..<400 { queue.receive(DictationTestAudio.buffer(Float(index), frames: 16)) }
            done.fulfill()
        }
        usleep(200)
        queue.attach(engine)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(engine.appended, (0..<400).map(Float.init))
    }
}

@MainActor
final class DictationSignalTests: XCTestCase {
    func testWaitersGetTheFirstValue() async {
        let signal = DictationSignal<Int>()
        async let early = signal.wait()
        await Task.yield()
        signal.send(1)
        signal.send(2)
        let value = await early
        XCTAssertEqual(value, 1)
        let late = await signal.wait()
        XCTAssertEqual(late, 1)
        XCTAssertTrue(signal.isSent)
    }
}

// MARK: - 듣기 한 번

@MainActor
final class DictationControllerTests: XCTestCase {
    private let suiteName = "io.github.m-kim77.cheoma.test.dictation-controller"
    private var audio: FakeAudioSource!
    private var engine: FakeDictationEngine!
    private var inserted: [String] = []
    private var insertResult = DictationInsertionResult.inserted(.commandV)
    private var insertedMethods: [DictationPasteMethod] = []
    private var microphone = AVAuthorizationStatus.authorized
    /// 단축키 · 다른 수식키를 누르고 있는지 (가짜 키보드)
    private var modifiersDown = false
    private var trusted = true
    private var accessibilityRequests = 0
    private var clipboardAccess = DictationClipboardAccess.allowed
    /// 권한을 물은 차례
    private var permissionLog: [String] = []
    /// true면 가짜 감시 · 탭을 단 진짜 단축키 감시를 넣는다 (받아쓰기를 켤 때 만든다)
    private var usesMonitor = false
    private var hooks: FakeSystemHooks!
    private var monitor: PushToTalkMonitor?
    /// 가짜 키보드에서 단축키가 눌려 있는지와 시각
    private var hotKeyDown = false
    private var now: TimeInterval = 100
    private var typedCount = 0
    /// 화면이 꺼지지 않게 잡아 둔 수
    private var displayAwake = 0

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(glossary: String = "", configure: (inout DictationSettings) -> Void = { _ in })
        throws -> (DictationController, NotchModel) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var settings = DictationSettings()
        settings.isEnabled = true
        settings.glossaryText = glossary
        configure(&settings)
        settings.save(to: defaults)
        audio = FakeAudioSource()
        engine = FakeDictationEngine()
        inserted = []
        insertedMethods = []
        hooks = FakeSystemHooks()
        let engine = engine!
        let dependencies = DictationController.Dependencies(
            audio: audio, makeEngine: { _ in engine },
            insert: { [unowned self] text, settings, _ in
                inserted.append(text)
                insertedMethods.append(settings.pasteMethod)
                return insertResult
            },
            microphoneStatus: { [unowned self] in microphone },
            requestMicrophone: { [unowned self] in
                permissionLog.append("마이크")
                return false
            },
            accessibilityTrusted: { [unowned self] in trusted }, modifiersHeld: { [unowned self] _ in modifiersDown },
            ownPanelIsKey: { false },
            requestAccessibility: { [unowned self] in
                accessibilityRequests += 1
                permissionLog.append("손쉬운 사용")
            },
            clipboardAccess: { [unowned self] in clipboardAccess },
            makeMonitor: { [unowned self] hotKey, handsFree in
                guard usesMonitor else { return nil }
                let monitor = PushToTalkMonitor(hotKey: hotKey, allowsHandsFree: handsFree, interceptsEscape: true,
                                                clock: { [unowned self] in now },
                                                isHotKeyPhysicallyDown: { [unowned self] _ in hotKeyDown }, hooks: hooks.hooks)
                self.monitor = monitor
                return monitor
            },
            userTyped: { [unowned self] in typedCount += 1 },
            keepDisplayAwake: { [unowned self] in
                displayAwake += 1
                return { [unowned self] in displayAwake -= 1 }
            })
        let model = NotchModel()
        let controller = DictationController(notch: model, defaults: defaults, dependencies: dependencies)
        controller.timing = DictationController.Timing(tail: 0.01, linger: 0.05, inserted: 0.05, failed: 0.05,
                                                        modifierRelease: 0, prepareDebounce: 0.01, limit: 60)
        return (controller, model)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("기다리다 끝남: \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHoldToTalkInsertsTextWithGlossary() async throws {
        let (controller, model) = try makeController(glossary: "체오마 → Cheoma")
        engine.results = ["체오마 에서 도커 띄워 줘"]
        controller.handle(.armed)
        XCTAssertTrue(audio.isRunning)
        // 기다리는 0.15초 동안 들어온 첫 음절
        audio.send(1)
        audio.send(2)
        controller.handle(.began(handsFree: false))
        XCTAssertEqual(model.dictation?.stage, .listening)
        audio.send(3)
        try await waitUntil("앞 소리를 엔진에 넘김") { engine.appended.count == 3 }
        XCTAssertEqual(engine.appended, [1, 2, 3])
        // 사용자 용어집이 엔진 낱말 맨 앞에, 그다음 기본 용어
        XCTAssertEqual(engine.lastOptions?.vocabulary.first, "Cheoma")
        XCTAssertTrue(engine.lastOptions?.vocabulary.contains("Docker") == true)

        engine.sendPartial("도커 띄워")
        try await waitUntil("중간 글") { model.dictationLive.text == "Docker 띄워" }

        controller.handle(.ended)
        XCTAssertEqual(model.dictation?.stage, .transcribing)
        XCTAssertEqual(model.dictation?.text, "Docker 띄워")
        try await waitUntil("붙여 넣음") { !inserted.isEmpty }
        XCTAssertEqual(inserted, ["Cheoma에서 Docker 띄워 줘"])
        XCTAssertEqual(model.dictation?.stage, .inserted("입력됨"))
        XCTAssertFalse(audio.isRunning)
        try await waitUntil("귀가 사라짐") { model.dictation == nil }
        XCTAssertEqual(engine.cancelCount, 0)
        XCTAssertFalse(controller.hasActiveSession)
    }

    /// 톡 친 것(⌥ 단축키 포함)은 엔진을 건드리지 않고, 두 번째 누름을 기다리는 동안만 마이크를 열어 둔다
    func testTapNeverReachesEngine() async throws {
        let (controller, model) = try makeController()
        controller.handle(.armed)
        audio.send(1)
        controller.handle(.cancelled)
        XCTAssertNil(model.dictation)
        XCTAssertTrue(audio.isRunning)
        try await waitUntil("마이크 닫힘") { !audio.isRunning }
        XCTAssertEqual(engine.beginCount, 0)
        XCTAssertEqual(engine.cancelCount, 0)
    }

    func testDoubleTapReusesOpenMicrophone() async throws {
        let (controller, model) = try makeController()
        engine.results = ["계속 들어요"]
        controller.handle(.armed)
        controller.handle(.cancelled)
        controller.handle(.armed)
        controller.handle(.began(handsFree: true))
        XCTAssertEqual(audio.stopCount, 0)
        XCTAssertEqual(model.dictation?.handsFree, true)
        audio.send(5)
        try await waitUntil("엔진에 넘김") { engine.appended == [5] }
        controller.handle(.ended)
        try await waitUntil("붙여 넣음") { inserted == ["계속 들어요"] }
    }

    func testCancelAfterBeganCancelsEngineSilently() async throws {
        let (controller, model) = try makeController()
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        try await waitUntil("엔진 시작") { engine.beginCount == 1 }
        controller.handle(.cancelled)
        XCTAssertNil(model.dictation)
        XCTAssertFalse(audio.isRunning)
        try await waitUntil("엔진 취소") { engine.cancelCount >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.finishCount, 0)
        XCTAssertEqual(inserted, [])
        XCTAssertNil(model.dictation)
    }

    func testNothingHeard() async throws {
        let (controller, model) = try makeController()
        engine.results = ["  "]
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("못 들음") { model.dictation?.stage == .failed("인식된 말 없음") }
        XCTAssertEqual(inserted, [])
        try await waitUntil("귀가 사라짐") { model.dictation == nil }
    }

    func testEngineFailureShowsReason() async throws {
        let (controller, model) = try makeController()
        engine.beginError = DictationError.engineUnavailable("whisper-cli가 없습니다")
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        try await waitUntil("실패 표시") { model.dictation?.stage == .failed("whisper-cli 없음") }
        controller.handle(.ended)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.finishCount, 0)
        XCTAssertEqual(inserted, [])
        // 키를 늦게 떼도 옮기는 중으로 바뀌어 멈춰 있지 않는다
        XCTAssertNotEqual(model.dictation?.stage, .transcribing)
        XCTAssertFalse(audio.isRunning)
    }

    /// 마이크 권한이 없으면 귀 대신 누를 수 있는 알림 (시스템 설정 › 마이크)
    func testMicrophoneDeniedShowsClickableAlert() throws {
        let (controller, model) = try makeController()
        microphone = .denied
        controller.handle(.armed)
        XCTAssertFalse(audio.isRunning)
        XCTAssertNil(model.alert)
        controller.handle(.began(handsFree: false))
        XCTAssertNil(model.dictation)
        XCTAssertEqual(model.alert?.symbol, "mic.slash.fill")
        XCTAssertEqual(model.alert?.url, DictationSystemSettings.Pane.microphone.url)
        controller.handle(.ended)
        XCTAssertEqual(engine.beginCount, 0)
    }

    /// 앞 말을 글로 옮기는 동안 다시 눌러도 앞 말은 그대로 붙고, 새 말은 모아 두었다가 차례대로 엔진에 넘긴다
    func testBackToBackWaitsForPreviousFinish() async throws {
        let (controller, model) = try makeController()
        engine.results = ["첫째", "둘째"]
        engine.holdsFinish = true
        controller.handle(.armed)
        audio.send(1)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("첫째 finish") { engine.isHoldingFinish }

        controller.handle(.armed)
        audio.send(2)
        controller.handle(.began(handsFree: false))
        audio.send(3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.beginCount, 1)
        XCTAssertEqual(model.dictation?.stage, .listening)

        engine.holdsFinish = false
        engine.releaseFinish()
        try await waitUntil("첫째 붙임") { inserted == ["첫째"] }
        // 새 듣기가 귀를 쓰고 있어서 붙였어요로 바꾸지 않는다
        XCTAssertEqual(model.dictation?.stage, .listening)
        try await waitUntil("둘째 시작") { engine.appended == [1, 2, 3] }
        audio.send(4)
        controller.handle(.ended)
        try await waitUntil("둘째 붙임") { inserted == ["첫째", "둘째"] }
        XCTAssertEqual(engine.appended, [1, 2, 3, 4])
    }

    /// 앞 말을 글로 옮기는 동안 짧게 말하고 떼도(엔진이 아직 시작하지 않음) 그 말을 버리지 않는다
    func testShortPressBehindLongFinishKeepsItsAudio() async throws {
        let (controller, _) = try makeController()
        engine.results = ["첫째", "둘째"]
        engine.holdsFinish = true
        controller.handle(.armed)
        audio.send(1)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("첫째 finish") { engine.isHoldingFinish }

        controller.handle(.armed)
        audio.send(2)
        controller.handle(.began(handsFree: false))
        audio.send(3)
        controller.handle(.ended)
        // 키를 뗀 뒤 조금 더 듣는 시간이 지나 마이크가 닫힌다. 엔진은 아직 앞 말을 옮기는 중
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(engine.beginCount, 1)

        engine.holdsFinish = false
        engine.releaseFinish()
        try await waitUntil("둘 다 붙임") { inserted == ["첫째", "둘째"] }
        XCTAssertEqual(engine.appended, [1, 2, 3])
    }

    /// 다음 받아쓰기 단축키를 누르고 말하는 동안 앞 말을 ⌥⌘V로 보내지 않는다. 키를 떼면 앞 말, 그다음 새 말
    func testPasteWaitsWhileNextHotKeyIsHeld() async throws {
        let (controller, _) = try makeController()
        controller.timing.modifierRelease = 0.05
        engine.results = ["첫째", "둘째"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        modifiersDown = true
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        try await waitUntil("첫째 finish") { engine.finishCount == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(inserted, [], "단축키를 누르고 있는 동안은 붙여 넣지 않는다")

        modifiersDown = false
        controller.handle(.ended)
        try await waitUntil("둘 다 붙임") { inserted == ["첫째", "둘째"] }
        XCTAssertEqual(insertedMethods, [.automatic, .automatic])
    }

    /// 수식키를 끝내 떼지 않으면 ⌘V를 보내지 않고 클립보드에만 넣는다
    func testStuckModifierCopiesOnly() async throws {
        let (controller, _) = try makeController()
        engine.results = ["말"]
        modifiersDown = true
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("넣음") { !inserted.isEmpty }
        XCTAssertEqual(insertedMethods, [.clipboardOnly])
    }

    /// 듣는 도중 마이크가 바뀌면 그때까지 들은 것을 옮긴다
    func testInterruptionTranscribesWhatWasHeard() async throws {
        let (controller, _) = try makeController()
        engine.results = ["여기까지 말함"]
        controller.handle(.armed)
        audio.send(1)
        controller.handle(.began(handsFree: true))
        try await waitUntil("엔진에 넘김") { engine.appended == [1] }
        audio.interrupt(.microphoneUnavailable("마이크가 변경되었습니다"))
        try await waitUntil("붙여 넣음") { inserted == ["여기까지 말함"] }
        XCTAssertEqual(engine.finishCount, 1)
        XCTAssertEqual(engine.cancelCount, 0)
        XCTAssertFalse(controller.hasActiveSession)
    }

    /// 소리가 하나도 오지 않았으면 이유만 짧게 알린다
    func testInterruptionWithoutAudioShowsHeadline() async throws {
        let (controller, model) = try makeController()
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        audio.interrupt(.microphoneUnavailable("마이크에서 소리가 들어오지 않습니다"))
        XCTAssertEqual(model.dictation?.stage, .failed("마이크 소리 없음"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.finishCount, 0)
        XCTAssertEqual(inserted, [])
    }

    /// 엔진이 끝내 답하지 않아도 실패로 끝내고, 다음 받아쓰기는 엔진을 받는다
    func testStuckFinishTimesOutAndFreesEngine() async throws {
        let (controller, model) = try makeController()
        controller.timing.finishLimit = 0.1
        engine.results = ["멈춤"]
        engine.holdsFinish = true
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("실패 표시") { model.dictation?.stage == .failed("시간 초과") }
        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1)

        // 멈췄던 finish가 늦게 끝나도 그 글은 버린다
        engine.holdsFinish = false
        engine.releaseFinish()
        try await waitUntil("멈췄던 finish가 끝남") { engine.results.isEmpty }
        engine.results = ["다음"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("다음 붙임") { inserted == ["다음"] }
        XCTAssertFalse(inserted.contains("멈춤"))
    }

    /// 블루투스 헤드셋 마이크는 정말 듣기 시작할 때 연다 (⌥← 같은 단축키에 헤드셋이 통화 음질로 바뀌지 않게)
    func testBluetoothMicrophoneOpensOnlyWhenListening() async throws {
        let (controller, _) = try makeController()
        audio.opensBluetooth = true
        engine.results = ["헤드셋으로"]
        controller.handle(.armed)
        controller.handle(.cancelled)
        XCTAssertEqual(audio.startCount, 0)

        controller.handle(.armed)
        XCTAssertFalse(audio.isRunning)
        controller.handle(.began(handsFree: false))
        XCTAssertTrue(audio.isRunning)
        audio.send(7)
        try await waitUntil("엔진에 넘김") { engine.appended == [7] }
        controller.handle(.ended)
        try await waitUntil("붙여 넣음") { inserted == ["헤드셋으로"] }
    }

    /// 화면을 잠그거나 잠자면 듣던 것을 옮기지 않고 버린다
    func testSuspendDropsListening() async throws {
        let (controller, model) = try makeController()
        engine.results = ["잠금 화면에서 들은 말"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: true))
        try await waitUntil("엔진 시작") { engine.beginCount == 1 }
        controller.suspend()
        XCTAssertFalse(audio.isRunning)
        XCTAssertNil(model.dictation)
        XCTAssertFalse(controller.hasActiveSession)
        try await waitUntil("엔진 취소") { engine.cancelCount >= 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(engine.finishCount, 0)
    }

    // MARK: 진짜 단축키 감시와 함께 (가짜 감시 · 탭)

    /// 받아쓰기를 켜서 단축키 감시를 만든다
    private func makeControllerWithMonitor(configure: (inout DictationSettings) -> Void = { _ in })
        throws -> (DictationController, NotchModel, PushToTalkMonitor) {
        usesMonitor = true
        let (controller, model) = try makeController {
            configure(&$0)
            $0.isEnabled = false
        }
        controller.settings.isEnabled = true
        let monitor = try XCTUnwrap(monitor)
        XCTAssertTrue(monitor.isRunning)
        return (controller, model, monitor)
    }

    private func hotKey(_ down: Bool, after seconds: TimeInterval = 0) throws {
        now += seconds
        hotKeyDown = down
        let flags = down ? PushToTalkStateMachine.Modifiers.option | PushToTalkStateMachine.Modifiers.rightOption | 0x100 : 0x100
        try XCTUnwrap(monitor).handle(try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61)))
    }

    /// 두 번 빠르게 눌러 손을 떼고 듣는다
    private func doubleTap() throws {
        try hotKey(true, after: 1)
        try hotKey(false, after: 0.05)
        try hotKey(true, after: 0.15)
        try hotKey(false, after: 0.05)
    }

    /// 누르고 있다가 떼는 한 번 (기준 시간이 지나 듣기 시작한다)
    private func hold(saying text: String) async throws {
        engine.results = [text]
        try hotKey(true, after: 1)
        now += 0.2
        try XCTUnwrap(monitor).tick()
        try hotKey(false, after: 0.3)
        try await waitUntil("붙여 넣음: \(text)") { inserted.last == text }
    }

    /// 마이크 권한이 없어 시작하지 못한 손 떼고 듣기: 단축키 감시도 처음으로 돌린다 (Esc 탭이 남거나 다음 누름이 끝내기로 쓰이지 않게)
    func testHandsFreeStartFailureResetsMonitor() async throws {
        let (controller, model, monitor) = try makeControllerWithMonitor()
        microphone = .denied
        try doubleTap()
        XCTAssertEqual(model.alert?.symbol, "mic.slash.fill")
        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertFalse(monitor.isActive)
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertFalse(monitor.watchesPointer)
        XCTAssertFalse(monitor.interceptKey(down: true, keyCode: 53, at: 0), "다음 Esc는 앞 앱에 간다")

        microphone = .authorized
        try await hold(saying: "다음")
        XCTAssertEqual(inserted, ["다음"])
        controller.settings.isEnabled = false
        XCTAssertEqual(hooks.installedCount, 0)
    }

    /// 엔진이 시작하지 못한 손 떼고 듣기 (whisper-cli · 모델이 없음): 실패를 보이고 단축키 감시를 처음으로
    func testHandsFreeEngineFailureResetsMonitor() async throws {
        let (controller, model, monitor) = try makeControllerWithMonitor()
        engine.beginError = DictationError.engineUnavailable("whisper-cli가 없습니다")
        try doubleTap()
        try await waitUntil("실패 표시") { model.dictation?.stage == .failed("whisper-cli 없음") }
        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertFalse(monitor.isActive)
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertFalse(audio.isRunning)

        engine.beginError = nil
        try await hold(saying: "다음")
        XCTAssertEqual(inserted, ["다음"])
        controller.settings.isEnabled = false
    }

    /// 사용자가 친 키는 넣는 쪽에 알린다 (받아쓰기가 보낸 ⌘V는 빼고)
    func testTypedKeysReachInserter() throws {
        let (controller, _, monitor) = try makeControllerWithMonitor()
        let typed = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: typed)))
        XCTAssertEqual(typedCount, 1)
        let paste = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        paste.flags = .maskCommand
        paste.setIntegerValueField(.eventSourceUserData, value: DictationPasteKey.eventMarker)
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: paste)))
        try hotKey(true, after: 1)
        try hotKey(false, after: 0.05)
        XCTAssertEqual(typedCount, 1)
        controller.settings.isEnabled = false
    }

    /// 엔진이 시작하는 데 너무 오래 걸리면 버리고, 늦게 끝난 시작은 무시하고, 다음 받아쓰기는 엔진을 받는다
    func testStuckBeginTimesOut() async throws {
        let (controller, model) = try makeController()
        controller.timing.beginLimit = 0.1
        engine.holdsBegin = true
        engine.results = ["멈춤"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        try await waitUntil("실패 표시") { model.dictation?.stage == .failed("시간 초과") }
        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1)
        XCTAssertFalse(controller.hasActiveSession)
        XCTAssertFalse(audio.isRunning)
        // 키를 늦게 떼도 할 일이 없다
        controller.handle(.ended)
        engine.holdsBegin = false
        engine.releaseBegin()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.finishCount, 0)
        XCTAssertEqual(inserted, [])

        engine.results = ["다음"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        try await waitUntil("다음 붙임") { inserted == ["다음"] }
    }

    /// 다음 받아쓰기 단축키를 끝까지 누르고 있으면 앞 말은 ⌘V 없이 클립보드에만 넣는다 (그래도 차례는 앞 말이 먼저)
    func testHeldNextSessionMakesPreviousCopyOnly() async throws {
        let (controller, _) = try makeController()
        controller.timing.limit = 0.15
        controller.timing.modifierRelease = 0.05
        engine.results = ["첫째", "둘째"]
        modifiersDown = true
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        controller.handle(.ended)
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        try await waitUntil("둘 다 넣음") { inserted == ["첫째", "둘째"] }
        XCTAssertEqual(insertedMethods, [.clipboardOnly, .clipboardOnly])
    }

    /// 듣는 동안만 화면이 꺼지지 않게 한다 (시작하지 못한 것은 잡지 않는다)
    func testKeepsDisplayAwakeOnlyWhileListening() async throws {
        let (controller, _) = try makeController()
        engine.results = ["말"]
        controller.handle(.armed)
        XCTAssertEqual(displayAwake, 0)
        controller.handle(.began(handsFree: true))
        XCTAssertEqual(displayAwake, 1)
        controller.handle(.ended)
        try await waitUntil("붙여 넣음") { inserted == ["말"] }
        XCTAssertEqual(displayAwake, 0)

        controller.handle(.armed)
        controller.handle(.began(handsFree: true))
        controller.suspend()
        XCTAssertEqual(displayAwake, 0)

        microphone = .denied
        controller.handle(.armed)
        controller.handle(.began(handsFree: false))
        XCTAssertEqual(displayAwake, 0)
    }

    /// 처음 켤 때 마이크를 먼저 묻고, 답한 뒤에 손쉬운 사용을 묻는다 (묻는 창이 한꺼번에 뜨지 않게)
    func testEnablingAsksMicrophoneBeforeAccessibility() async throws {
        let (controller, _) = try makeController { $0.isEnabled = false }
        microphone = .notDetermined
        trusted = false
        controller.settings.isEnabled = true
        XCTAssertEqual(accessibilityRequests, 0)
        try await waitUntil("손쉬운 사용을 물음") { accessibilityRequests == 1 }
        XCTAssertEqual(permissionLog, ["마이크", "손쉬운 사용"])
        controller.settings.isEnabled = false
    }

    /// 손쉬운 사용 권한 없이 켜면 그때 한 번 묻는다
    func testEnablingWithoutAccessibilityAsksOnce() throws {
        let (controller, _) = try makeController { $0.isEnabled = false }
        trusted = false
        controller.settings.isEnabled = true
        XCTAssertEqual(accessibilityRequests, 1)
        controller.settings.isEnabled = false
        controller.settings.isEnabled = true
        XCTAssertEqual(accessibilityRequests, 1)
        controller.settings.isEnabled = false
    }

    /// 클립보드 읽기 허용 상태는 설정 화면을 열 때 다시 읽는다
    func testClipboardAccessIsRefreshed() throws {
        let (controller, _) = try makeController()
        XCTAssertEqual(controller.clipboardAccess, .allowed)
        clipboardAccess = .notAsked
        controller.refreshStatus()
        XCTAssertEqual(controller.clipboardAccess, .notAsked)
    }

    func testLimitEndsLongDictation() async throws {
        let (controller, model) = try makeController()
        controller.timing.limit = 0.05
        engine.results = ["오래 말함"]
        controller.handle(.armed)
        controller.handle(.began(handsFree: true))
        try await waitUntil("최대 시간") { inserted == ["오래 말함"] }
        XCTAssertFalse(controller.hasActiveSession)
        // 늦게 온 키 떼기는 무시한다
        controller.handle(.ended)
        XCTAssertNotEqual(model.dictation?.stage, .transcribing)
    }

    func testDisablingStopsMicrophoneAndHidesEars() async throws {
        let (controller, model) = try makeController()
        controller.handle(.armed)
        controller.handle(.began(handsFree: true))
        try await waitUntil("엔진 시작") { engine.beginCount == 1 }
        controller.settings.isEnabled = false
        XCTAssertFalse(audio.isRunning)
        XCTAssertNil(model.dictation)
        XCTAssertFalse(controller.hasActiveSession)
        try await waitUntil("엔진 취소") { engine.cancelCount >= 1 }
    }

    func testSettingsArePersisted() throws {
        let (controller, _) = try makeController()
        controller.settings.pasteMethod = .clipboardOnly
        controller.settings.glossaryText = "도커 → Docker"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let loaded = DictationSettings.load(from: defaults)
        XCTAssertEqual(loaded.pasteMethod, .clipboardOnly)
        XCTAssertEqual(loaded.glossaryText, "도커 → Docker")
    }

    // MARK: 다듬기

    func testEngineOptionsMergeUserAndBuiltInGlossary() {
        var settings = DictationSettings()
        settings.localeIdentifier = "en-US"
        settings.whisperModelPath = "  ~/models/a.bin \n"
        settings.glossaryText = "트목스 → tmux\nSwiftData\n도커 → 도커"
        let glossary = DictationGlossary(userText: settings.glossaryText)
        let options = DictationController.engineOptions(settings: settings, glossary: glossary)
        XCTAssertEqual(options.localeIdentifier, "en-US")
        XCTAssertEqual(options.whisperModelPath, "~/models/a.bin")
        XCTAssertEqual(Array(options.vocabulary.prefix(2)), ["tmux", "SwiftData"])
        XCTAssertTrue(options.vocabulary.contains("Claude Code"))
        // 사용자가 끈 기본 바꾸기는 엔진에도 알리지 않는다
        XCTAssertFalse(options.vocabulary.contains("Docker"))
    }

    func testFinalTextAppliesGlossaryAndTrims() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(DictationController.finalText("  깃헙 에 푸시하고 도커 를 띄워 줘 \n", glossary: glossary),
                       "GitHub에 푸시하고 Docker를 띄워 줘")
        XCTAssertEqual(DictationController.finalText(" \n", glossary: glossary), "")
    }

    /// 귀에는 짧은 글만 (다 적은 이유는 기록에)
    func testErrorHeadlinesFitTheEar() {
        let errors: [DictationError] = [
            .microphoneDenied, .nothingHeard, .microphoneUnavailable("마이크가 변경되었습니다"),
            .microphoneUnavailable("마이크 연결이 끊어졌습니다"), .microphoneUnavailable("마이크에서 소리가 들어오지 않습니다"),
            .microphoneUnavailable("마이크 권한을 허용한 후 다시 시도하십시오"), .microphoneUnavailable("입력 장치 없음"),
            .microphoneUnavailable("장치가 응답하지 않습니다 (오류 -10868)"), .microphoneUnavailable("알 수 없는 까닭이 아주 길게 적힌 것"),
            .engineUnavailable(DictationController.appleUnavailableReason),
            .engineUnavailable("whisper-cli가 없습니다. brew install whisper-cpp로 설치하십시오"),
            .engineUnavailable("whisper 모델 파일(ggml-*.bin)을 찾을 수 없습니다. ~/models에 넣거나 설정에서 선택하십시오"),
            .engineUnavailable("whisper 처리 시간 초과"), .engineUnavailable("whisper-cli 실패: bad"),
            .engineUnavailable("Apple 음성 인식이 이 언어(xx)를 지원하지 않습니다"), .engineUnavailable("아주 길고 처음 보는 엔진 오류 문장이에요"),
            .insertFailed("무엇"),
        ]
        // 오른쪽 귀의 글 칸은 150 - 10 - 14 = 126pt (12pt 굵게). 줄이지 않고 들어가야 한다
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for error in errors {
            let width = NSAttributedString(string: error.headline, attributes: [.font: font]).size().width
            XCTAssertLessThanOrEqual(width, 126, error.headline)
        }
        XCTAssertEqual(DictationError.microphoneUnavailable("마이크가 변경되었습니다").headline, "마이크 변경됨")
        XCTAssertEqual(DictationError.engineUnavailable(DictationController.appleUnavailableReason).headline, "macOS 26 필요")
        XCTAssertEqual(DictationError.engineUnavailable("짧은 이유").headline, "짧은 이유")
        // 모르는 엔진 오류를 말이 불분명했다고 하지 않는다
        XCTAssertEqual(DictationError.engineUnavailable("아주 길고 처음 보는 엔진 오류 문장이에요").headline, "받아쓰기 실패")
        XCTAssertEqual(DictationError.engineUnavailable("Apple 음성 인식을 시작하지 못했습니다: 무엇").headline, "음성 인식 시작 실패")
    }

    func testGlobeKeyNotes() {
        XCTAssertNil(DictationSystemSettings.globeKeyNote(usage: 0))
        XCTAssertTrue(DictationSystemSettings.globeKeyNote(usage: 1)?.contains("입력 소스") == true)
        XCTAssertTrue(DictationSystemSettings.globeKeyNote(usage: 2)?.contains("이모지") == true)
        XCTAssertTrue(DictationSystemSettings.globeKeyNote(usage: 3)?.contains("받아쓰기") == true)
        // macOS 받아쓰기는 두 번 누를 때만 켜진다. 두 번 눌러 듣기를 껐으면 겹치지 않는다
        XCTAssertNil(DictationSystemSettings.globeKeyNote(usage: 3, allowsHandsFree: false))
        XCTAssertNotNil(DictationSystemSettings.globeKeyNote(usage: 1, allowsHandsFree: false))
        // 시스템 설정 › 키보드에 있는 이름 그대로
        XCTAssertTrue(DictationSystemSettings.globeKeyNote(usage: 1)?.contains("‘🌐︎ 키를 누를 때 실행할 동작’") == true)
        XCTAssertTrue(DictationSystemSettings.globeKeyNote(usage: 1)?.contains("‘안\u{00A0}함’") == true)
        XCTAssertNotNil(DictationSystemSettings.globeKeyNote(usage: nil))
        XCTAssertFalse(DictationSystemSettings.globeKeyNote(usage: nil)?.contains("이 Mac에서는") ?? true)
    }

    func testResultStages() {
        let timing = DictationController.Timing()
        XCTAssertEqual(DictationController.stage(for: .inserted(.commandV), timing: timing).0, .inserted("입력됨"))
        XCTAssertEqual(DictationController.stage(for: .inserted(.ownPanel), timing: timing).0, .inserted("입력됨"))
        XCTAssertEqual(DictationController.stage(for: .inserted(.clipboardOnly), timing: timing).0, .inserted("클립보드에 복사됨"))
        XCTAssertEqual(DictationController.stage(for: .copiedOnly(reason: "암호 필드여서 클립보드에만 복사했습니다"), timing: timing).0,
                       .failed("암호 필드 · 복사만 됨"))
        XCTAssertEqual(DictationController.stage(for: .failed("⌘V를 보낼 수 없음"), timing: timing).0,
                       .failed("⌘V를 보낼 수 없음"))
        XCTAssertEqual(DictationController.shortCopiedReason("보안 입력이 켜져 있어 클립보드에만 복사했습니다"), "보안 입력 · 복사만 됨")
        XCTAssertEqual(DictationController.shortCopiedReason("손쉬운 사용 권한이 없어 클립보드에만 복사했습니다"), "권한 없음 · 복사만 됨")
        XCTAssertEqual(DictationController.shortCopiedReason("텍스트 입력란이 아니어서 클립보드에만 복사했습니다"), "입력란 아님 · 복사만 됨")
    }

    func testSystemSettingsAddresses() {
        XCTAssertEqual(DictationSystemSettings.Pane.microphone.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(DictationSystemSettings.Pane.accessibility.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(DictationSystemSettings.Pane.pasteboard.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }
}

/// 받아쓰기가 보낸 ⌘V는 단축키 감시가 넘긴다 (막 다시 누른 단축키를 버리지 않게)
@MainActor
final class PushToTalkOwnPasteTests: XCTestCase {
    func testOwnPasteKeyDoesNotCancelPress() throws {
        var now: TimeInterval = 100
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { now })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        let flags = PushToTalkStateMachine.Modifiers.option | PushToTalkStateMachine.Modifiers.rightOption | 0x100
        monitor.handle(try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61)))
        XCTAssertEqual(events, [.armed])

        // 만들기만 하고 보내지 않는다
        let paste = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        paste.flags = .maskCommand
        paste.setIntegerValueField(.eventSourceUserData, value: DictationPasteKey.eventMarker)
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: paste)))
        XCTAssertEqual(events, [.armed])

        let typed = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: typed)))
        XCTAssertEqual(events, [.armed, .cancelled])
        now += 1
        monitor.stop()
    }

    /// 톡 친 뒤에만 마이크를 잠깐 열어 둔다. ⌥← 같은 단축키로 버린 것은 두 번 누르기를 기다리지 않는다
    func testTapWaitsForSecondTapButChordDoesNot() throws {
        var now: TimeInterval = 100
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { now })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { [unowned monitor] event in
            events.append(event)
            if event == .cancelled { XCTAssertEqual(monitor.isWaitingForSecondTap, events.count == 2 && now == 100.05) }
        }
        let down = PushToTalkStateMachine.Modifiers.option | PushToTalkStateMachine.Modifiers.rightOption | 0x100
        func flags(_ raw: UInt) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61))
        }
        monitor.handle(try flags(down))
        now = 100.05
        monitor.handle(try flags(0x100))
        XCTAssertEqual(events, [.armed, .cancelled])
        XCTAssertTrue(monitor.isWaitingForSecondTap)

        now = 101
        monitor.handle(try flags(down))
        let arrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: arrow)))
        XCTAssertEqual(events, [.armed, .cancelled, .armed, .cancelled])
        XCTAssertFalse(monitor.isWaitingForSecondTap)
        monitor.stop()
    }

    func testAbandonForgetsHeldKey() throws {
        var now: TimeInterval = 100
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { now },
                                        isHotKeyPhysicallyDown: { _ in true })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        let down = PushToTalkStateMachine.Modifiers.option | PushToTalkStateMachine.Modifiers.rightOption | 0x100
        func flags(_ raw: UInt) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61))
        }
        monitor.handle(try flags(down))
        now += 0.2
        monitor.tick()
        XCTAssertEqual(events, [.armed, .began(handsFree: false)])
        monitor.abandon()
        XCTAssertFalse(monitor.isActive)
        now += 1
        monitor.handle(try flags(0x100))
        XCTAssertEqual(events, [.armed, .began(handsFree: false)])
        monitor.stop()
    }
}

// MARK: - 가짜 마이크 · 엔진

extension DictationController {
    /// 마이크 · 단축키 · 클립보드에 닿지 않고, 이 맥의 받아쓰기 설정도 건드리지 않는 받아쓰기 (설정 창 테스트용)
    static func forTests(notch: NotchModel) -> DictationController {
        let suiteName = "io.github.m-kim77.cheoma.test.dictation-idle"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let dependencies = Dependencies(
            audio: FakeAudioSource(), makeEngine: { _ in FakeDictationEngine() },
            insert: { _, _, _ in .failed("시험") }, microphoneStatus: { .authorized }, requestMicrophone: { false },
            accessibilityTrusted: { true }, modifiersHeld: { _ in false }, ownPanelIsKey: { false })
        return DictationController(notch: notch, defaults: defaults, dependencies: dependencies)
    }
}

enum DictationTestAudio {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// 첫 샘플에 표시값을 넣은 버퍼 (엔진이 받은 차례를 확인한다)
    static func buffer(_ marker: Float, frames: AVAudioFrameCount = 480) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0][0] = marker
        return buffer
    }
}

private final class FakeAudioSource: DictationAudioSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onInterrupted: ((DictationError) -> Void)?
    /// 기본 입력이 블루투스 헤드셋인 것처럼
    var opensBluetooth = false
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(prefersBuiltInMicrophone: Bool) throws -> AVAudioFormat {
        startCount += 1
        isRunning = true
        return DictationTestAudio.format
    }

    func stop() {
        if isRunning { stopCount += 1 }
        isRunning = false
    }

    func opensBluetoothInput(prefersBuiltInMicrophone: Bool) -> Bool { opensBluetooth && !isRunning }

    /// 마이크가 바뀌거나 빠진 것처럼 (닫은 뒤 알린다)
    func interrupt(_ error: DictationError) {
        stop()
        onInterrupted?(error)
    }

    /// 오디오 스레드에서 온 것처럼
    func send(_ marker: Float) {
        guard isRunning else { return }
        let handler = onBuffer
        let buffer = DictationTestAudio.buffer(marker)
        DispatchQueue.global().sync { handler?(buffer) }
    }
}

final class FakeDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [Float] = []
    private var _beginCount = 0
    private var _finishCount = 0
    private var _cancelCount = 0
    private var _lastOptions: DictationEngineOptions?
    private var partial: (@Sendable (String) -> Void)?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var _results: [String] = []
    private var _holdsFinish = false
    private var _beginError: Error?
    private var _holdsBegin = false
    private var beginContinuation: CheckedContinuation<Void, Never>?

    var appended: [Float] { lock.withLock { _appended } }
    var beginCount: Int { lock.withLock { _beginCount } }
    var finishCount: Int { lock.withLock { _finishCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var lastOptions: DictationEngineOptions? { lock.withLock { _lastOptions } }
    var isHoldingFinish: Bool { lock.withLock { finishContinuation != nil } }
    var results: [String] {
        get { lock.withLock { _results } }
        set { lock.withLock { _results = newValue } }
    }
    var holdsFinish: Bool {
        get { lock.withLock { _holdsFinish } }
        set { lock.withLock { _holdsFinish = newValue } }
    }
    var beginError: Error? {
        get { lock.withLock { _beginError } }
        set { lock.withLock { _beginError = newValue } }
    }
    /// begin이 releaseBegin을 부를 때까지 돌아오지 않는다 (멈춘 엔진처럼)
    var holdsBegin: Bool {
        get { lock.withLock { _holdsBegin } }
        set { lock.withLock { _holdsBegin = newValue } }
    }

    func availability(options: DictationEngineOptions) async -> DictationAvailability { .ready }
    func prepare(options: DictationEngineOptions) async {}

    func begin(format: AVAudioFormat, options: DictationEngineOptions,
               onPartial: @escaping @Sendable (String) -> Void) async throws {
        let (error, holds) = lock.withLock { () -> (Error?, Bool) in
            _beginCount += 1
            _lastOptions = options
            partial = onPartial
            return (_beginError, _holdsBegin)
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { beginContinuation = continuation }
            }
        }
        if let error { throw error }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let marker = buffer.floatChannelData![0][0]
        lock.withLock { _appended.append(marker) }
    }

    func finish() async throws -> String {
        let holds = lock.withLock { () -> Bool in
            _finishCount += 1
            return _holdsFinish
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { finishContinuation = continuation }
            }
        }
        return lock.withLock { _results.isEmpty ? "" : _results.removeFirst() }
    }

    func cancel() {
        lock.withLock { _cancelCount += 1 }
    }

    func sendPartial(_ text: String) {
        let partial = lock.withLock { self.partial }
        DispatchQueue.global().async { partial?(text) }
    }

    func releaseBegin() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { beginContinuation = nil }
            return beginContinuation
        }
        continuation?.resume()
    }

    func releaseFinish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { finishContinuation = nil }
            return finishContinuation
        }
        continuation?.resume()
    }
}

import AppKit
import AVFoundation
import Combine
import IOKit.pwr_mgt
import os

/// 받아쓰기를 잇는다: 단축키 → 마이크 → 엔진 → 용어집 → 붙여넣기 → 노치 귀.
/// 설정을 저장하고, 설정 화면에 권한 · 엔진 상태를 보여 준다.
///
/// 듣기 한 번:
/// - armed: 마이크를 열고 버퍼를 모은다 (엔진은 아직 부르지 않는다. 톡 친 것이나 ⌥ 단축키면 그냥 닫는다)
/// - began: 노치에 귀를 띄우고 엔진을 시작한다. 시작하는 동안 온 버퍼는 모아 둔 것과 함께 차례대로 넘긴다
/// - ended: 조금 더 들은 뒤 마이크를 닫고, 글로 옮겨 용어집을 적용하고 붙여 넣는다
/// - cancelled: 소리 없이 버린다
/// 엔진은 한 번에 하나만 듣는다. 앞 듣기가 글로 옮기기를 마친 뒤에 다음 듣기를 엔진에 넘긴다 (그동안 소리는 모아 둔다)
@MainActor
final class DictationController: ObservableObject {
    /// 한 번에 들을 수 있는 가장 긴 시간. 넘으면 키를 뗀 것처럼 글로 옮긴다
    nonisolated static let maximumDuration: TimeInterval = 120
    static let appleUnavailableReason = "Apple 음성 인식에는 macOS 26 이상이 필요합니다"
    /// 설정 화면에서 고를 수 있는 언어
    struct Language: Hashable {
        let identifier: String
        let title: String
    }

    static let languages = [
        Language(identifier: "ko-KR", title: "한국어"), Language(identifier: "en-US", title: "English"),
        Language(identifier: "ja-JP", title: "日本語"),
    ]

    /// 기다리는 시간들 (테스트에서 줄인다)
    struct Timing {
        /// 키를 뗀 뒤에도 이만큼 더 듣는다 (마지막 버퍼가 0.1초쯤 늦게 온다)
        var tail: TimeInterval = 0.12
        /// 톡 친 뒤 마이크를 이만큼 열어 둔다 (두 번 누르기의 두 번째를 기다리는 동안 다시 열지 않게)
        var linger: TimeInterval = PushToTalkStateMachine.doubleTapWindow + 0.05
        /// 붙였어요를 보여 주는 시간
        var inserted: TimeInterval = 1.0
        /// 못 했어요를 보여 주는 시간
        var failed: TimeInterval = 2.2
        /// 붙여 넣기 전에 수식키를 뗄 때까지 기다리는 가장 긴 시간 (⌥를 누른 채면 ⌥⌘V가 된다).
        /// 다음 받아쓰기의 단축키를 누르고 있으면 그 키를 뗄 때까지 더 기다린다
        var modifierRelease: TimeInterval = 3
        /// 용어집 · 모델 경로를 고치는 동안 엔진을 매번 다시 준비하지 않는다
        var prepareDebounce: TimeInterval = 0.8
        /// 한 번에 들을 수 있는 가장 긴 시간
        var limit: TimeInterval = DictationController.maximumDuration
        /// 엔진이 시작하는 데 이보다 오래 걸리면 버린다 (처음 모델을 올릴 때는 10초 넘게 걸릴 수 있다)
        var beginLimit: TimeInterval = 30
        /// 글로 옮기는 데 이 시간 + 들은 시간보다 오래 걸리면 버린다 (다음 듣기가 끝없이 기다리지 않게)
        var finishLimit: TimeInterval = 30
    }

    /// 바깥 세상과 닿는 것들. 테스트에서는 가짜를 넣는다
    struct Dependencies {
        var audio: DictationAudioSource
        var makeEngine: @MainActor (DictationEngineKind) -> DictationEngine?
        var insert: @MainActor (_ text: String, _ settings: DictationSettings, _ ownPanelIsKey: Bool) async -> DictationInsertionResult
        var microphoneStatus: @MainActor () -> AVAuthorizationStatus
        var requestMicrophone: @MainActor () async -> Bool
        var accessibilityTrusted: @MainActor () -> Bool
        /// 붙여 넣기에 끼어들 수식키를 누르고 있는지
        var modifiersHeld: @MainActor (DictationHotKey) -> Bool
        /// Cheoma 노치 창이 키 창인지 (에이전트 답 입력란)
        var ownPanelIsKey: @MainActor () -> Bool
        /// 손쉬운 사용 권한을 묻는다 (시스템이 묻는 창 + 시스템 설정)
        var requestAccessibility: @MainActor () -> Void = {}
        /// 클립보드 내용을 읽어도 되는지 (내용은 읽지 않는다)
        var clipboardAccess: @MainActor () -> DictationClipboardAccess = { .allowed }
        /// 클립보드를 한 번 읽어 macOS가 묻게 하고, 다른 앱에서 붙여넣기 설정을 연다 (설정 화면의 단추로만)
        var requestClipboardAccess: @MainActor () -> Void = {}
        /// 단축키 감시. 기본은 없음 (테스트 · 미리보기에서 진짜 키를 보지 않게). live()가 Esc 탭을 다는 감시를 넣는다
        var makeMonitor: @MainActor (_ hotKey: DictationHotKey, _ allowsHandsFree: Bool) -> PushToTalkMonitor? = { _, _ in nil }
        /// 사용자가 키를 쳤다 (단축키 감시가 알린다). 이어 받아쓸 때 띄어 쓸지 가린다
        var userTyped: @MainActor () -> Void = {}
        /// 듣는 동안 화면이 꺼지지 않게 한다 (손을 떼고 말하면 키 입력이 없어 화면이 꺼지고 잠길 수 있다). 돌려준 것을 부르면 놓는다
        var keepDisplayAwake: @MainActor () -> (() -> Void)? = { nil }

        @MainActor
        static func live() -> Dependencies {
            let inserter = DictationTextInserter()
            return Dependencies(
                audio: DictationAudioCapture(),
                makeEngine: DictationEngines.make,
                insert: { text, settings, ownPanelIsKey in
                    await inserter.insert(text, settings: settings, ownPanelIsKey: ownPanelIsKey)
                },
                microphoneStatus: { MicrophonePermission.status },
                requestMicrophone: { await MicrophonePermission.request() },
                accessibilityTrusted: { PushToTalkMonitor.isAccessibilityTrusted },
                modifiersHeld: { hotKey in
                    var mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                    if hotKey == .fn { mask.insert(.maskSecondaryFn) }
                    return !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty
                },
                ownPanelIsKey: { (NSApp as NSApplication?)?.keyWindow is OverlayPanel },
                requestAccessibility: { MenuBarItemScanner.requestPermission() },
                clipboardAccess: { DictationClipboard.access(of: .general) },
                requestClipboardAccess: {
                    // 다른 앱이 복사한 것을 한 번 읽어야 macOS가 묻고 목록에 Cheoma를 올린다
                    _ = NSPasteboard.general.string(forType: .string)
                    DictationSystemSettings.open(.pasteboard)
                },
                // 듣기를 버린 Esc는 앞 앱(터미널의 에이전트 등)에 넘기지 않는다
                makeMonitor: { PushToTalkMonitor(hotKey: $0, allowsHandsFree: $1, interceptsEscape: true) },
                userTyped: { inserter.userTyped() },
                keepDisplayAwake: {
                    var id = IOPMAssertionID(0)
                    guard IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                      IOPMAssertionLevel(kIOPMAssertionLevelOn), "받아쓰기" as CFString,
                                                      &id) == kIOReturnSuccess else { return nil }
                    return { IOPMAssertionRelease(id) }
                })
        }
    }

    @Published var settings: DictationSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            settingsChanged(from: oldValue)
        }
    }

    // MARK: 설정 화면에 보여 줄 상태

    @Published private(set) var microphoneStatus: AVAuthorizationStatus
    @Published private(set) var isAccessibilityTrusted: Bool
    /// 고른 엔진을 쓸 수 있는지. nil이면 알아보는 중
    @Published private(set) var availability: DictationAvailability?
    /// Apple 언어 모델을 내려받는 중 (0…1)
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadError: String?
    /// 원래 클립보드를 되돌리려면 macOS가 클립보드 읽기를 허용해야 한다
    @Published private(set) var clipboardAccess: DictationClipboardAccess

    private let notch: NotchModel
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    var timing = Timing()

    private var monitor: PushToTalkMonitor?
    private var engines: [DictationEngineKind: DictationEngine] = [:]
    /// prepare를 부른 엔진 (끌 때 놓아야 할 것)
    private var preparedKinds = Set<DictationEngineKind>()
    private var cachedGlossary: (text: String, glossary: DictationGlossary)?

    /// 지금 키를 누르고 있는(또는 손을 떼고 듣는) 듣기
    private var current: Session?
    private var nextSessionID = 1
    /// 노치에 귀를 띄운 듣기
    private var displayedSessionID: Int?
    /// 가장 마지막으로 엔진에 넘긴 듣기가 엔진을 놓으면 열린다
    private var lastRelease: DictationSignal<Void>?
    /// 가장 마지막으로 엔진에 넘긴 듣기가 넣기까지 마치면 열린다 (넣는 차례를 말한 차례대로)
    private var lastDone: DictationSignal<Void>?
    private var clearWork: DispatchWorkItem?
    private var lingerWork: DispatchWorkItem?
    private var prepareWork: DispatchWorkItem?
    private var availabilityTask: Task<Void, Never>?
    private var isDownloading = false
    private var trustTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// 화면 잠금 · 잠자기 · 사용자 전환 알림
    private var suspendObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// 받아쓰기를 켤 때 손쉬운 사용 권한을 한 번만 묻는다
    private var askedAccessibility = false
    /// 듣는 동안 화면이 꺼지지 않게 잡아 둔 것을 놓는다
    private var releaseDisplayAwake: (() -> Void)?

    init(notch: NotchModel, defaults: UserDefaults = .standard, dependencies: Dependencies? = nil) {
        self.notch = notch
        self.defaults = defaults
        let dependencies = dependencies ?? .live()
        self.dependencies = dependencies
        settings = DictationSettings.load(from: defaults)
        microphoneStatus = dependencies.microphoneStatus()
        isAccessibilityTrusted = dependencies.accessibilityTrusted()
        clipboardAccess = dependencies.clipboardAccess()
        dependencies.audio.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.levelChanged(level) }
        }
        dependencies.audio.onInterrupted = { [weak self] error in
            MainActor.assumeIsolated { self?.interrupted(error) }
        }
    }

    // MARK: 켜기 · 끄기

    /// 앱이 켜질 때 부른다. 받아쓰기가 켜져 있으면 단축키를 듣기 시작한다
    func start() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        // 화면을 잠그거나 잠자거나 다른 사용자로 바꾸면 듣던 것을 버린다 (잠금 화면에서 계속 듣지 않게)
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (workspace, NSWorkspace.screensDidSleepNotification), (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
        ]
        suspendObservers = names.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        refreshPermissions()
        if settings.isEnabled { enable() }
    }

    /// 앱을 끝낼 때. 마이크를 닫고 엔진이 붙잡은 것(whisper 프로세스, Apple 모델)을 놓는다
    func shutdown() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        for observer in suspendObservers { observer.center.removeObserver(observer.token) }
        suspendObservers = []
        stopEverything()
    }

    /// 화면 잠금 · 잠자기: 듣던 것을 글로 옮기지 않고 버리고 마이크를 닫는다
    func suspend() {
        monitor?.abandon()
        if let current { abandon(current) }
        stopMicrophone()
        clearIndicator()
    }

    private func enable() {
        (dependencies.audio as? DictationAudioCapture)?.prepare()
        startMonitor()
        prepareEngine()
        refreshAvailability()
        updateTrustPolling()
    }

    private func stopEverything() {
        monitor?.onEvent = nil
        monitor?.stop()
        monitor = nil
        if let current { abandon(current) }
        current = nil
        stopMicrophone()
        prepareWork?.cancel()
        prepareWork = nil
        for kind in preparedKinds {
            if let engine = engines[kind] { DictationEngines.shutdown(engine) }
        }
        preparedKinds.removeAll()
        engines.removeAll()
        trustTimer?.invalidate()
        trustTimer = nil
        clearIndicator()
    }

    private func startMonitor() {
        guard monitor == nil, let monitor = dependencies.makeMonitor(settings.hotKey, settings.allowsHandsFree) else { return }
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onKeyTyped = { [weak self] in self?.dependencies.userTyped() }
        monitor.start()
        self.monitor = monitor
    }

    private func settingsChanged(from old: DictationSettings) {
        if settings.isEnabled != old.isEnabled {
            if settings.isEnabled {
                enable()
                // 켜는 그때 마이크 권한을 묻고(처음 한 번), 답한 뒤에 손쉬운 사용 권한을 묻는다 (묻는 창이 한꺼번에 뜨지 않게)
                if dependencies.microphoneStatus() == .notDetermined {
                    Task { [weak self] in
                        _ = await self?.dependencies.requestMicrophone()
                        self?.refreshPermissions()
                        self?.askAccessibilityOnce()
                    }
                } else {
                    askAccessibilityOnce()
                }
            } else {
                stopEverything()
                refreshAvailability()
            }
            return
        }
        if settings.hotKey != old.hotKey || settings.allowsHandsFree != old.allowsHandsFree {
            monitor?.update(hotKey: settings.hotKey, allowsHandsFree: settings.allowsHandsFree)
        }
        if settings.engine != old.engine {
            // 쓰지 않을 엔진은 놓는다 (whisper 프로세스, Apple 모델)
            if preparedKinds.remove(old.engine) != nil, let engine = engines.removeValue(forKey: old.engine) {
                DictationEngines.shutdown(engine)
            }
            availability = nil
            prepareEngine()
            refreshAvailability()
        } else if settings.localeIdentifier != old.localeIdentifier || settings.glossaryText != old.glossaryText
                    || settings.whisperModelPath != old.whisperModelPath {
            schedulePrepare()
        }
    }

    /// 다른 앱의 키를 받으려면 손쉬운 사용 권한이 필요하다. 없으면 켤 때 한 번 묻는다 (시스템이 묻는 창 + 시스템 설정)
    private func askAccessibilityOnce() {
        guard settings.isEnabled, !dependencies.accessibilityTrusted(), !askedAccessibility else { return }
        askedAccessibility = true
        dependencies.requestAccessibility()
    }

    // MARK: 엔진

    private func engine(for kind: DictationEngineKind) -> DictationEngine? {
        if let engine = engines[kind] { return engine }
        guard let engine = dependencies.makeEngine(kind) else { return nil }
        engines[kind] = engine
        return engine
    }

    /// 기본 용어집 + 사용자 용어집 (글이 바뀔 때만 다시 만든다)
    var glossary: DictationGlossary {
        if let cachedGlossary, cachedGlossary.text == settings.glossaryText { return cachedGlossary.glossary }
        let glossary = DictationGlossary(userText: settings.glossaryText)
        cachedGlossary = (settings.glossaryText, glossary)
        return glossary
    }

    var engineOptions: DictationEngineOptions {
        Self.engineOptions(settings: settings, glossary: glossary)
    }

    nonisolated static func engineOptions(settings: DictationSettings, glossary: DictationGlossary) -> DictationEngineOptions {
        DictationEngineOptions(localeIdentifier: settings.localeIdentifier, vocabulary: glossary.vocabulary,
                               whisperModelPath: settings.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 켜져 있으면 고른 엔진의 모델을 미리 올려 둔다
    private func prepareEngine() {
        guard settings.isEnabled, let engine = engine(for: settings.engine) else { return }
        preparedKinds.insert(settings.engine)
        let options = engineOptions
        Task { [weak self] in
            await engine.prepare(options: options)
            self?.refreshAvailability()
        }
    }

    private func schedulePrepare() {
        prepareWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prepareWork = nil
                if self.settings.isEnabled { self.prepareEngine() } else { self.refreshAvailability() }
            }
        }
        prepareWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.prepareDebounce, execute: work)
    }

    // MARK: 상태 (설정 화면)

    /// 권한과 엔진 상태를 다시 읽는다 (설정 화면을 열 때 · 앱이 앞으로 올 때)
    func refreshStatus() {
        refreshPermissions()
        refreshAvailability()
    }

    func refreshPermissions() {
        let microphone = dependencies.microphoneStatus()
        if microphoneStatus != microphone { microphoneStatus = microphone }
        let access = dependencies.clipboardAccess()
        if clipboardAccess != access { clipboardAccess = access }
        let trusted = dependencies.accessibilityTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
            // 권한이 없을 때 단 전역 감시는 권한을 받아도 이벤트가 오지 않을 수 있어서 다시 단다
            if trusted, let monitor, !monitor.isActive {
                monitor.onEvent = nil
                monitor.stop()
                self.monitor = nil
                startMonitor()
            }
        }
        updateTrustPolling()
    }

    /// 켜 두었는데 손쉬운 사용 권한이 없으면 받을 때까지 가끔 본다
    private func updateTrustPolling() {
        let needsPolling = settings.isEnabled && !isAccessibilityTrusted
        if needsPolling, trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
        } else if !needsPolling {
            trustTimer?.invalidate()
            trustTimer = nil
        }
    }

    func refreshAvailability() {
        let kind = settings.engine
        guard let engine = engine(for: kind) else {
            availability = .unavailable(Self.appleUnavailableReason)
            return
        }
        let options = engineOptions
        availabilityTask?.cancel()
        availabilityTask = Task { [weak self] in
            let result = await engine.availability(options: options)
            guard let self, !Task.isCancelled, self.settings.engine == kind else { return }
            if self.availability != result { self.availability = result }
        }
    }

    /// 마이크 권한: 아직 묻지 않았으면 묻고, 거절했으면 시스템 설정을 연다
    func requestMicrophoneAccess() {
        guard dependencies.microphoneStatus() == .notDetermined else {
            DictationSystemSettings.open(.microphone)
            return
        }
        Task { [weak self] in
            _ = await self?.dependencies.requestMicrophone()
            self?.refreshPermissions()
        }
    }

    /// 손쉬운 사용 권한: 시스템이 묻는 창을 띄우고 시스템 설정을 연다 (설정 화면의 단추)
    func requestAccessibilityAccess() {
        dependencies.requestAccessibility()
    }

    /// 클립보드 읽기 허용: 아직 묻지 않았으면 한 번 읽어 macOS가 묻게 하고, 아니면 시스템 설정만 연다 (설정 화면의 단추로만)
    func requestClipboardAccess() {
        if clipboardAccess == .notAsked {
            dependencies.requestClipboardAccess()
        } else {
            DictationSystemSettings.open(.pasteboard)
        }
        refreshPermissions()
    }

    /// Apple 언어 모델을 내려받는다 (설정 화면의 단추로만)
    func downloadAppleModel() {
        guard !isDownloading else { return }
        guard #available(macOS 26.0, *), let apple = engine(for: .apple) as? AppleSpeechEngine else {
            downloadError = Self.appleUnavailableReason
            return
        }
        let options = engineOptions
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        Task { [weak self] in
            do {
                try await apple.downloadAssets(options: options) { value in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.isDownloading else { return }
                            self.downloadProgress = value
                        }
                    }
                }
                self?.downloadFinished(error: nil)
            } catch {
                self?.downloadFinished(error: error)
            }
        }
    }

    private func downloadFinished(error: Error?) {
        isDownloading = false
        downloadProgress = nil
        if let error {
            let reason = (error as? DictationError)?.message ?? error.localizedDescription
            downloadError = "다운로드 실패: \(reason)"
            AppLog.write("받아쓰기: 언어 모델 \(downloadError ?? "")")
        }
        refreshAvailability()
        prepareEngine()
    }

    // MARK: 단축키

    func handle(_ event: PushToTalkEvent) {
        switch event {
        case .armed: armed()
        case .began(let handsFree): began(handsFree: handsFree)
        case .ended: ended()
        case .cancelled: cancelled()
        }
    }

    /// 키를 눌렀다: 첫 음절을 놓치지 않게 마이크를 연다
    private func armed() {
        lingerWork?.cancel()
        lingerWork = nil
        if let current { abandon(current) }
        let session = Session(id: nextSessionID)
        nextSessionID += 1
        current = session
        switch dependencies.microphoneStatus() {
        case .authorized:
            break
        case .notDetermined:
            session.startError = .microphoneUnavailable("마이크 권한을 허용한 후 다시 시도하십시오")
            session.asksPermission = true
            return
        default:
            session.startError = .microphoneDenied
            return
        }
        // 블루투스 헤드셋 마이크는 열면 헤드셋이 통화 음질로 바뀌고, 여는 데 1초쯤 걸려 미리 열어도 얻는 게 없다.
        // ⌥← 같은 단축키나 톡 친 것에 열지 않게 정말 듣기 시작할 때 연다
        if dependencies.audio.opensBluetoothInput(prefersBuiltInMicrophone: settings.prefersBuiltInMicrophone) {
            session.deferredStart = true
            return
        }
        openMicrophone(for: session)
    }

    private func openMicrophone(for session: Session) {
        dependencies.audio.onBuffer = Self.bufferHandler(session.queue)
        do {
            session.format = try dependencies.audio.start(prefersBuiltInMicrophone: settings.prefersBuiltInMicrophone)
        } catch {
            session.startError = Self.dictationError(error)
            stopMicrophone()
        }
    }

    /// 오디오 스레드에서 불린다
    nonisolated private static func bufferHandler(_ queue: DictationBufferQueue) -> (AVAudioPCMBuffer) -> Void {
        { buffer in queue.receive(buffer) }
    }

    /// 정말 듣기 시작: 귀를 띄우고 엔진에 넘긴다
    private func began(handsFree: Bool) {
        guard let session = current, !session.began else { return }
        session.began = true
        session.handsFree = handsFree
        if session.deferredStart {
            session.deferredStart = false
            openMicrophone(for: session)
        }
        if let error = session.startError {
            dropCurrent(session)
            if session.asksPermission {
                Task { [weak self] in
                    _ = await self?.dependencies.requestMicrophone()
                    self?.refreshPermissions()
                }
            }
            report(error, for: session)
            return
        }
        guard let format = session.format, let engine = engine(for: settings.engine) else {
            dropCurrent(session)
            report(.engineUnavailable(Self.appleUnavailableReason), for: session)
            return
        }
        let glossary = glossary
        session.engine = engine
        session.glossary = glossary
        session.beganAt = Date()
        clearWork?.cancel()
        displayedSessionID = session.id
        notch.dictation = DictationIndicator(stage: .listening, level: 0, text: "", handsFree: handsFree)
        // 앞 듣기의 소리 크기 · 글이 남지 않게 (같은 표시를 다시 넣으면 위에서 비우지 않는다)
        notch.dictationLive.reset(level: 0, text: "")
        if releaseDisplayAwake == nil { releaseDisplayAwake = dependencies.keepDisplayAwake() }
        session.limitTimer = Timer.scheduledTimer(withTimeInterval: timing.limit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedLimit(session) }
        }
        let previous = lastRelease
        lastRelease = session.released
        let previousDone = lastDone
        lastDone = session.done
        let options = Self.engineOptions(settings: settings, glossary: glossary)
        let id = session.id
        let engineTiming = timing
        Task { [weak self] in
            await previous?.wait()
            let outcome = await Self.runEngine(session, engine: engine, format: format, options: options,
                                               timing: engineTiming) { text in
                // 엔진 스레드에서 온다. 용어집은 여기서 적용해 둔다
                let shown = glossary.apply(to: text)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.partialArrived(shown, sessionID: id) }
                }
            }
            session.released.send(())
            await previousDone?.wait()
            await self?.complete(session, outcome: outcome)
            session.done.send(())
        }
    }

    private enum Outcome {
        case text(String)
        case cancelled
        case failed(Error)
    }

    /// 엔진이 정한 시간 안에 답하지 않았다
    private struct EngineTimedOut: Error {}

    /// 엔진으로 듣기 한 번: begin → (모아 둔 소리 넘기기) → 끝 신호 → finish 또는 cancel.
    /// begin · finish는 시간을 정해 두고 기다린다. 넘으면 엔진을 취소하고 실패로 끝낸다 (다음 듣기가 엔진을 받을 수 있게)
    private static func runEngine(_ session: Session, engine: DictationEngine, format: AVAudioFormat,
                                  options: DictationEngineOptions, timing: Timing,
                                  onPartial: @escaping @Sendable (String) -> Void) async -> Outcome {
        guard !session.isCancelled else { return .cancelled }
        session.enteredEngine = true
        do {
            try await withDeadline(timing.beginLimit) {
                try await engine.begin(format: format, options: options, onPartial: onPartial)
            }
        } catch {
            return failure(error, session: session, engine: engine)
        }
        if session.isCancelled {
            engine.cancel()
            return .cancelled
        }
        session.queue.attach(engine)
        switch await session.end.wait() {
        case .cancel:
            engine.cancel()
            return .cancelled
        case .finish:
            let heard = session.beganAt.map { Date().timeIntervalSince($0) } ?? 0
            do {
                return .text(try await withDeadline(timing.finishLimit + heard) { try await engine.finish() })
            } catch {
                return failure(error, session: session, engine: engine)
            }
        }
    }

    private static func failure(_ error: Error, session: Session, engine: DictationEngine) -> Outcome {
        if error is EngineTimedOut {
            // 멈춘 엔진 일은 버린다. 나중에 끝나도 아무도 기다리지 않는다
            engine.cancel()
            AppLog.write("받아쓰기: 엔진이 답하지 않아 멈춤")
            return .failed(DictationError.engineUnavailable("받아쓰기 시간 초과"))
        }
        return session.isCancelled || error is CancellationError ? .cancelled : .failed(error)
    }

    /// operation을 seconds까지만 기다린다. 넘으면 EngineTimedOut을 던진다 (operation은 그대로 두고 결과만 버린다)
    private static func withDeadline<T>(_ seconds: TimeInterval,
                                        _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume = { (result: Result<T, Error>) in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            // 잠자는 동안은 세지 않는다 (뚜껑을 닫았다 연 것을 엔진이 멈춘 것으로 보지 않게)
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds), clock: .suspending)
                if !Task.isCancelled { resume(.failure(EngineTimedOut())) }
            }
            Task {
                do { resume(.success(try await operation())) } catch { resume(.failure(error)) }
                timer.cancel()
            }
        }
    }

    /// 키를 뗐다: 조금 더 들은 뒤 마이크를 닫고 글로 옮긴다
    private func ended() {
        guard let session = current else { return }
        current = nil
        session.limitTimer?.invalidate()
        guard session.began else {
            abandon(session)
            return
        }
        // 시작하다 실패한 듣기는 이미 알렸다
        guard session.engine != nil, !session.isFinished else { return }
        if displayedSessionID == session.id {
            notch.dictation = DictationIndicator(stage: .transcribing, text: notch.dictationLive.text,
                                                 handsFree: session.handsFree)
        }
        let tail = timing.tail
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(tail))
            // 새 소리는 받지 않지만, 엔진이 아직 시작하지 않았으면 모아 둔 소리는 시작할 때 넘긴다
            session.queue.finishInput()
            // 그사이 다시 눌렀으면 마이크는 새 듣기가 쓴다
            if let self, self.current == nil { self.stopMicrophone() }
            session.end.send(.finish)
        }
    }

    private func cancelled() {
        guard let session = current else { return }
        current = nil
        // 톡 친 것이면 두 번째 누름을 기다리는 동안 마이크를 열어 둔다 (⌥← 같은 단축키였으면 바로 닫는다).
        // 단축키 감시 없이 부를 때(시험)는 두 번 누르기 설정을 따른다
        let waitsForSecondTap = monitor?.isWaitingForSecondTap ?? settings.allowsHandsFree
        abandon(session, keepsMicrophone: !session.began && waitsForSecondTap && session.format != nil)
    }

    /// 듣기를 버린다. 글로 옮기지 않고 아무것도 알리지 않는다
    private func abandon(_ session: Session, keepsMicrophone: Bool = false) {
        if current === session { current = nil }
        session.limitTimer?.invalidate()
        session.isCancelled = true
        session.queue.discard()
        if session.enteredEngine, let engine = session.engine { engine.cancel() }
        session.end.send(.cancel)
        if displayedSessionID == session.id { clearIndicator() }
        if keepsMicrophone { lingerMicrophone() } else { stopMicrophone() }
    }

    /// 너무 오래 들었다: 키를 뗀 것처럼 마무리한다. 단축키 감시는 처음부터 (늦게 뗀 키가 다음 듣기를 끝내지 않게)
    private func reachedLimit(_ session: Session) {
        guard current === session else { return }
        monitor?.abandon()
        ended()
    }

    /// 컨트롤러가 스스로 듣기를 접었다 (시작 실패 · 엔진 실패). 단축키 감시도 처음으로 돌린다
    /// (손을 떼고 듣는 중으로 남아 Esc 탭이 계속 달려 있거나 다음 누름이 끝내기로 쓰이지 않게)
    private func dropCurrent(_ session: Session) {
        guard current === session else { return }
        current = nil
        session.limitTimer?.invalidate()
        session.queue.discard()
        stopMicrophone()
        monitor?.abandon()
    }

    /// 듣는 도중 마이크가 멈췄다 (마이크는 이미 닫혔다).
    /// 이미 들은 소리가 있으면 거기까지 글로 옮긴다. 소리가 하나도 오지 않았으면 이유만 알린다
    private func interrupted(_ error: DictationError) {
        guard let session = current else { return }
        monitor?.abandon()
        if session.began, session.engine != nil, !session.isFinished, session.queue.hasReceivedAudio {
            AppLog.write("받아쓰기: \(error.message), 들은 데까지 옮김")
            ended()
            return
        }
        let began = session.began
        abandon(session)
        if began { report(error, for: session) }
    }

    // MARK: 글로 옮긴 뒤

    private func complete(_ session: Session, outcome: Outcome) async {
        session.isFinished = true
        // 키를 아직 누르고 있는데(또는 손을 떼고 듣는 중에) 엔진이 시작하지 못했으면 접는다 (키를 떼도 할 일이 없다)
        dropCurrent(session)
        switch outcome {
        case .cancelled:
            // 듣는 중 · 옮기는 중 표시가 남지 않게
            if displayedSessionID == session.id { clearIndicator() }
        case .failed(let error):
            report(Self.dictationError(error), for: session)
        case .text(let raw):
            let text = Self.finalText(raw, glossary: session.glossary ?? glossary)
            guard !text.isEmpty else {
                report(.nothingHeard, for: session)
                return
            }
            // 단축키나 다른 수식키를 누른 채 ⌘V를 보내면 다른 단축키(⌥⌘V)가 된다. 뗄 때까지 기다린다.
            // 다음 받아쓰기 단축키를 누르고 말하는 중이면 그 키를 뗄 때까지 기다린다 (넣는 차례는 그대로 앞 말이 먼저)
            var deadline = Date().addingTimeInterval(timing.modifierRelease)
            let hardStop = Date().addingTimeInterval(timing.limit + timing.modifierRelease)
            while dependencies.modifiersHeld(settings.hotKey), Date() < hardStop {
                let nextIsHeld = current.map { $0 !== session && !$0.handsFree } ?? false
                if nextIsHeld { deadline = Date().addingTimeInterval(timing.modifierRelease) }
                if !nextIsHeld, Date() >= deadline { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            var insertSettings = settings
            let ownPanelIsKey = dependencies.ownPanelIsKey()
            // 그래도 수식키가 눌려 있으면 ⌘V를 보내지 않고 클립보드에만 넣는다 (Cheoma 입력란은 키를 보내지 않으니 그대로)
            if !ownPanelIsKey, dependencies.modifiersHeld(settings.hotKey) { insertSettings.pasteMethod = .clipboardOnly }
            let result = await dependencies.insert(text, insertSettings, ownPanelIsKey)
            if case .failed(let message) = result { AppLog.write("받아쓰기: 붙여 넣지 못함: \(message)") }
            let (stage, duration) = Self.stage(for: result, timing: timing)
            show(stage, for: session, duration: duration)
        }
    }

    /// 엔진이 돌려준 글에 용어집을 적용하고 앞뒤 빈칸을 지운다
    nonisolated static func finalText(_ raw: String, glossary: DictationGlossary) -> String {
        glossary.apply(to: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 넣은 결과를 귀에 보여 줄 단계와 시간으로
    nonisolated static func stage(for result: DictationInsertionResult, timing: Timing = Timing()) -> (DictationIndicator.Stage, TimeInterval) {
        switch result {
        case .inserted(.clipboardOnly): (.inserted("클립보드에 복사됨"), timing.inserted)
        case .inserted: (.inserted("입력됨"), timing.inserted)
        case .copiedOnly(let reason): (.failed(shortCopiedReason(reason)), timing.failed)
        case .failed(let message): (.failed(message), timing.failed)
        }
    }

    /// 귀가 좁아서 "클립보드에만 복사했습니다"를 "복사만 됨"으로 줄인다
    nonisolated static func shortCopiedReason(_ reason: String) -> String {
        if reason.contains("암호") { return "암호 필드 · 복사만 됨" }
        if reason.contains("보안 입력") { return "보안 입력 · 복사만 됨" }
        if reason.contains("손쉬운 사용") { return "권한 없음 · 복사만 됨" }
        if reason.contains("입력란") { return "입력란 아님 · 복사만 됨" }
        return reason.replacingOccurrences(of: "클립보드에만 복사했습니다", with: "복사만 됨")
    }

    nonisolated static func dictationError(_ error: Error) -> DictationError {
        if let error = error as? DictationError { return error }
        return .engineUnavailable(error.localizedDescription)
    }

    // MARK: 노치 귀

    private func levelChanged(_ level: Float) {
        guard let session = current, session.began, displayedSessionID == session.id,
              notch.dictation?.stage == .listening else { return }
        notch.dictationLive.push(level: level)
    }

    private func partialArrived(_ text: String, sessionID: Int) {
        guard displayedSessionID == sessionID, notch.dictation?.stage == .listening, !text.isEmpty else { return }
        if notch.dictationLive.text != text { notch.dictationLive.text = text }
    }

    /// 마이크 권한이 없으면 누를 수 있는 알림(시스템 설정 열기)으로, 나머지는 귀에 짧게 (다 적은 이유는 기록에 남긴다)
    private func report(_ error: DictationError, for session: Session) {
        if error != .nothingHeard { AppLog.write("받아쓰기: \(error.message)") }
        if error == .microphoneDenied {
            if displayedSessionID == session.id { clearIndicator() }
            notch.show(NotchAlert(symbol: "mic.slash.fill", tint: .orange, text: error.message,
                                  url: DictationSystemSettings.Pane.microphone.url), duration: 5)
            return
        }
        show(.failed(error.headline), for: session, duration: timing.failed)
    }

    /// 듣기 하나의 결과를 잠깐 보여 준다. 그사이 새 듣기가 귀를 쓰고 있으면 건드리지 않는다
    private func show(_ stage: DictationIndicator.Stage, for session: Session, duration: TimeInterval) {
        if let displayed = displayedSessionID, displayed > session.id { return }
        clearWork?.cancel()
        displayedSessionID = session.id
        notch.dictation = DictationIndicator(stage: stage, handsFree: session.handsFree)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.displayedSessionID == session.id, self.notch.dictation?.stage == stage else { return }
                self.clearIndicator()
            }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func clearIndicator() {
        clearWork?.cancel()
        clearWork = nil
        displayedSessionID = nil
        if notch.dictation != nil { notch.dictation = nil }
    }

    // MARK: 마이크

    private func stopMicrophone() {
        lingerWork?.cancel()
        lingerWork = nil
        dependencies.audio.onBuffer = nil
        dependencies.audio.stop()
        releaseDisplayAwake?()
        releaseDisplayAwake = nil
    }

    /// 버퍼는 버리면서 잠깐 열어 둔다. 그 안에 다시 누르면 그대로 쓴다
    private func lingerMicrophone() {
        dependencies.audio.onBuffer = nil
        lingerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current == nil else { return }
                self.stopMicrophone()
            }
        }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.linger, execute: work)
    }

    // MARK: 시험용

    /// 듣기가 진행 중인지 (테스트)
    var hasActiveSession: Bool { current != nil }
}

// MARK: - 듣기 한 번

/// 키를 누른 때부터 글을 넣을 때까지. 메인 스레드에서만 바꾼다 (queue는 오디오 스레드도 쓴다)
@MainActor
private final class Session {
    enum End: Sendable { case finish, cancel }

    let id: Int
    let queue = DictationBufferQueue()
    /// 키를 뗐거나 버렸다
    let end = DictationSignal<End>()
    /// 엔진을 놓았다 (다음 듣기가 엔진을 써도 된다)
    let released = DictationSignal<Void>()
    /// 글을 넣었거나 넣지 않기로 했다 (다음 듣기가 넣어도 된다)
    let done = DictationSignal<Void>()
    var format: AVAudioFormat?
    var engine: DictationEngine?
    var glossary: DictationGlossary?
    var began = false
    var handsFree = false
    /// begin을 불렀다 (그 뒤에 버리면 엔진에 cancel을 보낸다)
    var enteredEngine = false
    var isCancelled = false
    /// 엔진 일이 끝났다 (글 · 실패 · 버림)
    var isFinished = false
    /// armed에서 마이크를 못 열었다. began에서 알린다 (톡 친 것이면 알리지 않는다)
    var startError: DictationError?
    var asksPermission = false
    /// 블루투스 헤드셋이라 armed에서 열지 않았다. began에서 연다
    var deferredStart = false
    var beganAt: Date?
    var limitTimer: Timer?

    init(id: Int) {
        self.id = id
    }
}

// MARK: - 엔진이 시작할 때까지 소리 모아 두기

/// 마이크 버퍼를 엔진의 begin이 끝날 때까지 모아 두었다가 차례대로 넘긴다. 그 뒤로 오는 것은 바로 넘긴다.
/// 키를 떼면(finishInput) 새 버퍼는 받지 않지만 모아 둔 것은 남겨 두었다가 엔진이 늦게 시작해도 넘긴다. 버리면(discard) 다 지운다.
/// 오디오 스레드(receive)와 메인 스레드(attach · finishInput · discard)가 같이 쓴다
final class DictationBufferQueue: @unchecked Sendable {
    /// 이보다 많이 모이면 새로 온 것은 버린다. 한 번에 들을 수 있는 가장 긴 시간보다 조금 길게 둔다
    /// (48 kHz 모노 Float32로 2분이면 23 MB쯤. 앞 듣기를 글로 옮기는 동안 기다리는 말도 끊지 않는다)
    let maximumSeconds: Double

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var engine: DictationEngine?
    private var acceptsInput = true
    private var isDiscarded = false
    private var receivedAny = false

    init(maximumSeconds: Double = DictationController.maximumDuration + 1) {
        self.maximumSeconds = maximumSeconds
    }

    /// 모아 둔 버퍼 수 (테스트)
    var pendingCount: Int { lock.withLock { pending.count } }
    /// 버퍼를 하나라도 받았는지
    var hasReceivedAudio: Bool { lock.withLock { receivedAny } }

    /// 오디오 스레드. 마이크가 버퍼를 다시 쓸 수 있어서 모아 둘 때는 복사한다
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsInput, !isDiscarded, buffer.frameLength > 0 else { return }
        receivedAny = true
        if let engine {
            engine.append(buffer)
            return
        }
        let limit = AVAudioFramePosition(buffer.format.sampleRate * maximumSeconds)
        guard pendingFrames + AVAudioFramePosition(buffer.frameLength) <= limit,
              let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        pending.append(copy)
        pendingFrames += AVAudioFramePosition(copy.frameLength)
    }

    /// 엔진이 시작했다. 모아 둔 버퍼를 먼저 넘긴다 (그동안 오는 버퍼는 기다렸다가 그 뒤에).
    /// 키를 이미 뗐으면 모아 둔 것만 넘긴다
    func attach(_ engine: DictationEngine) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDiscarded else { return }
        for buffer in pending { engine.append(buffer) }
        pending.removeAll()
        pendingFrames = 0
        self.engine = acceptsInput ? engine : nil
    }

    /// 키를 뗐다: 새 버퍼는 더 받지 않는다. 모아 둔 것은 attach에서 넘긴다
    func finishInput() {
        lock.lock()
        defer { lock.unlock() }
        acceptsInput = false
        engine = nil
    }

    /// 버렸다: 모아 둔 것도 지우고 더 받지 않는다
    func discard() {
        lock.lock()
        defer { lock.unlock() }
        isDiscarded = true
        acceptsInput = false
        pending.removeAll()
        pendingFrames = 0
        engine = nil
    }
}

// MARK: - 한 번 보내는 신호

/// 한 번 보내면 그 값으로 계속 열려 있는 신호. 먼저 기다리던 쪽도, 나중에 기다리는 쪽도 그 값을 받는다
@MainActor
final class DictationSignal<Value: Sendable> {
    private(set) var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    var isSent: Bool { value != nil }

    /// 두 번째부터는 무시한다
    func send(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: value) }
    }

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - 시스템 설정

/// 받아쓰기에 필요한 권한 · 키보드 설정 화면
enum DictationSystemSettings {
    enum Pane {
        case microphone, accessibility, speechRecognition, keyboard, pasteboard

        var url: URL {
            let base = "x-apple.systempreferences:"
            let path = switch self {
            case .microphone: "com.apple.preference.security?Privacy_Microphone"
            case .accessibility: "com.apple.preference.security?Privacy_Accessibility"
            case .speechRecognition: "com.apple.preference.security?Privacy_SpeechRecognition"
            case .keyboard: "com.apple.Keyboard-Settings.extension"
            case .pasteboard: "com.apple.preference.security?Privacy_Pasteboard"
            }
            return URL(string: base + path)!
        }
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    /// fn(지구본) 키를 누르면 macOS가 하는 일 (com.apple.HIToolbox › AppleFnUsageType). 정한 적이 없으면 nil
    static var globeKeyUsage: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    /// fn을 단축키로 쓸 때 보여 줄 주의. 지구본 키에 아무 일도 없으면(0) nil.
    /// 1: 입력 소스 변경, 2: 이모지 및 기호 보기, 3: 받아쓰기 시작(두 번 누르기). 3은 두 번 눌러 듣기를 끄면 겹치지 않는다
    static func globeKeyNote(usage: Int?, allowsHandsFree: Bool = true) -> String? {
        // 시스템 설정의 이름 그대로 (fn 키만 있는 키보드에서는 ‘fn 키를 누를 때 실행할 동작’). ‘안 함’은 줄이 나뉘지 않게 붙인다
        let remedy = "시스템 설정 › 키보드에서 ‘🌐︎ 키를 누를 때 실행할 동작’을 ‘안\u{00A0}함’으로 설정하십시오."
        switch usage {
        case 0: return nil
        case 1: return "🌐︎ 키가 ‘입력 소스 변경’으로 설정되어 있습니다. " + remedy
        case 2: return "🌐︎ 키가 ‘이모지 및 기호 보기’로 설정되어 있습니다. " + remedy
        case 3:
            guard allowsHandsFree else { return nil }
            return "🌐︎ 키를 두 번 누르면 macOS 받아쓰기도 시작됩니다. " + remedy
        default: return "🌐︎ 키에 다른 동작이 설정되어 있으면 함께 실행됩니다. " + remedy
        }
    }
}

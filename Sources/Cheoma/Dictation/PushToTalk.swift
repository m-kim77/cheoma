import AppKit
import ApplicationServices
import os

// 받아쓰기 단축키: 수식키 하나를 누르고 있는 동안 듣는다.
// 짧게 톡 치면 버리고, 두 번 빠르게 치면 손을 떼도 계속 듣는다.

/// 단축키 상태 기계. 키 이벤트와 그 시각을 받아 할 일(PushToTalkEvent)을 돌려준다.
/// AppKit 없이 값(키 코드 · 수식키 비트 · 시각)만 다뤄서 실제 키 없이 시험할 수 있다
struct PushToTalkStateMachine {
    /// 이만큼 누르고 있어야 듣기 시작한다. 이보다 빨리 떼면 톡 친 것이다
    static let holdThreshold: TimeInterval = 0.15
    /// 톡 친 뒤 이 안에 다시 누르면 손을 떼도 계속 듣는다
    static let doubleTapWindow: TimeInterval = 0.40
    /// kVK_Escape
    static let escapeKeyCode: UInt16 = 53

    enum Phase: Equatable {
        case idle
        /// 막 눌렀다 (armed를 냈다). 기준 시간이 지나도록 누르고 있으면 듣기 시작
        case pressed(since: TimeInterval)
        /// 누른 채 듣는 중. 떼면 끝
        case holding
        /// 짧게 눌렀다 뗐다. 곧 다시 누르면 손을 떼도 듣는다
        case tapped(releasedAt: TimeInterval)
        /// 두 번 눌러 손을 떼도 듣는 중
        case handsFree(HandsFree)
        /// 이번 누름은 받아쓰기가 아니다 (다른 수식키와 같이 눌렀거나 도중에 버렸다). 키를 뗄 때까지 아무것도 하지 않는다
        case ignoring
    }

    enum HandsFree: Equatable {
        /// 두 번째로 누른 키를 아직 떼지 않았다
        case starting
        /// 키를 떼고 듣는 중
        case listening
        /// 끝내려고 다시 눌렀다. 떼면 끝
        case stopping
        /// 다시 누른 채 다른 키를 같이 눌렀다 (⌥← 같은 단축키). 떼도 계속 듣는다
        case chord
    }

    private(set) var hotKey: DictationHotKey
    private(set) var allowsHandsFree: Bool
    private(set) var phase: Phase = .idle
    /// 단축키가 지금 눌려 있는지 (이벤트로 따라간 값)
    private(set) var isHotKeyDown = false
    /// 마지막으로 본 수식키 비트 (NSEvent.ModifierFlags.rawValue). 다른 수식키가 새로 눌렸는지 가린다
    private var lastFlags: UInt = 0

    init(hotKey: DictationHotKey, allowsHandsFree: Bool) {
        self.hotKey = hotKey
        self.allowsHandsFree = allowsHandsFree
    }

    /// 듣는 중인지 (armed를 낸 뒤 아직 ended · cancelled를 내지 않았다)
    var isActive: Bool {
        switch phase {
        case .pressed, .holding, .handsFree: true
        case .idle, .tapped, .ignoring: false
        }
    }

    /// 이 시각에 tick을 불러야 한다 (누르고 기다리는 기준 시간 · 두 번 누르기를 기다리는 시간)
    var nextDeadline: TimeInterval? {
        switch phase {
        case .pressed(let since): since + Self.holdThreshold
        case .tapped(let releasedAt): releasedAt + Self.doubleTapWindow
        default: nil
        }
    }

    // MARK: 입력

    /// 수식키가 눌리거나 떼졌다 (flagsChanged). keyCode는 바뀐 키다
    mutating func flagsChanged(keyCode: UInt16, flags: UInt, at time: TimeInterval) -> [PushToTalkEvent] {
        var events = tick(at: time)
        let previous = lastFlags
        lastFlags = flags
        let held = Modifiers.isHeld(hotKey, flags: flags)
        if keyCode == hotKey.keyCode {
            if held, !isHotKeyDown {
                events += hotKeyPressed(othersHeld: Modifiers.others(of: hotKey, flags: flags) != 0, at: time)
            } else if !held, isHotKeyDown {
                events += hotKeyReleased(at: time)
            }
            return events
        }
        // 단축키를 뗀 이벤트를 놓쳤으면 (보안 입력 등) 다른 키의 이벤트로 바로잡는다
        if isHotKeyDown, !held { events += hotKeyReleased(at: time) }
        let newlyPressed = Modifiers.others(of: hotKey, flags: flags) & ~Modifiers.others(of: hotKey, flags: previous)
        if newlyPressed != 0 { events += otherKeyPressed() }
        return events
    }

    /// 수식키가 아닌 키가 눌렸다 (keyDown)
    mutating func keyDown(keyCode: UInt16, at time: TimeInterval) -> [PushToTalkEvent] {
        var events = tick(at: time)
        events += keyCode == Self.escapeKeyCode ? escapePressed() : otherKeyPressed()
        return events
    }

    /// 마우스 단추가 눌렸다. 단축키를 누른 채 누르면 ⌥-클릭 같은 단축키다 (손을 떼고 듣는 중이면 무시한다)
    mutating func pointerPressed(at time: TimeInterval) -> [PushToTalkEvent] {
        var events = tick(at: time)
        events += otherKeyPressed()
        return events
    }

    /// 시간이 흘렀다. nextDeadline에 맞춰 부른다 (다른 입력도 먼저 이걸 거친다)
    mutating func tick(at time: TimeInterval) -> [PushToTalkEvent] {
        switch phase {
        case .pressed(let since) where time >= since + Self.holdThreshold:
            phase = .holding
            return [.began(handsFree: false)]
        case .tapped(let releasedAt) where time > releasedAt + Self.doubleTapWindow:
            phase = .idle
            return []
        default:
            return []
        }
    }

    /// 처음 상태로 돌린다. 듣는 중이었으면 cancelled를 낸다
    mutating func reset() -> [PushToTalkEvent] {
        let wasActive = isActive
        phase = .idle
        isHotKeyDown = false
        lastFlags = 0
        return wasActive ? [.cancelled] : []
    }

    /// 단축키나 두 번 누르기 설정을 바꾼다. 키가 바뀌면 처음부터 (듣는 중이었으면 cancelled)
    mutating func update(hotKey: DictationHotKey, allowsHandsFree: Bool) -> [PushToTalkEvent] {
        var events: [PushToTalkEvent] = []
        if hotKey != self.hotKey { events = reset() }
        self.hotKey = hotKey
        self.allowsHandsFree = allowsHandsFree
        // 두 번 누르기를 끄면 기다리던 두 번째 누름은 없던 일로 한다 (이미 손을 떼고 듣는 중이면 그대로 두고 다음 누름에 끝낸다)
        if !allowsHandsFree, case .tapped = phase { phase = .idle }
        return events
    }

    // MARK: 상태 바꾸기

    private mutating func hotKeyPressed(othersHeld: Bool, at time: TimeInterval) -> [PushToTalkEvent] {
        isHotKeyDown = true
        switch phase {
        case .idle:
            // 다른 수식키를 누른 채 누르면 다른 단축키(⇧⌥ 등)이다
            if othersHeld {
                phase = .ignoring
                return []
            }
            phase = .pressed(since: time)
            return [.armed]
        case .tapped:
            // tick을 먼저 거쳤으니 여기 왔으면 아직 두 번 누르기 시간 안이다
            if othersHeld {
                phase = .ignoring
                return []
            }
            phase = .handsFree(.starting)
            return [.armed, .began(handsFree: true)]
        case .handsFree(.listening):
            phase = .handsFree(othersHeld ? .chord : .stopping)
            return []
        case .pressed, .holding, .handsFree, .ignoring:
            return []
        }
    }

    private mutating func hotKeyReleased(at time: TimeInterval) -> [PushToTalkEvent] {
        isHotKeyDown = false
        switch phase {
        case .pressed:
            // 기준 시간 전에 뗐다 (tick을 먼저 거쳤으니 기준 시간이 지났으면 이미 holding이다)
            phase = allowsHandsFree ? .tapped(releasedAt: time) : .idle
            return [.cancelled]
        case .holding, .handsFree(.stopping):
            phase = .idle
            return [.ended]
        case .handsFree(.starting), .handsFree(.chord):
            phase = .handsFree(.listening)
            return []
        case .ignoring:
            phase = .idle
            return []
        case .idle, .tapped, .handsFree(.listening):
            return []
        }
    }

    /// 단축키를 누른 채 다른 키 · 다른 수식키 · 마우스를 눌렀다 (⌥← · ⌥-클릭 같은 단축키였다)
    private mutating func otherKeyPressed() -> [PushToTalkEvent] {
        switch phase {
        case .pressed, .holding, .handsFree(.starting):
            phase = isHotKeyDown ? .ignoring : .idle
            return [.cancelled]
        case .handsFree(.stopping):
            phase = .handsFree(.chord)
            return []
        case .tapped:
            // 톡 친 뒤 다른 키를 쳤으면 두 번 누르기가 아니다
            phase = .idle
            return []
        case .idle, .ignoring, .handsFree(.listening), .handsFree(.chord):
            return []
        }
    }

    private mutating func escapePressed() -> [PushToTalkEvent] {
        switch phase {
        case .pressed, .holding, .handsFree:
            phase = isHotKeyDown ? .ignoring : .idle
            return [.cancelled]
        case .tapped:
            phase = .idle
            return []
        case .idle, .ignoring:
            return []
        }
    }

    // MARK: 수식키 비트

    /// NSEvent.ModifierFlags.rawValue의 비트. 장치 비트(NX_DEVICE…)로 왼쪽 · 오른쪽을 가린다
    enum Modifiers {
        static let shift: UInt = 1 << 17
        static let control: UInt = 1 << 18
        static let option: UInt = 1 << 19
        static let command: UInt = 1 << 20
        static let function: UInt = 1 << 23

        static let leftControl: UInt = 0x0001
        static let leftShift: UInt = 0x0002
        static let rightShift: UInt = 0x0004
        static let leftCommand: UInt = 0x0008
        static let rightCommand: UInt = 0x0010
        static let leftOption: UInt = 0x0020
        static let rightOption: UInt = 0x0040
        static let rightControl: UInt = 0x2000

        static let families = shift | control | option | command | function
        static let deviceBits = leftControl | leftShift | rightShift | leftCommand | rightCommand
            | leftOption | rightOption | rightControl

        /// 단축키의 수식키 묶음 비트와 그 키 · 반대쪽 키의 장치 비트 (fn은 장치 비트가 없다)
        static func bits(for key: DictationHotKey) -> (family: UInt, own: UInt, opposite: UInt) {
            switch key {
            case .rightOption: (option, rightOption, leftOption)
            case .rightCommand: (command, rightCommand, leftCommand)
            case .fn: (function, 0, 0)
            }
        }

        /// 단축키가 눌려 있는지. 장치 비트가 아예 없는 이벤트(원격 제어 앱이 보낸 것 등)는 묶음 비트만 본다
        static func isHeld(_ key: DictationHotKey, flags: UInt) -> Bool {
            let bits = bits(for: key)
            guard flags & bits.family != 0 else { return false }
            if bits.own == 0 || flags & (bits.own | bits.opposite) == 0 { return true }
            return flags & bits.own != 0
        }

        /// 단축키 말고 눌려 있는 수식키 비트 (Caps Lock은 켜 두는 것이라 빼고, 같은 묶음의 반대쪽 키는 넣는다)
        static func others(of key: DictationHotKey, flags: UInt) -> UInt {
            let bits = bits(for: key)
            return flags & ((families & ~bits.family) | (deviceBits & ~bits.own))
        }
    }
}

/// 전역 · 앱 안 키 이벤트를 상태 기계에 넣고, 나온 일을 onEvent로 알린다.
/// 전역 감시는 손쉬운 사용 권한만 있으면 된다 (Cheoma는 이미 받아 두었다). 이벤트를 보기만 하고 막지는 않는다.
/// 듣는 동안만 마우스 누름도 보고(⌥-클릭 같은 단축키), interceptsEscape면 이벤트 탭을 달아 듣기를 버린 Esc를 앞 앱에 넘기지 않는다
@MainActor
final class PushToTalkMonitor {
    var onEvent: ((PushToTalkEvent) -> Void)?
    /// 사용자가 키를 쳤다 (받아쓰기가 보낸 ⌘V · 수식키만 누른 것은 빼고). 이어 받아쓸 때 띄어 쓸지 가린다
    var onKeyTyped: (() -> Void)?

    /// 키를 뗀 이벤트가 밀려 있는지 다시 보는 간격과 횟수
    static let recheckInterval: TimeInterval = 0.02
    static let maximumRechecks = 10

    /// 감시가 시스템에 다는 것. 시험에서는 가짜를 넣어 진짜 키 · 마우스를 보지 않고 탭도 만들지 않는다
    struct SystemHooks {
        /// 키 감시 (전역 · 앱 안). 앱 안 감시는 true를 돌려받으면 그 이벤트를 삼킨다
        var addKeyMonitors: @MainActor (_ global: @escaping @MainActor (NSEvent) -> Void,
                                        _ local: @escaping @MainActor (NSEvent) -> Bool) -> [Any]
        /// 마우스 누름 감시 (전역 · 앱 안)
        var addPointerMonitors: @MainActor (_ handler: @escaping @MainActor (NSEvent) -> Void) -> [Any]
        var removeMonitor: @MainActor (Any) -> Void
        /// Esc 탭을 단다. 삼킬지는 gate로 정하고, 정한 것은 report로 알린다 (탭 스레드에서). 만들지 못하면 nil
        var installEscapeTap: @MainActor (_ gate: EscapeTapGate,
                                          _ report: @escaping @Sendable (EscapeTapDecision, TimeInterval) -> Void) -> AnyObject?
        var removeEscapeTap: @MainActor (AnyObject) -> Void
    }

    private var machine: PushToTalkStateMachine
    private let hooks: SystemHooks
    private var keyMonitors: [Any] = []
    private var pointerMonitors: [Any] = []
    private var deadlineTimer: Timer?
    private let clock: () -> TimeInterval
    private let isHotKeyPhysicallyDown: (DictationHotKey) -> Bool
    private let interceptsEscape: Bool
    /// 탭 스레드가 읽는 값 (듣는 중인지 · 삼킨 Esc를 아직 떼지 않았는지)
    private let escapeGate = EscapeTapGate()
    private var escapeTap: AnyObject?
    /// 삼킨 Esc의 키 떼기가 오지 않을 때 (탭이 꺼짐 등) 탭을 오래 달아 두지 않는다
    private var swallowedEscapeWork: DispatchWorkItem?
    private var recheckCount = 0

    /// clock은 시험에서 시각을 정해 주려고 둔다. 이벤트에 시각이 없을 때(시험에서 만든 이벤트)와 타이머가 쓴다.
    /// isHotKeyPhysicallyDown은 지금 키보드에서 단축키가 눌려 있는지 (이벤트를 처리하는 것과 상관없이)
    init(hotKey: DictationHotKey, allowsHandsFree: Bool, interceptsEscape: Bool = false,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isHotKeyPhysicallyDown: @escaping (DictationHotKey) -> Bool = PushToTalkMonitor.hotKeyIsDown,
         hooks: SystemHooks = .live) {
        machine = PushToTalkStateMachine(hotKey: hotKey, allowsHandsFree: allowsHandsFree)
        self.interceptsEscape = interceptsEscape
        self.clock = clock
        self.isHotKeyPhysicallyDown = isHotKeyPhysicallyDown
        self.hooks = hooks
    }

    /// 손쉬운 사용 권한. 없으면 전역 감시가 다른 앱의 키를 받지 못한다 (오류 없이 조용히)
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 지금 키보드에서 단축키가 눌려 있는지 (윈도 서버가 아는 지금 상태)
    nonisolated static func hotKeyIsDown(_ hotKey: DictationHotKey) -> Bool {
        PushToTalkStateMachine.Modifiers.isHeld(hotKey, flags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    }

    var isRunning: Bool { !keyMonitors.isEmpty }
    var hotKey: DictationHotKey { machine.hotKey }
    var allowsHandsFree: Bool { machine.allowsHandsFree }
    /// 듣는 중인지 (armed를 낸 뒤 아직 ended · cancelled를 내지 않았다)
    var isActive: Bool { machine.isActive }
    /// 톡 친 뒤 두 번째 누름을 기다리는 중 (⌥← 같은 단축키로 버린 것이면 false)
    var isWaitingForSecondTap: Bool {
        if case .tapped = machine.phase { return true }
        return false
    }
    /// 듣는 동안 마우스 누름을 보고 있는지 (시험)
    var watchesPointer: Bool { !pointerMonitors.isEmpty }
    /// Esc 탭을 달아 두었는지 (시험)
    var hasEscapeTap: Bool { escapeTap != nil }

    func start() {
        guard keyMonitors.isEmpty else { return }
        keyMonitors = hooks.addKeyMonitors({ [weak self] event in
            self?.handle(event)
        }, { [weak self] event in
            self?.handleLocal(event) ?? false
        })
    }

    /// 감시를 멈춘다. 듣는 중이었으면 cancelled를 낸다
    func stop() {
        for monitor in keyMonitors { hooks.removeMonitor(monitor) }
        keyMonitors.removeAll()
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        deliver(machine.reset())
        swallowedEscapeWork?.cancel()
        swallowedEscapeWork = nil
        // 탭이 더 삼키지 않게 먼저 끄고, 키 떼기를 기다리지 않고 뗀다
        escapeGate.setIntercepts(false)
        escapeGate.forgetSwallowedEscape()
        updateSessionHooks()
    }

    func update(hotKey: DictationHotKey, allowsHandsFree: Bool) {
        emit(machine.update(hotKey: hotKey, allowsHandsFree: allowsHandsFree))
    }

    /// 듣기를 밖에서 끝냈을 때 (최대 시간 · 마이크가 멈춤 · 시작하지 못함). 아무 일도 내지 않고 처음 상태로 돌린다.
    /// 누르고 있던 키를 나중에 떼도 ended가 오지 않고, 손을 떼고 듣던 중이었어도 다음 누름은 새 듣기다
    func abandon() {
        _ = machine.reset()
        settle()
    }

    /// 키 이벤트 하나를 넣는다 (감시가 부른다. 시험에서는 만든 이벤트를 바로 넣는다)
    func handle(_ event: NSEvent) {
        // 받아쓴 글을 붙여 넣으려고 보낸 ⌘V는 사용자가 누른 키가 아니다 (막 다시 누른 단축키를 버리지 않게)
        if event.type == .keyDown,
           event.cgEvent?.getIntegerValueField(.eventSourceUserData) == DictationPasteKey.eventMarker { return }
        if event.type == .keyDown { onKeyTyped?() }
        // 탭이 삼킨 Esc는 여기 오지 않는다. 탭을 달기 전에 눌린 Esc는 여기서 버린다 (같은 Esc가 또 와도 두 번째는 할 일이 없다)
        // 처리한 때가 아니라 이벤트가 일어난 때를 쓴다. 메인 스레드가 밀려 늦게 처리해도 톡 친 것을 누른 것으로 보지 않는다
        let now = event.timestamp > 0 ? event.timestamp : clock()
        recheckCount = 0
        switch event.type {
        case .flagsChanged:
            emit(machine.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue, at: now))
        case .keyDown:
            emit(machine.keyDown(keyCode: event.keyCode, at: now))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            emit(machine.pointerPressed(at: now))
        default:
            return
        }
    }

    /// 앱 안 감시. 듣기를 버린 Esc는 Cheoma 창(노치의 답 입력란 등)에 넘기지 않는다 (true면 삼킨다)
    private func handleLocal(_ event: NSEvent) -> Bool {
        let cancels = event.type == .keyDown && event.keyCode == PushToTalkStateMachine.escapeKeyCode && machine.isActive
        handle(event)
        return cancels
    }

    /// 기준 시간이 됐다 (타이머가 부른다)
    func tick() {
        // 메인 스레드가 밀리면 키를 떼거나 다시 누른 이벤트가 아직 줄에 남아 있을 수 있다.
        // 지금 키 상태가 기다리던 것과 다르면 그 이벤트가 제 시각으로 처리되도록 조금 더 기다린다 (몇 번까지만)
        if recheckCount < Self.maximumRechecks, eventIsPending {
            recheckCount += 1
            scheduleTimer(after: Self.recheckInterval)
            return
        }
        recheckCount = 0
        emit(machine.tick(at: clock()))
    }

    /// 지금 키 상태로 보아 아직 처리하지 않은 단축키 이벤트가 있는지
    private var eventIsPending: Bool {
        switch machine.phase {
        case .pressed: !isHotKeyPhysicallyDown(machine.hotKey)
        case .tapped: isHotKeyPhysicallyDown(machine.hotKey)
        default: false
        }
    }

    // MARK: Esc 탭

    /// 탭 스레드가 하는 일(정하고 알리기)을 메인 스레드에서 한 번에 한다 (시험). 앞 앱에 넘기지 않으면 true
    func interceptKey(down: Bool, keyCode: UInt16, at time: TimeInterval) -> Bool {
        let decision = escapeGate.decide(keyCode: keyCode, down: down)
        escapeTapReported(decision, at: time)
        return decision != .pass
    }

    /// 탭 스레드가 정한 것을 메인 스레드에서 받는다
    func escapeTapReported(_ decision: EscapeTapDecision, at time: TimeInterval) {
        switch decision {
        case .swallowAndCancel:
            recheckCount = 0
            swallowedEscapeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.forgetSwallowedEscape() }
            }
            swallowedEscapeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            emit(machine.keyDown(keyCode: PushToTalkStateMachine.escapeKeyCode, at: time > 0 ? time : clock()))
        case .swallowRelease:
            swallowedEscapeWork?.cancel()
            swallowedEscapeWork = nil
            updateSessionHooks()
        case .pass, .swallow:
            break
        }
    }

    private func forgetSwallowedEscape() {
        swallowedEscapeWork = nil
        escapeGate.forgetSwallowedEscape()
        updateSessionHooks()
    }

    private func installEscapeTap() {
        guard interceptsEscape, escapeTap == nil, !keyMonitors.isEmpty else { return }
        // 앞 탭을 뗀 뒤 남은 것이 있으면 버린다 (새 탭이 첫 Esc를 반복으로 보지 않게)
        escapeGate.forgetSwallowedEscape()
        escapeGate.setIntercepts(machine.isActive)
        escapeTap = hooks.installEscapeTap(escapeGate) { [weak self] decision, time in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.escapeTapReported(decision, at: time) }
            }
        }
    }

    private func removeEscapeTap() {
        guard let escapeTap else { return }
        hooks.removeEscapeTap(escapeTap)
        self.escapeTap = nil
    }

    // MARK: 듣는 동안만 다는 것

    /// 듣는 동안만 마우스 감시 · Esc 탭을 단다 (듣지 않을 때는 아무 일도 하지 않게).
    /// 탭 스레드가 볼 값을 먼저 바꾸고 나서 뗄지 본다: 그사이 삼킨 Esc가 있으면 그 키 떼기까지 달아 둔다
    private func updateSessionHooks() {
        escapeGate.setIntercepts(machine.isActive)
        if machine.isActive {
            installPointerMonitors()
            installEscapeTap()
        } else {
            removePointerMonitors()
            if !escapeGate.holdsSwallowedEscape { removeEscapeTap() }
        }
    }

    /// 단축키를 누른 채 클릭하면 ⌥-클릭 같은 단축키다 (손을 떼고 듣는 중이면 무시한다)
    private func installPointerMonitors() {
        guard pointerMonitors.isEmpty, !keyMonitors.isEmpty else { return }
        pointerMonitors = hooks.addPointerMonitors { [weak self] event in self?.handle(event) }
    }

    private func removePointerMonitors() {
        for monitor in pointerMonitors { hooks.removeMonitor(monitor) }
        pointerMonitors.removeAll()
    }

    // MARK: 타이머

    private func deliver(_ events: [PushToTalkEvent]) {
        for event in events { onEvent?(event) }
    }

    /// 상태 기계가 낸 일을 알린다. 듣는 동안만 다는 것은 알리기 전에 맞춘다:
    /// 마이크를 여는 동안(armed) 누른 Esc도 탭이 삼키게 (탭은 자기 스레드에서 돌아 그동안 키 입력을 막지 않는다)
    private func emit(_ events: [PushToTalkEvent]) {
        updateSessionHooks()
        deliver(events)
        settle()
    }

    /// 입력을 넣은 뒤: 다음 기준 시간을 맞추고 듣는 동안만 다는 것을 정리한다
    private func settle() {
        scheduleDeadline()
        updateSessionHooks()
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = machine.nextDeadline else { return }
        scheduleTimer(after: max(deadline - clock(), 0))
    }

    private func scheduleTimer(after interval: TimeInterval) {
        deadlineTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        // 메뉴를 여는 중(이벤트 추적 모드)에도 돌게 한다
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }
}

extension PushToTalkMonitor.SystemHooks {
    /// 진짜 NSEvent 감시와 이벤트 탭
    static var live: Self {
        Self(
            addKeyMonitors: { global, local in
                let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
                var monitors: [Any] = []
                // 전역 감시는 Cheoma 자신에게 오는 이벤트(노치에서 답을 입력할 때 등)를 못 보니 앱 안 감시도 단다
                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                    MainActor.assumeIsolated { global(event) }
                }) {
                    monitors.append(monitor)
                }
                if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                    MainActor.assumeIsolated { local(event) } ? nil : event
                }) {
                    monitors.append(monitor)
                }
                return monitors
            },
            addPointerMonitors: { handler in
                let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                var monitors: [Any] = []
                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                    MainActor.assumeIsolated { handler(event) }
                }) {
                    monitors.append(monitor)
                }
                if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                    MainActor.assumeIsolated { handler(event) }
                    return event
                }) {
                    monitors.append(monitor)
                }
                return monitors
            },
            removeMonitor: { NSEvent.removeMonitor($0) },
            installEscapeTap: { gate, report in EscapeTapThread.start(gate: gate, report: report) },
            removeEscapeTap: { ($0 as? EscapeTapThread)?.stop() })
    }
}

// MARK: - Esc 탭

/// Esc 탭이 본 키를 어떻게 할지. 탭 스레드에서 바로 정한다
enum EscapeTapDecision: Equatable, Sendable {
    /// 앞 앱에 넘긴다
    case pass
    /// 삼킨다 (삼킨 Esc를 누르고 있어 반복해서 온 것)
    case swallow
    /// 삼키고 듣기를 버린다
    case swallowAndCancel
    /// 삼킨 Esc의 키 떼기를 삼킨다 (이제 탭을 떼도 된다)
    case swallowRelease
}

/// Esc 탭이 삼킬지 정하는 값. 단축키 감시(메인 스레드)가 듣는 동안 켜 두고 탭 스레드가 읽는다 (잠금으로 지킨다)
final class EscapeTapGate: Sendable {
    private struct State: Sendable {
        var intercepts = false
        var swallowedDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 듣는 중이라 Esc를 삼키고 듣기를 버린다
    func setIntercepts(_ intercepts: Bool) {
        state.withLock { $0.intercepts = intercepts }
    }

    /// 삼킨 Esc의 키 떼기를 아직 못 봤다 (그것도 앞 앱에 넘기지 않는다)
    var holdsSwallowedEscape: Bool { state.withLock { $0.swallowedDown } }

    /// 삼킨 Esc의 키 떼기를 더 기다리지 않는다
    func forgetSwallowedEscape() {
        state.withLock { $0.swallowedDown = false }
    }

    /// 탭 스레드에서 부른다
    func decide(keyCode: UInt16, down: Bool) -> EscapeTapDecision {
        guard keyCode == PushToTalkStateMachine.escapeKeyCode else { return .pass }
        return state.withLock { state in
            if !down {
                guard state.swallowedDown else { return .pass }
                state.swallowedDown = false
                return .swallowRelease
            }
            // 누르고 있어 반복해서 오는 Esc
            if state.swallowedDown { return .swallow }
            guard state.intercepts else { return .pass }
            // 한 번 버렸으면 메인 스레드가 다시 정할 때까지 다음 Esc는 넘긴다
            state.intercepts = false
            state.swallowedDown = true
            return .swallowAndCancel
        }
    }
}

/// 듣는 동안만 다는 Esc 탭. 자기 스레드의 런루프에서 돌아서 Cheoma 메인 스레드가 바빠도 다른 앱으로 가는 키를 늦추지 않는다.
/// 삼킬지는 탭 스레드에서 gate로 바로 정하고, 듣기를 버린 것 · 삼킨 Esc를 뗀 것만 report로 알린다
final class EscapeTapThread: @unchecked Sendable {
    private let gate: EscapeTapGate
    private let report: @Sendable (EscapeTapDecision, TimeInterval) -> Void
    /// launch에서 스레드를 띄우기 전에 정한다
    private var port: CFMachPort!
    private var source: CFRunLoopSource!
    private var setEnabled: ((Bool) -> Void)!
    private let lock = NSLock()
    /// 탭 스레드의 런루프 (돌기 시작하면)
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var finished = false

    init(gate: EscapeTapGate, report: @escaping @Sendable (EscapeTapDecision, TimeInterval) -> Void) {
        self.gate = gate
        self.report = report
    }

    /// 탭을 만들고 스레드를 띄운다. 권한이 없거나 만들지 못하면 nil (그러면 지금처럼 보기만 하고 Esc가 앞 앱에도 간다)
    static func start(gate: EscapeTapGate,
                      report: @escaping @Sendable (EscapeTapDecision, TimeInterval) -> Void) -> EscapeTapThread? {
        let tap = EscapeTapThread(gate: gate, report: report)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // 콜백은 스레드가 tap을 붙잡고 있는 동안만 불린다 (스레드가 끝나기 전에 탭을 무효로 한다)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(tap).toOpaque()) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        // 런루프가 돌기 전에 온 키가 기다리지 않게 꺼 두고, 탭 스레드에서 켠다
        CGEvent.tapEnable(tap: port, enable: false)
        tap.launch(port: port, source: source) { CGEvent.tapEnable(tap: port, enable: $0) }
        return tap
    }

    /// 스레드를 띄워 port를 돌린다. setEnabled는 탭을 켜고 끈다 (시험에서는 이벤트 탭이 아닌 포트로 스레드만 본다)
    func launch(port: CFMachPort, source: CFRunLoopSource, setEnabled: @escaping (Bool) -> Void) {
        self.port = port
        self.source = source
        self.setEnabled = setEnabled
        let thread = Thread { [self] in run() }
        thread.name = "Cheoma Esc 탭"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 탭 스레드가 런루프를 돌고 있는지 · 끝났는지 (시험)
    var isRunning: Bool { lock.withLock { runLoop != nil && !finished } }
    var isFinished: Bool { lock.withLock { finished } }

    /// 탭을 떼고 스레드를 끝낸다 (메인 스레드에서). 떼는 일은 탭 스레드에서 해서 돌고 있는 콜백과 겹치지 않는다
    func stop() {
        let target = lock.withLock { () -> CFRunLoop? in
            guard !stopped else { return nil }
            stopped = true
            return runLoop
        }
        // 스레드가 아직 런루프를 돌기 전이면 스레드가 stopped를 보고 스스로 정리한다
        guard let target else { return }
        CFRunLoopPerformBlock(target, CFRunLoopMode.commonModes.rawValue) { [self] in
            setEnabled(false)
            CFRunLoopRemoveSource(target, source, .commonModes)
            CFMachPortInvalidate(port)
            CFRunLoopStop(target)
        }
        CFRunLoopWakeUp(target)
    }

    /// 탭 스레드. stop이 런루프를 멈추면 돌아오고 스레드가 끝난다
    private func run() {
        defer { lock.withLock { finished = true } }
        let current: CFRunLoop = CFRunLoopGetCurrent()
        let proceeds = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            runLoop = current
            return true
        }
        guard proceeds else {
            CFMachPortInvalidate(port)
            return
        }
        CFRunLoopAddSource(current, source, .commonModes)
        setEnabled(true)
        CFRunLoopRun()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        return Unmanaged<EscapeTapThread>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }

    /// 탭 스레드. 메인 스레드를 기다리지 않고 바로 답한다
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 콜백이 늦거나 사용자 입력으로 시스템이 탭을 끄면 다시 켠다 (떼는 중이 아니면)
            if !lock.withLock({ stopped }) { setEnabled(true) }
        case .keyDown, .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let decision = gate.decide(keyCode: keyCode, down: type == .keyDown)
            switch decision {
            case .pass:
                break
            case .swallow:
                return nil
            case .swallowAndCancel, .swallowRelease:
                report(decision, ProcessInfo.processInfo.systemUptime)
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

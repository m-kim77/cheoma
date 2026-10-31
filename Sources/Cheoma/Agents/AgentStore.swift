import AppKit
import SwiftUI

/// 노치에 보여주는 에이전트 세션 하나 (터미널 안에서 돌아서 화면을 읽고 답을 보낼 수 있는 것)
struct AgentSession: Identifiable, Equatable, Sendable {
    /// 위치로 정한 ID ("terminal:/dev/ttys004", "tmux:%3")
    var id: String
    var kind: AgentKind
    var pid: pid_t
    var location: TerminalLocation
    var cwd: String?
    /// Claude의 ai-title, 터미널 탭 제목 등
    var title: String?
    var startedAt: Date?
    var state: AgentState
    /// 지금 상태가 된 시각
    var stateSince: Date
    var analysis: ScreenAnalysis?
    /// 마지막으로 읽은 화면. 고른 세션은 자주, 나머지는 상태가 바뀔 때만 읽는다
    var screen: TerminalScreen?
    var lastEvent: AgentHookEvent?
    /// Cheoma가 tmux로 띄운 세션 (노치에서 끝낼 수 있다)
    var isLaunchedByCheoma: Bool
    /// 에이전트의 세션 ID (Claude Code가 적어 두는 sessions/<pid>.json). 기록의 제목을 이걸로 찾는다
    var sessionID: String? = nil
    /// Claude Code 설정 폴더 이름 (".claude", ".claude-account2" …): 어느 계정으로 도는지
    var account: String? = nil
    /// 목록 순서에 쓰는 마지막 움직임: 상태가 바뀐 때의 마지막 출력 시각 (출력마다 바꾸면 목록이 계속 뒤섞인다)
    var lastActivity: Date = .distantPast

    /// 목록에 보여줄 이름: 작업 폴더 이름, 모르면 에이전트 이름
    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return kind.displayName }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// 코드 에이전트 세션을 찾고, 상태를 지켜보고, 답을 보낸다.
/// 무거운 일(프로세스 찾기, Apple Event, tmux, 기록 읽기)은 백그라운드 큐에서 하고 결과만 메인에서 바꾼다
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// 기록으로만 아는 최근 세션 (터미널 밖: 데스크톱 앱, IDE …). 보기만 한다
    @Published private(set) var recordedSessions: [RecordedSession] = []
    @Published private(set) var usage = AgentUsage()
    @Published var selectedID: AgentSession.ID?
    @Published private(set) var hookStatus = HookInstaller.Status(claude: [], codex: .unavailable)
    @Published private(set) var terminalPermission: AutomationPermission = .notDetermined
    /// 보내기 실패 같은 알림. 화면에 잠깐 보여준다
    @Published private(set) var message: String?
    @Published private(set) var isTmuxAvailable = false
    /// 설치된 에이전트 (새로 실행할 때 고르는 목록)
    @Published private(set) var installedAgents: [AgentKind] = []
    /// 새 에이전트를 띄울 때 고르는 최근 작업 폴더 (최근 것부터)
    @Published private(set) var recentFolders: [String] = []

    /// 에이전트 탭이 보이는 동안 true. 고른 세션의 화면을 1초마다 읽는다
    var isVisible = false {
        didSet { if isVisible && !oldValue { refreshNow() } }
    }
    /// 사용자가 봐야 하는 세션이 생기면 노치 알림을 띄운다
    var onAlert: ((NotchAlert, AgentSession.ID) -> Void)?

    /// 오른쪽에 보이는 세션. 고른 적이 없으면 목록 맨 위 (apply에서 그 세션으로 고정한다)
    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    /// 출력이 이 시간 안에 있었으면 작업 중으로 본다
    nonisolated static let activeWindow: TimeInterval = 1.5
    private static let recentFoldersKey = "agents.recentFolders"
    /// 같은 세션에 같은 알림을 다시 띄우지 않는 시간
    private static let alertCooldown: TimeInterval = 20
    /// 이만큼은 일하다 멈춰야 '끝났어요'를 알린다 (출력이 잠깐 멈춘 것에 울리지 않게)
    private static let minimumWork: TimeInterval = 4
    /// 사라진 세션을 '끝남'으로 남겨 두는 시간
    private static let exitedLinger: TimeInterval = 30

    private let queue = DispatchQueue(label: "io.github.m-kim77.cheoma.agents", qos: .utility)
    private let usageReader = AgentUsageReader()
    private var timer: Timer?
    private var tickCount = 0
    private var isPolling = false
    private var pollAgain = false
    private var lastUsageRead = Date.distantPast
    private var lastCaptured: [AgentSession.ID: Date] = [:]
    private var wasActive: [AgentSession.ID: Bool] = [:]
    private var lastActiveAt: [AgentSession.ID: Date] = [:]
    private var lastAlert: [AgentSession.ID: (state: AgentState, date: Date)] = [:]
    private var exitedAt: [AgentSession.ID: Date] = [:]
    /// 훅 이벤트가 먼저 오고 세션은 아직 못 찾았을 때 잠깐 들고 있는다
    private var pendingEvents: [AgentHookEvent] = []
    /// 방금 띄운 tmux 패널: 나타나면 고른다
    private var launchedPaneID: String?
    private var hookObserver: NSObjectProtocol?
    private var messageWork: DispatchWorkItem?

    func start() {
        guard timer == nil else { return }
        observeHooks()
        queue.async {
            let tmux = TmuxBridge.shared.executable != nil
            let installed = Self.findInstalledAgents()
            let hooks = HookInstaller.status()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.isTmuxAvailable = tmux
                    self?.installedAgents = installed
                    self?.hookStatus = hooks
                }
            }
        }
        poll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func select(_ id: AgentSession.ID?) {
        selectedID = id
        if let id { lastCaptured[id] = nil }
        if isVisible { poll() }
    }

    // MARK: - 보내기

    /// 글자를 보내고 Enter를 누른다
    func send(text: String, to id: AgentSession.ID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session = session(id) else { return }
        perform(on: session) { bridge, location in
            try bridge.send(text: text, pressEnter: true, to: location)
        }
    }

    /// 특수 키를 보낸다 (tmux 세션만)
    func send(key: TerminalKey, to id: AgentSession.ID) {
        guard let session = session(id) else { return }
        guard session.location.canSendKeys else {
            show(message: "이 세션에는 특수 키를 보낼 수 없어요. tmux 세션에서는 돼요")
            return
        }
        perform(on: session) { bridge, location in
            try bridge.send(key: key, to: location)
        }
    }

    /// 화면의 선택지를 고른다
    func choose(_ choice: AgentChoice, in id: AgentSession.ID) {
        guard let session = session(id) else { return }
        guard choice.key.isEmpty else {
            perform(on: session) { bridge, location in
                try bridge.send(text: choice.key, pressEnter: choice.needsEnter, to: location)
            }
            return
        }
        // 번호 없는 목록: 커서에서 고른 줄까지 화살표로 옮긴 뒤 Enter (tmux만)
        guard session.location.canSendKeys else {
            show(message: "이 목록은 화살표로 골라야 해서 터미널에서 직접 골라 주세요")
            return
        }
        let choices = session.analysis?.choices ?? []
        guard let target = choices.firstIndex(of: choice) else { return }
        let current = choices.firstIndex { $0.isHighlighted } ?? 0
        let moves = [TerminalKey](repeating: target > current ? .down : .up, count: abs(target - current))
        perform(on: session) { bridge, location in
            for key in moves + [.enter] { try bridge.send(key: key, to: location) }
        }
    }

    /// 그 터미널 탭을 앞으로 가져온다
    func reveal(_ id: AgentSession.ID) {
        guard let session = session(id) else { return }
        perform(on: session, refresh: false) { bridge, location in
            try bridge.reveal(location)
        }
    }

    /// Cheoma가 띄운 tmux 세션을 끝낸다
    func stop(_ id: AgentSession.ID) {
        guard let session = session(id), session.isLaunchedByCheoma else { return }
        perform(on: session) { _, location in
            try TmuxBridge.shared.kill(location)
        }
    }

    /// 새 tmux 세션에서 에이전트를 띄운다
    func launch(_ kind: AgentKind, in folder: String) {
        remember(folder: folder)
        queue.async {
            do {
                let location = try TmuxBridge.shared.launch(kind, in: folder)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if case .tmux(let paneID, _) = location {
                            self.launchedPaneID = paneID
                            self.selectedID = "tmux:\(paneID)"
                        }
                        self.isTmuxAvailable = true
                        self.poll()
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.show(message: message) }
                }
            }
        }
    }

    /// Terminal 자동화 권한을 묻는다 (사용자가 버튼을 눌렀을 때만). macOS가 묻는 창이 뜬다
    func requestTerminalAccess() {
        queue.async {
            let bridge = TerminalAppBridge.shared
            let permission: AutomationPermission = bridge.isRunning ? bridge.permission(askIfNeeded: true) : .targetNotRunning
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.terminalPermission = permission
                    switch permission {
                    case .granted: self.poll()
                    case .denied: self.show(message: "시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 Cheoma의 Terminal을 켜 주세요")
                    case .targetNotRunning: self.show(message: "Terminal이 켜져 있을 때 연결할 수 있어요")
                    case .notDetermined: break
                    }
                }
            }
        }
    }

    /// Claude Code · Codex 설정에 Cheoma 훅을 넣는다
    func installHooks() {
        changeHooks { status in
            var done: [String] = []
            for target in status.claude where !target.isInstalled {
                try HookInstaller.installClaude(configDir: target.configDir)
                done.append("Claude Code(\(target.configDir.lastPathComponent))")
            }
            if status.codex == .notInstalled {
                try HookInstaller.installCodex()
                done.append("Codex")
            }
            return done.isEmpty ? "이미 연결돼 있어요" : "\(done.joined(separator: ", ")) 연결했어요"
        }
    }

    /// 넣었던 훅을 뺀다
    func uninstallHooks() {
        changeHooks { status in
            for target in status.claude where target.isInstalled {
                try HookInstaller.uninstallClaude(configDir: target.configDir)
            }
            if status.codex == .installed { try HookInstaller.uninstallCodex() }
            return "훅을 뺐어요"
        }
    }

    /// 바로 다시 확인한다
    func refreshNow() {
        if let id = selectedSession?.id { lastCaptured[id] = nil }
        poll()
    }

    // MARK: - 지켜보기

    private func tick() {
        tickCount += 1
        // 탭을 보고 있으면 매초, 아니면 3초마다 (알림을 놓치지 않을 만큼만)
        if isVisible || tickCount % 3 == 0 { poll() }
        if !pendingEvents.isEmpty { pendingEvents.removeAll { Date().timeIntervalSince($0.date) > 10 } }
    }

    /// 백그라운드에서 모은 결과를 메인에서 합친다. 한 번에 하나만 돈다
    private func poll() {
        guard !isPolling else { pollAgain = true; return }
        isPolling = true
        let now = Date()
        let readUsage = now.timeIntervalSince(lastUsageRead) > (isVisible ? 10 : 30)
        if readUsage { lastUsageRead = now }
        let plan = PollPlan(
            selectedID: isVisible ? selectedSession?.id : nil,
            terminalAllowed: terminalPermission == .granted,
            checkPermission: isVisible || tickCount % 15 == 0,
            lastCaptured: lastCaptured,
            wasActive: wasActive,
            readUsage: readUsage)
        // 읽기 도구는 이 큐에서만 쓰므로 넘겨도 안전하다
        let reader = Unchecked(usageReader)
        queue.async {
            let result = Self.collect(plan, usageReader: reader.value)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPolling = false
                    self.apply(result)
                    if self.pollAgain {
                        self.pollAgain = false
                        self.poll()
                    }
                }
            }
        }
    }

    private func apply(_ result: PollResult) {
        if let permission = result.permission { terminalPermission = permission }
        if let usage = result.usage { self.usage = usage }
        if let error = result.error { show(message: error) }

        var next: [AgentSession] = []
        var seen = Set<AgentSession.ID>()
        for item in result.items where !seen.contains(item.id) {
            seen.insert(item.id)
            exitedAt[item.id] = nil
            var session = sessions.first { $0.id == item.id } ?? AgentSession(
                id: item.id, kind: item.kind, pid: item.pid, location: item.location, cwd: item.cwd, title: nil,
                startedAt: item.startedAt, state: .unknown, stateSince: result.date, analysis: nil, screen: nil,
                lastEvent: nil, isLaunchedByCheoma: item.isLaunchedByCheoma,
                lastActivity: [item.lastOutput, item.statusSince, item.startedAt].compactMap { $0 }.max() ?? result.date)
            session.kind = item.kind
            session.pid = item.pid
            session.location = item.location
            session.cwd = item.cwd ?? session.cwd
            session.startedAt = item.startedAt ?? session.startedAt
            session.isLaunchedByCheoma = item.isLaunchedByCheoma
            session.sessionID = item.sessionID ?? session.sessionID
            session.account = item.account ?? session.account
            if let screen = item.screen {
                session.screen = screen
                session.analysis = item.analysis
                lastCaptured[item.id] = result.date
            }
            if item.isActive { lastActiveAt[item.id] = result.date }
            wasActive[item.id] = item.isActive
            if let index = pendingEvents.firstIndex(where: { Self.matches($0, session) }) {
                session.lastEvent = pendingEvents.remove(at: index)
            }
            let state = decideState(session, item: item, now: result.date)
            if state != session.state {
                transition(&session, to: state, at: result.date)
                // 처음 판단(확인 중 → …)은 실제로 움직인 게 아니라서 마지막 출력 시각까지만 올린다
                let moved = [item.lastOutput, item.statusSince].compactMap { $0 }.max()
                session.lastActivity = max(session.lastActivity, moved ?? (state == .exited ? session.lastActivity : result.date))
            }
            next.append(session)
        }

        // 사라진 세션은 잠깐 '끝남'으로 남긴다
        for old in sessions where !seen.contains(old.id) {
            let since = exitedAt[old.id] ?? result.date
            exitedAt[old.id] = since
            guard result.date.timeIntervalSince(since) < Self.exitedLinger else {
                forget(old.id)
                continue
            }
            var session = old
            if session.state != .exited { transition(&session, to: .exited, at: since) }
            next.append(session)
        }

        // 세션 제목 (Claude의 ai-title 등): 세션 ID로 찾는다. ID를 모르면 그 폴더에 세션이 하나뿐일 때만 폴더로 찾는다
        // (같은 폴더의 터미널 여러 개가 다 같은 제목으로 보이지 않게)
        for index in next.indices {
            let session = next[index]
            let record: RecordedSession?
            if let id = session.sessionID ?? session.lastEvent?.sessionID {
                record = usage.recentSessions.first { $0.id == id }
            } else if next.filter({ $0.kind == session.kind && $0.cwd == session.cwd }).count == 1 {
                record = usage.recentSessions.first { $0.kind == session.kind && $0.cwd == session.cwd }
            } else {
                record = nil
            }
            next[index].title = record?.title
        }

        sessions = next.sorted(by: Self.order)
        recordedSessions = usage.recentSessions.filter { record in
            !sessions.contains { session in
                session.sessionID == record.id || (session.kind == record.kind && session.cwd == record.cwd && session.state != .exited)
            }
        }
        updateRecentFolders()

        if let paneID = launchedPaneID, sessions.contains(where: { $0.id == "tmux:\(paneID)" }) {
            selectedID = "tmux:\(paneID)"
            launchedPaneID = nil
        }
        // 고른 세션은 목록 순서가 바뀌어도 그대로 둔다 (답을 쓰는 중에 다른 세션으로 바뀌지 않게)
        if launchedPaneID == nil, selectedID.map({ id in !sessions.contains { $0.id == id } }) ?? true {
            selectedID = sessions.first?.id
        }
    }

    /// Claude Code는 스스로 적는 상태, 나머지는 화면 → 훅 → 출력 활동 순서로 판단한다
    private func decideState(_ session: AgentSession, item: PollItem, now: Date) -> AgentState {
        guard item.hasAgentProcess else { return .exited }
        // Claude Code가 적는 상태는 한 차례 내내 busy로 남는다. 화면이나 출력으로 보면 도구를 돌리는 사이마다
        // 입력창만 보이거나 출력이 멈춰서 작업 중 ↔ 입력 기다림을 오갔다. 화면은 선택지가 떠 있는지만 본다
        if let status = item.agentStatus {
            switch status {
            case "busy":
                // 사용자가 보낸 것 없이 도는 일 (기다리는 동안 대화 줄이기, 돌아왔을 때 요약): 할 일이 없으니 기다림으로 둔다
                return isBackgroundWork(session, item: item) ? .needsInput : .working
            case "waiting":
                return .needsChoice
            // "shell": 차례가 끝난 뒤 셸이 남아 있을 때 (10/31 확인: 응답을 끝내고 몇 시간째 shell). 할 일은 없다
            case "idle", "shell":
                if item.screen != nil { return item.analysis?.state == .needsChoice ? .needsChoice : .needsInput }
                // 이번에 화면을 못 읽었으면, 상태가 그대로인 동안 보이던 선택지를 그대로 둔다
                let unchanged = (item.statusSince ?? .distantPast) <= session.stateSince
                return session.state == .needsChoice && unchanged ? .needsChoice : .needsInput
            default:
                break
            }
        }
        // 이번에 읽은 화면이 가장 정확하다
        if item.screen != nil, let analysis = item.analysis, analysis.state != .unknown, analysis.state != .exited {
            return analysis.state
        }
        if item.isActive { return .working }
        // 화면을 못 읽는 세션: 출력이 멈춘 뒤 들어온 훅을 따른다
        if let event = session.lastEvent, event.date >= (lastActiveAt[session.id] ?? .distantPast) {
            switch event.name {
            case "Notification":
                return event.notificationType == "permission_prompt" ? .needsChoice : .needsInput
            case "Stop", "StopFailure", "agent-turn-complete": return .needsInput
            case "UserPromptSubmit": return .working
            default: break
            }
        }
        // 출력이 멈췄다: 화면을 못 읽었으면 다음 지시를 기다린다고 본다
        if session.state == .working || session.state == .unknown, item.screen == nil {
            let quiet = now.timeIntervalSince(lastActiveAt[session.id] ?? session.stateSince)
            if quiet > 2.5 { return .needsInput }
        }
        return session.state == .exited ? .unknown : session.state
    }

    /// Claude Code가 busy인데 사용자가 보낸 것이 없다: 마지막 훅이 차례 끝(Stop)이나 시작(SessionStart)이고 그 뒤로 지시가 없었다.
    /// Claude Code는 기다리는 동안 프롬프트 캐시가 끝나기 전에 대화를 줄이고(idleCompaction), 돌아왔을 때 요약(recap)을 만든다. 훅이 있는 계정만 가린다
    private func isBackgroundWork(_ session: AgentSession, item: PollItem) -> Bool {
        guard hasClaudeHooks(session), let event = session.lastEvent else { return false }
        let idleEvent = event.name == "Stop" || event.name == "SessionStart"
            || (event.name == "Notification" && event.notificationType == "idle_prompt")
        return idleEvent && event.date <= (item.statusSince ?? .distantFuture)
    }

    /// 이 Claude 세션의 계정에 Cheoma 훅이 들어 있는지 (차례가 끝난 것을 Stop 훅으로 정확히 안다)
    private func hasClaudeHooks(_ session: AgentSession) -> Bool {
        guard session.kind == .claude, let account = session.account else { return false }
        return hookStatus.claude.contains { $0.configDir.lastPathComponent == account && $0.hooks }
    }

    private func transition(_ session: inout AgentSession, to state: AgentState, at date: Date) {
        let previous = session.state
        let workedFor = date.timeIntervalSince(session.stateSince)
        session.state = state
        session.stateSince = date
        switch state {
        case .needsChoice:
            alert(.needsChoice, for: session, at: date)
        // 훅이 있는 Claude는 Stop 훅으로만 알린다 (receive). 나머지는 잠깐 멈춘 출력에 울리지 않게 몇 초는 일했어야 한다
        case .needsInput where previous == .working && !hasClaudeHooks(session) && workedFor >= Self.minimumWork:
            alert(.needsInput, for: session, at: date)
        default:
            break
        }
    }

    private func alert(_ state: AgentState, for session: AgentSession, at date: Date) {
        // 보고 있는 세션은 알리지 않는다
        if isVisible && selectedSession?.id == session.id { return }
        let alert = state == .needsChoice
            ? NotchAlert(symbol: "hand.raised.fill", tint: .orange, text: "\(Self.shortName(session.kind)) 확인 필요")
            : NotchAlert(symbol: "checkmark.circle.fill", tint: .green, text: "\(Self.shortName(session.kind)) 끝났어요")
        if let last = lastAlert[session.id], last.state == state, date.timeIntervalSince(last.date) < Self.alertCooldown { return }
        lastAlert[session.id] = (state, date)
        onAlert?(alert, session.id)
    }

    // MARK: - 훅

    private func observeHooks() {
        hookObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentHooks.notificationName, object: nil, queue: .main
        ) { [weak self] notification in
            let event = AgentHooks.event(from: notification)
            MainActor.assumeIsolated {
                guard let event else { return }
                self?.receive(event)
            }
        }
    }

    private func receive(_ event: AgentHookEvent) {
        if let index = sessions.firstIndex(where: { Self.matches(event, $0) }) {
            sessions[index].lastEvent = event
            // 사용자가 보낸 지시가 정말 끝났을 때 (Claude Code의 Stop 훅). 기다리는 동안 혼자 도는 일에는 오지 않는다
            if event.name == "Stop", sessions[index].kind == .claude, sessions[index].state == .working {
                alert(.needsInput, for: sessions[index], at: event.date)
            }
            // 훅이 왔으니 화면을 바로 다시 읽는다
            lastCaptured[sessions[index].id] = nil
        } else {
            pendingEvents.append(event)
        }
        poll()
    }

    private nonisolated static func matches(_ event: AgentHookEvent, _ session: AgentSession) -> Bool {
        if let tty = event.tty, let sessionTTY = session.location.tty { return tty == sessionTTY }
        return event.kind == session.kind && event.cwd != nil && event.cwd == session.cwd
    }

    // MARK: - 도우미

    private func session(_ id: AgentSession.ID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// 터미널에 무언가 하고, 바로 화면을 다시 읽는다
    private func perform(on session: AgentSession, refresh: Bool = true,
                         _ work: @escaping @Sendable (TerminalBridge, TerminalLocation) throws -> Void) {
        let location = session.location
        guard let bridge = Self.bridge(for: location) else {
            show(message: "이 세션은 보기만 할 수 있어요. 답은 그 앱에서 해 주세요")
            return
        }
        if case .terminalApp = location, terminalPermission != .granted, refresh {
            show(message: "먼저 Terminal을 연결해 주세요")
            return
        }
        let id = session.id
        let target = Unchecked(bridge)
        queue.async {
            let failure: String?
            do {
                try work(target.value, location)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let failure { self.show(message: failure) }
                    guard refresh else { return }
                    self.lastCaptured[id] = nil
                    // 에이전트가 반응할 틈을 조금 준다
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        MainActor.assumeIsolated { self.poll() }
                    }
                }
            }
        }
    }

    private func changeHooks(_ work: @escaping @Sendable (HookInstaller.Status) throws -> String) {
        queue.async {
            let text: String
            do { text = try work(HookInstaller.status()) } catch { text = error.localizedDescription }
            let status = HookInstaller.status()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.hookStatus = status
                    self?.show(message: text)
                }
            }
        }
    }

    private func show(message: String) {
        self.message = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.message = nil }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func forget(_ id: AgentSession.ID) {
        exitedAt[id] = nil
        lastCaptured[id] = nil
        wasActive[id] = nil
        lastActiveAt[id] = nil
        lastAlert[id] = nil
    }

    private func remember(folder: String) {
        var folders = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        folders.removeAll { $0 == folder }
        folders.insert(folder, at: 0)
        UserDefaults.standard.set(Array(folders.prefix(8)), forKey: Self.recentFoldersKey)
        updateRecentFolders()
    }

    private func updateRecentFolders() {
        let launched = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        let candidates = launched + sessions.compactMap(\.cwd) + usage.recentSessions.compactMap(\.cwd)
        var seen = Set<String>()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = candidates.filter { folder in
            guard folder != home, folder != "/", !seen.contains(folder) else { return false }
            seen.insert(folder)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let result = Array(folders.prefix(8))
        if result != recentFolders { recentFolders = result }
    }

    /// 최근에 움직인 것부터 (같으면 ID로 고정해서 줄이 뒤섞이지 않게). 끝난 세션은 맨 아래
    private static func order(_ a: AgentSession, _ b: AgentSession) -> Bool {
        if (a.state == .exited) != (b.state == .exited) { return b.state == .exited }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.id < b.id
    }

    private static func shortName(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "pi"
        case .gemini: "Gemini"
        case .aider: "Aider"
        }
    }

    nonisolated private static func bridge(for location: TerminalLocation) -> TerminalBridge? {
        switch location {
        case .terminalApp: TerminalAppBridge.shared
        case .tmux: TmuxBridge.shared
        case .other: nil
        }
    }

    /// GUI 앱은 PATH가 짧아서, 에이전트가 흔히 설치되는 폴더를 직접 본다
    nonisolated private static func findInstalledAgents() -> [AgentKind] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
                       "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/bin"]
        return AgentKind.allCases.filter { kind in
            folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(kind.command)") }
        }
    }

    // MARK: - 백그라운드에서 모으기

    /// 이 큐에서만 쓰는 객체를 큐로 넘길 때 쓴다
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct PollPlan {
        var selectedID: AgentSession.ID?
        var terminalAllowed: Bool
        var checkPermission: Bool
        var lastCaptured: [AgentSession.ID: Date]
        var wasActive: [AgentSession.ID: Bool]
        var readUsage: Bool
    }

    private struct PollItem {
        var id: AgentSession.ID
        var kind: AgentKind
        var pid: pid_t
        var location: TerminalLocation
        var cwd: String?
        var startedAt: Date?
        var isLaunchedByCheoma: Bool
        /// tmux 패널만 남고 에이전트는 끝났으면 false
        var hasAgentProcess: Bool
        var isActive: Bool
        var lastOutput: Date? = nil
        /// Claude Code의 sessions/<pid>.json
        var sessionID: String? = nil
        var account: String? = nil
        var agentStatus: String? = nil
        var statusSince: Date? = nil
        var screen: TerminalScreen?
        var analysis: ScreenAnalysis?
    }

    private struct PollResult {
        var date: Date
        var items: [PollItem]
        var usage: AgentUsage?
        var permission: AutomationPermission?
        var error: String?
    }

    /// 프로세스 찾기 → 터미널 자리 정하기 → 필요한 화면만 읽기 → 분석. 큐에서만 부른다
    nonisolated private static func collect(_ plan: PollPlan, usageReader: AgentUsageReader) -> PollResult {
        let now = Date()
        let processes = AgentScanner.scan().filter { $0.tty != nil }
        let panes = tmuxServerRunning ? ((try? TmuxBridge.shared.panes()) ?? []) : []
        let claudeDirs = processes.contains { $0.kind == .claude }
            ? AgentUsageReader.claudeConfigDirs(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
            : []
        var items: [PollItem] = []

        for process in processes {
            guard let tty = process.tty else { continue }
            let pane = panes.first { $0.tty == tty }
            let id: AgentSession.ID
            let location: TerminalLocation
            if let pane {
                id = "tmux:\(pane.paneID)"
                location = .tmux(paneID: pane.paneID, tty: tty)
            } else if process.hostApp == "Terminal" {
                id = "terminal:\(tty)"
                location = .terminalApp(tty: tty)
            } else {
                id = "other:\(tty)"
                location = .other(tty: tty, app: process.hostApp)
            }
            let lastOutput = AgentScanner.lastOutput(tty: tty)
            let live = process.kind == .claude ? ClaudeStatusLine.liveSession(pid: process.pid, configDirs: claudeDirs) : nil
            items.append(PollItem(
                id: id, kind: process.kind, pid: process.pid, location: location, cwd: process.cwd,
                startedAt: process.startedAt, isLaunchedByCheoma: pane?.sessionName.hasPrefix(TmuxBridge.sessionPrefix) ?? false,
                hasAgentProcess: true, isActive: lastOutput.map { now.timeIntervalSince($0) < activeWindow } ?? false,
                lastOutput: lastOutput, sessionID: live?.sessionID, account: live?.account,
                agentStatus: live?.status, statusSince: live?.statusSince))
        }
        // Cheoma가 띄운 패널은 에이전트가 끝나도 남긴다 (마지막 화면을 볼 수 있게)
        for pane in panes where pane.sessionName.hasPrefix(TmuxBridge.sessionPrefix) && !items.contains(where: { $0.location.tty == pane.tty }) {
            let kind = AgentKind.allCases.first { pane.sessionName.hasPrefix("\(TmuxBridge.sessionPrefix)\($0.rawValue)") } ?? .claude
            items.append(PollItem(
                id: "tmux:\(pane.paneID)", kind: kind, pid: pane.pid, location: .tmux(paneID: pane.paneID, tty: pane.tty),
                cwd: pane.currentPath, startedAt: nil, isLaunchedByCheoma: true, hasAgentProcess: false, isActive: false))
        }

        var permission: AutomationPermission?
        let hasTerminalSessions = items.contains { if case .terminalApp = $0.location { return true }; return false }
        if hasTerminalSessions && (plan.checkPermission || plan.terminalAllowed) {
            let bridge = TerminalAppBridge.shared
            permission = bridge.isRunning ? bridge.permission(askIfNeeded: false) : .targetNotRunning
        }
        let terminalAllowed = (permission ?? (plan.terminalAllowed ? .granted : .notDetermined)) == .granted

        var failure: String?
        for index in items.indices {
            let item = items[index]
            let interval: TimeInterval
            switch item.location {
            case .tmux: interval = 3
            case .terminalApp where terminalAllowed: interval = 15
            default: continue
            }
            let due = now.timeIntervalSince(plan.lastCaptured[item.id] ?? .distantPast) >= interval
            let activityChanged = plan.wasActive[item.id] != item.isActive
            guard item.id == plan.selectedID || due || activityChanged, let bridge = bridge(for: item.location) else { continue }
            do {
                let screen = try bridge.capture(item.location)
                items[index].screen = screen
                items[index].analysis = AgentScreenParser.analyze(screen, kind: item.kind)
            } catch {
                // 고른 세션에서 난 문제만 알린다 (나머지는 다음에 다시 해 본다)
                if item.id == plan.selectedID { failure = failure ?? error.localizedDescription }
            }
        }

        return PollResult(date: now, items: items, usage: plan.readUsage ? usageReader.read() : nil,
                          permission: permission, error: failure)
    }

    /// tmux 서버가 떠 있는지 소켓 파일로 본다 (없으면 tmux를 실행하지 않는다)
    nonisolated private static var tmuxServerRunning: Bool {
        guard TmuxBridge.shared.executable != nil else { return false }
        let base = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
        return FileManager.default.fileExists(atPath: "\(base)/tmux-\(getuid())/default")
    }
}

// MARK: - 미리보기 (`--render`, 화면 작업용 가짜 데이터)

extension AgentStore {
    static func preview() -> AgentStore {
        let store = AgentStore()
        let now = Date()
        let claudeScreen = """
        ⏺ 바뀐 README를 커밋했어요. 이제 GitHub에 올릴게요.

        ╭──────────────────────────────────────────────────────────────────────╮
        │ Bash command                                                         │
        │                                                                      │
        │   git push origin agents                                             │
        │   Push the agents branch to GitHub                                   │
        │                                                                      │
        │ Do you want to proceed?                                              │
        │ ❯ 1. Yes                                                             │
        │   2. Yes, and don't ask again for git push commands in menu_bar      │
        │   3. No, and tell Claude what to do differently (esc)                │
        ╰──────────────────────────────────────────────────────────────────────╯
        """
        let codexScreen = """
        • Ran rg "NotchModel" -n Sources
          └ Sources/Cheoma/Notch/NotchModel.swift:11:final class NotchModel

        • Explored
          └ Read DashboardView.swift, FanTab.swift

        ◦ Working (42s • esc to interrupt)

        › Ask Codex to do anything
        """
        let piScreen = """
        Done. Summarized 12 notes into weekly.md (3 new tasks).

        ──────────────────────────────────────────────
        >
        ──────────────────────────────────────────────
        claude-opus-5-5 · ~/notes · $0.42
        """
        store.sessions = [
            AgentSession(
                id: "terminal:/dev/ttys004", kind: .claude, pid: 4101,
                location: .terminalApp(tty: "/dev/ttys004"),
                cwd: "/Users/me/Documents/menu_bar", title: "Agents tab for the notch",
                startedAt: now.addingTimeInterval(-3_100), state: .needsChoice, stateSince: now.addingTimeInterval(-95),
                analysis: ScreenAnalysis(
                    state: .needsChoice, question: "Do you want to proceed?",
                    choices: [
                        AgentChoice(key: "1", label: "Yes", isHighlighted: true),
                        AgentChoice(key: "2", label: "Yes, and don't ask again for git push commands in menu_bar", isHighlighted: false),
                        AgentChoice(key: "3", label: "No, and tell Claude what to do differently", isHighlighted: false),
                    ],
                    summary: "Bash command: git push origin agents"),
                screen: TerminalScreen(text: claudeScreen, capturedAt: now),
                lastEvent: nil, isLaunchedByCheoma: false),
            AgentSession(
                id: "tmux:%3", kind: .codex, pid: 5202,
                location: .tmux(paneID: "%3", tty: "/dev/ttys007"),
                cwd: "/Users/me/Documents/MJ-couple", title: nil,
                startedAt: now.addingTimeInterval(-720), state: .working, stateSince: now.addingTimeInterval(-42),
                analysis: ScreenAnalysis(state: .working, question: nil, choices: [], summary: "Working (42s • esc to interrupt)"),
                screen: TerminalScreen(text: codexScreen, capturedAt: now),
                lastEvent: nil, isLaunchedByCheoma: true),
            AgentSession(
                id: "tmux:%5", kind: .pi, pid: 6303,
                location: .tmux(paneID: "%5", tty: "/dev/ttys009"),
                cwd: "/Users/me/notes", title: nil,
                startedAt: now.addingTimeInterval(-4_000), state: .needsInput, stateSince: now.addingTimeInterval(-600),
                analysis: ScreenAnalysis(state: .needsInput, question: nil, choices: [], summary: "Done. Summarized 12 notes into weekly.md"),
                screen: TerminalScreen(text: piScreen, capturedAt: now),
                lastEvent: nil, isLaunchedByCheoma: true),
        ]
        store.sessions = store.sessions.map { session in
            var session = session
            session.lastActivity = session.stateSince
            if session.kind == .claude { session.account = ".claude-account2" }
            return session
        }.sorted(by: order)
        store.selectedID = "terminal:/dev/ttys004"
        store.recordedSessions = [
            RecordedSession(id: "c9db0d62", kind: .claude, cwd: "/Users/me/Documents/MJ-couple", title: "Couple app onboarding flow",
                            lastActivity: now.addingTimeInterval(-300), costUSD: 2.31, lastMessage: "온보딩 화면 세 장을 만들었어요.", isTurnComplete: true),
            RecordedSession(id: "019a0e3d", kind: .codex, cwd: "/Users/me/Documents/api", title: nil,
                            lastActivity: now.addingTimeInterval(-1_800), costUSD: nil, lastMessage: "Added pagination to /items", isTurnComplete: true),
        ]
        store.usage = AgentUsage(
            codex: CodexUsage(primary: UsageWindow(usedPercent: 4, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3_600)),
                              secondary: UsageWindow(usedPercent: 14, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400)),
                              plan: "plus", updatedAt: now.addingTimeInterval(-600)),
            claude: [
                ClaudeUsage(account: ".claude", todayCostUSD: 3.2, todayTokens: 1_240_000, blockCostUSD: 1.1,
                            blockStartedAt: now.addingTimeInterval(-2 * 3_600), blockEndsAt: now.addingTimeInterval(3 * 3_600),
                            limits: [UsageWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3_600)),
                                     UsageWindow(usedPercent: 68, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400))],
                            updatedAt: now, limitsUpdatedAt: now),
                ClaudeUsage(account: ".claude-account2", todayCostUSD: 12.4, todayTokens: 5_800_000, blockCostUSD: 4.7,
                            blockStartedAt: now.addingTimeInterval(-3_600), blockEndsAt: now.addingTimeInterval(4 * 3_600),
                            limits: [UsageWindow(usedPercent: 91, windowMinutes: 300, resetsAt: now.addingTimeInterval(40 * 60)),
                                     UsageWindow(usedPercent: 35, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400))],
                            updatedAt: now, limitsUpdatedAt: now),
            ],
            recentSessions: store.recordedSessions)
        store.hookStatus = HookInstaller.Status(
            claude: [HookInstaller.ClaudeTarget(configDir: URL(fileURLWithPath: "/Users/me/.claude"), hooks: true, statusLine: .installed),
                     HookInstaller.ClaudeTarget(configDir: URL(fileURLWithPath: "/Users/me/.claude-account2"), hooks: false, statusLine: .notInstalled)],
            codex: .occupied("notify-send"))
        store.terminalPermission = .granted
        store.isTmuxAvailable = true
        store.installedAgents = [.claude, .codex, .opencode, .pi]
        store.recentFolders = ["/Users/me/Documents/menu_bar", "/Users/me/Documents/MJ-couple", "/Users/me/notes"]
        return store
    }
}

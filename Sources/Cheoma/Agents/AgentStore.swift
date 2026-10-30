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
    var isVisible = false
    /// 사용자가 봐야 하는 세션이 생기면 노치 알림을 띄운다
    var onAlert: ((NotchAlert, AgentSession.ID) -> Void)?

    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    func start() {}

    func select(_ id: AgentSession.ID?) {
        selectedID = id
    }

    /// 글자를 보내고 Enter를 누른다
    func send(text: String, to id: AgentSession.ID) {}

    /// 특수 키를 보낸다 (tmux 세션만)
    func send(key: TerminalKey, to id: AgentSession.ID) {}

    /// 화면의 선택지를 고른다
    func choose(_ choice: AgentChoice, in id: AgentSession.ID) {}

    /// 그 터미널 탭을 앞으로 가져온다
    func reveal(_ id: AgentSession.ID) {}

    /// Cheoma가 띄운 tmux 세션을 끝낸다
    func stop(_ id: AgentSession.ID) {}

    /// 새 tmux 세션에서 에이전트를 띄운다
    func launch(_ kind: AgentKind, in folder: String) {}

    /// Terminal 자동화 권한을 묻는다 (사용자가 버튼을 눌렀을 때만)
    func requestTerminalAccess() {}

    /// Claude Code · Codex 설정에 Cheoma 훅을 넣는다 / 뺀다
    func installHooks() {}
    func uninstallHooks() {}

    /// 바로 다시 확인한다
    func refreshNow() {}
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
                            blockStartedAt: now.addingTimeInterval(-2 * 3_600), blockEndsAt: now.addingTimeInterval(3 * 3_600), updatedAt: now),
                ClaudeUsage(account: ".claude-account2", todayCostUSD: 12.4, todayTokens: 5_800_000, blockCostUSD: 4.7,
                            blockStartedAt: now.addingTimeInterval(-3_600), blockEndsAt: now.addingTimeInterval(4 * 3_600), updatedAt: now),
            ],
            recentSessions: store.recordedSessions)
        store.hookStatus = HookInstaller.Status(
            claude: [HookInstaller.ClaudeTarget(configDir: URL(fileURLWithPath: "/Users/me/.claude"), isInstalled: true),
                     HookInstaller.ClaudeTarget(configDir: URL(fileURLWithPath: "/Users/me/.claude-account2"), isInstalled: false)],
            codex: .occupied("notify-send"))
        store.terminalPermission = .granted
        store.isTmuxAvailable = true
        store.installedAgents = [.claude, .codex, .opencode, .pi]
        store.recentFolders = ["/Users/me/Documents/menu_bar", "/Users/me/Documents/MJ-couple", "/Users/me/notes"]
        return store
    }
}

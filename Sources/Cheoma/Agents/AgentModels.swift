import Foundation

// 코드 에이전트(Claude Code, Codex, OpenCode, pi …) 기능이 같이 쓰는 타입들.
// 프로세스 찾기 · 터미널 연동 · 화면 분석 · 훅 · 사용량 모듈이 이 타입으로 주고받는다.

/// 노치에서 지켜보는 코드 에이전트 종류
enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, opencode, pi, gemini, aider

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "pi"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        }
    }

    /// 새로 띄울 때 사용자 로그인 셸에서 실행하는 명령
    var command: String { rawValue }
}

/// 에이전트가 돌고 있는 터미널 자리
enum TerminalLocation: Hashable, Codable, Sendable {
    /// Terminal.app 탭. 탭은 tty로 찾는다 (예: "/dev/ttys004")
    case terminalApp(tty: String)
    /// tmux 패널. paneID는 "%3" 같은 tmux 고유 ID, tty는 패널의 tty
    case tmux(paneID: String, tty: String)
    /// 연동하지 않는 터미널이나 앱 안 (VS Code, Cursor, Ghostty, Claude 데스크톱 앱 등): 보기만 한다
    case other(tty: String?, app: String?)

    var tty: String? {
        switch self {
        case .terminalApp(let tty): tty
        case .tmux(_, let tty): tty
        case .other(let tty, _): tty
        }
    }

    /// 화면을 읽고 글자를 보낼 수 있는지
    var canReply: Bool {
        switch self {
        case .terminalApp, .tmux: true
        case .other: false
        }
    }

    /// Esc · 방향키 · Ctrl-C 같은 특수 키나 Enter 없는 글자를 보낼 수 있는지 (Terminal.app은 글자 + Enter만 된다)
    var canSendKeys: Bool {
        if case .tmux = self { return true }
        return false
    }
}

/// 에이전트 상태
enum AgentState: String, Codable, Sendable {
    /// 출력이 계속 바뀌는 중
    case working
    /// 허락이나 선택지를 기다림 (화면에 고를 것이 있다)
    case needsChoice
    /// 다음 지시를 기다림 (입력창이 비어 있다)
    case needsInput
    /// 프로세스가 끝났다
    case exited
    /// 아직 판단하지 못함
    case unknown

    var title: String {
        switch self {
        case .working: "작업 중"
        case .needsChoice: "선택 기다림"
        case .needsInput: "입력 기다림"
        case .exited: "끝남"
        case .unknown: "확인 중"
        }
    }

    /// 사용자가 뭔가 해 줘야 하는 상태
    var needsAttention: Bool { self == .needsChoice || self == .needsInput }
}

/// 화면에서 읽은 선택지 하나
struct AgentChoice: Hashable, Sendable {
    /// 이 선택지를 고르려고 보내는 글자 ("1", "y" …)
    var key: String
    /// 화면에 적힌 이름 ("Yes", "Yes, and don't ask again …")
    var label: String
    /// 지금 커서(❯ 등)가 가리키는 선택지
    var isHighlighted: Bool
    /// 글자를 보낸 뒤 Enter도 눌러야 고른 것이 되는지 ("[y/N]" 같은 질문). 번호 메뉴는 글자만으로 바로 골라진다
    var needsEnter: Bool = false
}

/// 터미널 화면 한 장
struct TerminalScreen: Equatable, Sendable {
    /// 화면에 보이는 줄들을 줄바꿈으로 이은 것. tmux에서 읽으면 ANSI 색 코드가 들어 있고, Terminal.app은 글자만 있다
    var text: String
    var capturedAt: Date
}

/// 화면을 보고 판단한 결과 (AgentScreenParser)
struct ScreenAnalysis: Equatable, Sendable {
    /// 화면만 보고 판단한 상태: working · needsChoice · needsInput · unknown
    var state: AgentState
    /// 선택지 위의 질문 ("Do you want to proceed?" …)
    var question: String?
    var choices: [AgentChoice]
    /// 목록에 한 줄로 보여줄 요약 (마지막 의미 있는 줄)
    var summary: String?
}

/// 특수 키 (tmux로만 보낼 수 있다)
enum TerminalKey: String, CaseIterable, Sendable {
    case enter, escape, tab, up, down, left, right, backspace, ctrlC
}

/// 터미널 연동 중 생긴 문제. 메시지는 그대로 화면에 보여준다
struct AgentBridgeError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// 터미널 연동 (Terminal.app, tmux). 백그라운드 큐에서 부른다. 막힐 수 있는 일(Apple Event, 프로세스 실행)을 하므로 메인 스레드에서 부르지 않는다
protocol TerminalBridge: AnyObject {
    /// 지금 화면을 읽는다
    func capture(_ location: TerminalLocation) throws -> TerminalScreen
    /// 글자를 보낸다. Terminal.app은 pressEnter와 상관없이 늘 Enter가 같이 간다
    func send(text: String, pressEnter: Bool, to location: TerminalLocation) throws
    /// 특수 키를 보낸다 (tmux만)
    func send(key: TerminalKey, to location: TerminalLocation) throws
    /// 그 터미널 창·탭을 앞으로 가져온다
    func reveal(_ location: TerminalLocation) throws
}

/// 돌고 있는 에이전트 프로세스 하나 (AgentScanner가 찾는다)
struct AgentProcess: Hashable, Sendable {
    var pid: pid_t
    var kind: AgentKind
    /// "/dev/ttys004". nil이면 터미널 밖에서 돈다 (IDE 확장, 데스크톱 앱 등)
    var tty: String?
    /// 작업 폴더
    var cwd: String?
    var startedAt: Date?
    /// 이 프로세스를 띄운 앱 (Terminal, Code, Cursor, tmux …). 모르면 nil
    var hostApp: String?
}

/// 최근 5시간 · 1주 같은 사용 한도 구간 하나
struct UsageWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

/// Codex 사용량 (Codex 세션 기록의 rate_limits)
struct CodexUsage: Equatable, Sendable {
    /// 보통 5시간 구간
    var primary: UsageWindow?
    /// 보통 1주 구간
    var secondary: UsageWindow?
    /// "plus", "pro" …
    var plan: String?
    /// 이 값을 기록한 시각 (Codex를 마지막으로 쓴 때). 오래됐으면 지금은 더 회복돼 있다
    var updatedAt: Date
}

/// Claude Code 사용량 (설정 폴더 하나 = 계정 하나)
struct ClaudeUsage: Equatable, Sendable {
    /// 설정 폴더 이름 (".claude", ".claude-account2" …)
    var account: String
    var todayCostUSD: Double
    /// 오늘 쓴 토큰 (입력 + 출력 + 캐시)
    var todayTokens: Int
    /// 지금 진행 중인 5시간 구간의 비용 (ccusage와 같은 방식: 첫 요청부터 5시간)
    var blockCostUSD: Double
    var blockStartedAt: Date?
    var blockEndsAt: Date?
    /// 구독의 5시간 · 주간 한도 (Cheoma 상태 줄이 받아 둔 값). 상태 줄을 연결하지 않았거나 아직 요청이 없었으면 비어 있다
    var limits: [UsageWindow] = []
    var updatedAt: Date?
    /// limits를 받은 시각 (그 계정으로 Claude Code를 마지막으로 쓴 때)
    var limitsUpdatedAt: Date?
    /// 설정 폴더 전체 경로 (이 계정으로 실행할 때 CLAUDE_CONFIG_DIR)
    var configDir: String = ""
    /// 로그인한 계정 (.claude.json의 oauthAccount)
    var email: String?
    var displayName: String?
    /// "Max 20x" …
    var plan: String?
}

/// 에이전트 탭 위쪽의 Claude 사용량을 무엇으로 보여줄지 (연결 설정에서 고른다)
enum ClaudeUsageDisplay: String, CaseIterable, Sendable {
    /// 구독의 5시간 · 주간 한도를 쓴 비율 (기본)
    case limits
    /// 기록의 토큰을 API 가격으로 셈한 비용. 구독이면 실제로 청구되는 돈이 아니다
    case cost

    static let defaultsKey = "agents.claudeUsageDisplay"

    var title: String {
        switch self {
        case .limits: "구독 한도"
        case .cost: "API 환산 비용"
        }
    }
}

/// 돌고 있는 Claude Code 프로세스가 스스로 적어 두는 정보 (`<설정 폴더>/sessions/<pid>.json`)
struct LiveClaudeSession: Equatable, Sendable {
    var sessionID: String
    /// 설정 폴더 이름 (".claude", ".claude-account2" …)
    var account: String
    /// "idle"(입력 기다림), "busy"(작업 중), "waiting"(권한 묻기)
    var status: String?
    var statusSince: Date?
}

/// 기록 파일로 아는 최근 세션. 터미널 밖 세션(Claude 데스크톱 앱, VS Code의 Codex 등)도 여기서 보인다 (보기만)
struct RecordedSession: Identifiable, Equatable, Sendable {
    /// 에이전트의 세션 ID
    var id: String
    var kind: AgentKind
    var cwd: String?
    /// Claude의 ai-title 같은 세션 제목
    var title: String?
    var lastActivity: Date
    var costUSD: Double?
    /// 마지막 어시스턴트 메시지의 첫 줄 (짧게)
    var lastMessage: String?
    /// 마지막 차례가 끝났는지 (Codex task_complete, Claude 마지막 줄이 어시스턴트 응답 …)
    var isTurnComplete: Bool?
    /// Claude Code 설정 폴더 이름 (".claude", ".claude-account2" …). 이어서 할 때 이 계정의 기록을 쓴다
    var account: String? = nil
    /// 기록 파일 (다른 계정으로 이어서 할 때 그 계정으로 옮긴다)
    var transcriptPath: String? = nil
}

/// 사용량과 최근 세션 (AgentUsageReader)
struct AgentUsage: Equatable, Sendable {
    var codex: CodexUsage?
    var claude: [ClaudeUsage] = []
    /// 최근 24시간 세션, 최근 것부터
    var recentSessions: [RecordedSession] = []
    /// Codex 로그인 (~/.codex/auth.json)
    var codexAccount: AgentAccounts.Codex?
}

/// 에이전트 훅이 보낸 이벤트 (Claude Code 훅, Codex notify)
struct AgentHookEvent: Codable, Equatable, Sendable {
    var kind: AgentKind
    /// "Notification", "Stop", "SessionStart", "SessionEnd", "UserPromptSubmit", "agent-turn-complete" …
    var name: String
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?
    /// 에이전트 프로세스의 tty (훅 프로세스의 부모에서 읽는다). 이걸로 터미널 탭을 찾는다
    var tty: String?
    var agentPID: Int32?
    /// 알림 내용, 마지막 메시지 등
    var message: String?
    /// Claude Notification 훅의 종류 ("permission_prompt", "idle_prompt" …)
    var notificationType: String?
    var date: Date
}

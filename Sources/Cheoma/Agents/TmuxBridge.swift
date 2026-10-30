import Foundation

/// tmux 패널 하나
struct TmuxPane: Hashable, Sendable {
    /// "%3" 같은 tmux 고유 ID
    var paneID: String
    var sessionName: String
    /// "세션:창.패널"
    var target: String
    var tty: String
    /// 패널의 첫 프로세스 (보통 셸)
    var pid: pid_t
    var currentCommand: String
    var currentPath: String
    /// 이 세션에 붙어 있는 클라이언트 tty들 (Terminal 탭에서 tmux attach 중이면 그 탭의 tty)
    var clientTTYs: [String]
}

/// tmux 연동. 구현 예정
final class TmuxBridge: TerminalBridge {
    static let shared = TmuxBridge()
    /// Cheoma가 띄운 세션 이름의 앞부분
    static let sessionPrefix = "cheoma-"

    /// tmux 실행 파일 경로 (/opt/homebrew/bin/tmux, /usr/local/bin/tmux, PATH). 없으면 nil
    var executable: String? { nil }

    /// 모든 세션의 패널. tmux 서버가 안 떠 있으면 빈 배열
    func panes() throws -> [TmuxPane] {
        []
    }

    /// 새 tmux 세션에서 에이전트를 띄운다. 사용자 로그인 셸로 실행해서 PATH · 별칭이 터미널에서와 같다
    func launch(_ kind: AgentKind, in folder: String) throws -> TerminalLocation {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }

    /// 그 패널의 세션을 붙이는 명령 (`tmux attach -t …`). Terminal 새 탭에서 열 때 쓴다
    func attachCommand(for location: TerminalLocation) -> String? {
        nil
    }

    /// Cheoma가 띄운 세션을 끝낸다
    func kill(_ location: TerminalLocation) throws {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }

    func capture(_ location: TerminalLocation) throws -> TerminalScreen {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }

    func send(text: String, pressEnter: Bool, to location: TerminalLocation) throws {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }

    func send(key: TerminalKey, to location: TerminalLocation) throws {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }

    func reveal(_ location: TerminalLocation) throws {
        throw AgentBridgeError(message: "tmux 연동은 아직 준비 중이에요")
    }
}

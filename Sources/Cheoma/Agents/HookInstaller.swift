import Foundation

/// 에이전트 설정에 Cheoma 훅을 넣고 뺀다. 구현 예정:
/// Claude Code settings.json에 훅을 합쳐 넣고(다른 설정과 훅은 그대로, 고치기 전에 백업), Codex는 notify가 비어 있을 때만 넣는다
enum HookInstaller {
    /// Claude Code 설정 폴더 하나 (~/.claude, ~/.claude-account2 …)
    struct ClaudeTarget: Equatable, Sendable {
        var configDir: URL
        var isInstalled: Bool
    }

    enum CodexStatus: Equatable, Sendable {
        case notInstalled
        case installed
        /// notify에 이미 다른 프로그램이 있어서 건드리지 않는다
        case occupied(String)
        /// Codex 설정이 없음
        case unavailable
    }

    struct Status: Equatable, Sendable {
        var claude: [ClaudeTarget]
        var codex: CodexStatus
    }

    static func status() -> Status {
        Status(claude: [], codex: .unavailable)
    }

    static func installClaude(configDir: URL) throws {
        throw AgentBridgeError(message: "훅 설치는 아직 준비 중이에요")
    }

    static func uninstallClaude(configDir: URL) throws {
        throw AgentBridgeError(message: "훅 설치는 아직 준비 중이에요")
    }

    static func installCodex() throws {
        throw AgentBridgeError(message: "훅 설치는 아직 준비 중이에요")
    }

    static func uninstallCodex() throws {
        throw AgentBridgeError(message: "훅 설치는 아직 준비 중이에요")
    }
}

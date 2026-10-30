import AppKit

/// Terminal.app 탭 하나
struct TerminalAppTab: Hashable, Sendable {
    var tty: String
    /// Terminal 창 ID (AppleScript `id of window`)
    var windowID: Int
    /// 창 안에서 탭 순서 (1부터)
    var tabIndex: Int
    var title: String?
    var isBusy: Bool
    /// 탭에서 도는 프로세스 이름들 (AppleScript `processes of tab`)
    var processes: [String]
}

/// Terminal.app이 처음 Apple Event를 받을 때 macOS가 묻는 "자동화" 권한
enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    /// 아직 묻지 않음
    case notDetermined
    /// Terminal이 꺼져 있어서 알 수 없음
    case targetNotRunning
}

/// Terminal.app 연동 (AppleScript). 구현 예정
final class TerminalAppBridge: TerminalBridge {
    static let shared = TerminalAppBridge()
    static let bundleIdentifier = "com.apple.Terminal"

    /// Terminal.app이 켜져 있는지 (Apple Event 없이)
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// 자동화 권한 상태. askIfNeeded가 true면 아직 안 물었을 때 macOS가 사용자에게 묻는다
    func permission(askIfNeeded: Bool) -> AutomationPermission {
        .notDetermined
    }

    /// 모든 창의 탭 목록
    func tabs() throws -> [TerminalAppTab] {
        throw AgentBridgeError(message: "Terminal 연동은 아직 준비 중이에요")
    }

    /// 새 탭(창이 없으면 새 창)을 열고 폴더에서 명령을 실행한다. 새 에이전트 실행, tmux 세션 열기에 쓴다
    func openTab(command: String, in folder: String?) throws {
        throw AgentBridgeError(message: "Terminal 연동은 아직 준비 중이에요")
    }

    func capture(_ location: TerminalLocation) throws -> TerminalScreen {
        throw AgentBridgeError(message: "Terminal 연동은 아직 준비 중이에요")
    }

    func send(text: String, pressEnter: Bool, to location: TerminalLocation) throws {
        throw AgentBridgeError(message: "Terminal 연동은 아직 준비 중이에요")
    }

    func send(key: TerminalKey, to location: TerminalLocation) throws {
        throw AgentBridgeError(message: "Terminal은 특수 키를 보낼 수 없어요")
    }

    func reveal(_ location: TerminalLocation) throws {
        throw AgentBridgeError(message: "Terminal 연동은 아직 준비 중이에요")
    }
}

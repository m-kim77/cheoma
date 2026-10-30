import Foundation

/// 에이전트 훅 → 실행 중인 Cheoma. 구현 예정:
/// `Cheoma --agent-event claude` (Claude Code 훅: 이벤트 JSON이 stdin으로 온다),
/// `Cheoma --agent-event codex '<json>'` (Codex notify: JSON이 마지막 인자로 온다).
/// 훅 프로세스의 부모(에이전트)에서 tty와 pid를 읽어 같이 보낸다
enum AgentHooks {
    static let notificationName = Notification.Name("io.github.m-kim77.cheoma.agent-event")

    /// 보내는 쪽 (훅이 띄우는 별도 프로세스). 훅을 막지 않도록 빨리 끝나야 한다
    static func send(arguments: [String]) {}

    /// 받는 쪽 (실행 중인 앱)
    static func event(from notification: Notification) -> AgentHookEvent? {
        nil
    }
}

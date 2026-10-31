import Foundation

/// 에이전트 훅 → 실행 중인 Cheoma.
/// - `Cheoma --agent-event claude`: Claude Code 훅. 이벤트 JSON이 stdin으로 온다
///   (session_id, cwd, transcript_path, hook_event_name, message, notification_type, last_assistant_message …)
/// - `Cheoma --agent-event codex '<json>'`: Codex notify. JSON이 마지막 인자로 온다 (type, cwd, last-assistant-message …)
/// 훅 프로세스의 부모(에이전트)에서 tty와 pid를 읽어 같이 보내고, 분산 알림으로 앱에 넘긴다.
/// 아무것도 출력하지 않는다: Claude는 일부 훅(UserPromptSubmit, SessionStart)의 stdout을 대화에 넣는다
enum AgentHooks {
    static let notificationName = Notification.Name("io.github.m-kim77.cheoma.agent-event")
    private static let payloadKey = "event"
    /// stdin을 이만큼만 읽는다 (마지막 메시지가 아주 길 수 있다)
    private static let maxInput = 256 << 10

    /// 보내는 쪽 (훅이 띄우는 별도 프로세스). 훅을 막지 않도록 빨리 끝나야 한다
    static func send(arguments: [String]) {
        guard let kindName = arguments.first, let kind = AgentKind(rawValue: kindName) else { return }
        let input: Data
        if kind == .claude {
            input = FileHandle.standardInput.readData(ofLength: maxInput)
        } else {
            input = Data((arguments.dropFirst().last ?? "").utf8)
        }
        let agent = AgentScanner.launchingAgent()
        guard let event = event(kind: kind, json: input, tty: agent?.tty, agentPID: agent?.pid, date: Date()),
              let data = try? JSONEncoder().encode(event), let text = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil, userInfo: [payloadKey: text], deliverImmediately: true)
    }

    /// 훅 입력 JSON → 이벤트. 모르는 형식이면 nil
    static func event(kind: AgentKind, json: Data, tty: String?, agentPID: pid_t?, date: Date) -> AgentHookEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let name: String?
        let message: String?
        let sessionID: String?
        switch kind {
        case .codex:
            name = string("type")
            message = string("last-assistant-message")
            sessionID = string("thread-id")
        default:
            name = string("hook_event_name")
            message = string("message") ?? string("last_assistant_message")
            sessionID = string("session_id")
        }
        guard let name else { return nil }
        return AgentHookEvent(
            kind: kind, name: name, sessionID: sessionID, cwd: string("cwd"), transcriptPath: string("transcript_path"),
            tty: tty, agentPID: agentPID.map { Int32($0) }, message: message.map(firstLine),
            notificationType: string("notification_type"), date: date)
    }

    /// 받는 쪽 (실행 중인 앱)
    static func event(from notification: Notification) -> AgentHookEvent? {
        guard let text = notification.userInfo?[payloadKey] as? String else { return nil }
        return try? JSONDecoder().decode(AgentHookEvent.self, from: Data(text.utf8))
    }

    /// 알림에는 첫 줄만 쓴다 (분산 알림으로 큰 글을 보내지 않게)
    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}

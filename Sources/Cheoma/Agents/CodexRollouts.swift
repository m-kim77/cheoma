import Foundation

// Codex 기록 (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) 읽기. VS Code의 Codex 확장도 여기에 쓴다.
// 줄마다 {"timestamp", "type", "payload"}이고, event_msg/token_count의 rate_limits에 5시간 · 1주 사용 %가 들어 있다

extension AgentUsageReader {
    struct CodexLimits {
        var time: Double
        var usage: CodexUsage
    }

    final class CodexFile {
        var stat: JSONLFile.Stat
        var offset: Int64 = 0
        var sessionID: String?
        var cwd: String?
        var lastMessage: String?
        var isTurnComplete: Bool?
        var lastTime: Double?
        var limits: CodexLimits?

        init(stat: JSONLFile.Stat) { self.stat = stat }
    }

    func parseCodexLine(_ j: JSONBytes, file: CodexFile) {
        guard j.byte(0) == UInt8(ascii: "{") else { return }
        var timestamp: Range<Int>?
        var type: Range<Int>?
        var payload: Range<Int>?
        j.forEachMember(ofObjectAt: 0) { key, value in
            if j.key(key, is: "timestamp") {
                timestamp = value
            } else if j.key(key, is: "type") {
                type = value
            } else if j.key(key, is: "payload") {
                payload = value
            }
            return timestamp == nil || type == nil || payload == nil
        }
        guard let type, let payload, j.isObject(payload) else { return }
        let time = timestamp.flatMap { j.date($0) }
        if let time { file.lastTime = max(file.lastTime ?? 0, time) }

        if j.stringValue(type, is: "session_meta") {
            j.forEachMember(ofObjectAt: payload.lowerBound) { key, value in
                if j.key(key, is: "id") {
                    file.sessionID = j.string(value)
                } else if j.key(key, is: "cwd") {
                    file.cwd = j.string(value)
                }
                return file.sessionID == nil || file.cwd == nil
            }
        } else if j.stringValue(type, is: "turn_context") {
            if let cwd = j.member("cwd", ofObjectAt: payload.lowerBound), let path = j.string(cwd) { file.cwd = path }
        } else if j.stringValue(type, is: "event_msg") {
            parseCodexEvent(j, payload: payload, time: time, file: file)
        } else if j.stringValue(type, is: "response_item") {
            parseCodexResponse(j, payload: payload, file: file)
        }
    }

    private func parseCodexEvent(_ j: JSONBytes, payload: Range<Int>, time: Double?, file: CodexFile) {
        var kind: Range<Int>?
        j.forEachMember(ofObjectAt: payload.lowerBound) { key, value in
            if j.key(key, is: "type") {
                kind = value
                // 필요 없는 이벤트는 여기서 그만 읽는다
                return j.stringValue(value, is: "task_complete") || j.stringValue(value, is: "token_count") || j.stringValue(value, is: "agent_message")
            }
            guard let kind else { return true }
            if j.stringValue(kind, is: "task_complete"), j.key(key, is: "last_agent_message") {
                if let text = j.string(value, maxBytes: 2_000), let line = Self.firstLine(text) { file.lastMessage = line }
                return false
            }
            if j.stringValue(kind, is: "agent_message"), j.key(key, is: "message") {
                if let text = j.string(value, maxBytes: 2_000), let line = Self.firstLine(text) { file.lastMessage = line }
                return false
            }
            if j.stringValue(kind, is: "token_count"), j.key(key, is: "rate_limits") {
                if let time, let usage = codexUsage(j, rateLimits: value, time: time), time >= (file.limits?.time ?? 0) {
                    file.limits = CodexLimits(time: time, usage: usage)
                }
                return false
            }
            return true
        }
        guard let kind else { return }
        if j.stringValue(kind, is: "task_started") || j.stringValue(kind, is: "user_message") {
            file.isTurnComplete = false
        } else if j.stringValue(kind, is: "task_complete") || j.stringValue(kind, is: "turn_aborted") {
            file.isTurnComplete = true
        }
    }

    private func parseCodexResponse(_ j: JSONBytes, payload: Range<Int>, file: CodexFile) {
        var isMessage = false
        var isAssistant = false
        var content: Range<Int>?
        j.forEachMember(ofObjectAt: payload.lowerBound) { key, value in
            if j.key(key, is: "type") {
                isMessage = j.stringValue(value, is: "message")
                return isMessage
            }
            if j.key(key, is: "role") {
                isAssistant = j.stringValue(value, is: "assistant")
                return isAssistant
            }
            if j.key(key, is: "content") { content = value }
            return content == nil
        }
        guard isMessage, isAssistant, let content, j.isArray(content) else { return }
        var last: Range<Int>?
        j.forEachElement(ofArrayAt: content.lowerBound) { item in
            if let text = j.member("text", ofObjectAt: item.lowerBound) { last = text }
            return true
        }
        if let last, let text = j.string(last, maxBytes: 2_000), let line = Self.firstLine(text) { file.lastMessage = line }
    }

    /// rate_limits 객체 → CodexUsage. 다른 한도(limit_id가 codex가 아닌 것)는 건너뛴다
    private func codexUsage(_ j: JSONBytes, rateLimits: Range<Int>, time: Double) -> CodexUsage? {
        guard j.isObject(rateLimits) else { return nil }
        var usage = CodexUsage(primary: nil, secondary: nil, plan: nil, updatedAt: Date(timeIntervalSince1970: time))
        var otherLimit = false
        j.forEachMember(ofObjectAt: rateLimits.lowerBound) { key, value in
            if j.key(key, is: "limit_id") {
                otherLimit = j.isString(value) && !j.stringValue(value, is: "codex")
            } else if j.key(key, is: "primary") {
                usage.primary = window(j, value, time: time)
            } else if j.key(key, is: "secondary") {
                usage.secondary = window(j, value, time: time)
            } else if j.key(key, is: "plan_type") {
                usage.plan = j.string(value)
            }
            return !otherLimit
        }
        guard !otherLimit, usage.primary != nil || usage.secondary != nil else { return nil }
        return usage
    }

    private func window(_ j: JSONBytes, _ range: Range<Int>, time: Double) -> UsageWindow? {
        guard j.isObject(range) else { return nil }
        var used: Double?
        var minutes = 0
        var resetsAt: Date?
        j.forEachMember(ofObjectAt: range.lowerBound) { key, value in
            if j.key(key, is: "used_percent") {
                used = j.double(value)
            } else if j.key(key, is: "window_minutes") {
                minutes = j.int(value) ?? 0
            } else if j.key(key, is: "resets_at"), let seconds = j.double(value) {
                resetsAt = Date(timeIntervalSince1970: seconds)
            } else if j.key(key, is: "resets_in_seconds"), resetsAt == nil, let seconds = j.double(value) {
                // 옛 버전은 기록 시각부터 남은 초로 적었다
                resetsAt = Date(timeIntervalSince1970: time + seconds)
            }
            return true
        }
        guard let used else { return nil }
        return UsageWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
    }

    /// session_index.jsonl 한 줄 → (세션 ID, 제목)
    func parseCodexIndexLine(_ j: JSONBytes) -> (String, String)? {
        var id: String?
        var name: String?
        j.forEachMember(ofObjectAt: 0) { key, value in
            if j.key(key, is: "id") {
                id = j.string(value)
            } else if j.key(key, is: "thread_name") {
                name = j.string(value, maxBytes: 400)
            }
            return id == nil || name == nil
        }
        guard let id, let name, !name.isEmpty else { return nil }
        return (id, name)
    }
}

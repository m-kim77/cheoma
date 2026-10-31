import Foundation

/// Claude Code 상태 줄 ↔ Cheoma.
/// 구독의 5시간 · 주간 한도는 기록 파일에 남지 않고, Claude Code가 상태 줄 명령에 넘기는 JSON(`rate_limits`)에만 있다.
/// 그래서 `Cheoma --agent-statusline <설정 폴더>`를 상태 줄로 걸어 두고, 받은 한도를 계정마다 파일로 남겨 앱이 읽는다.
/// `rate_limits`는 그 세션에서 첫 요청을 보낸 뒤부터 들어온다 (10/31 확인: five_hour · seven_day의 used_percentage, resets_at)
enum ClaudeStatusLine {
    /// 계정마다 한도를 적어 두는 폴더
    static func limitsFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cheoma/claude-limits")
    }

    /// 상태 줄 명령 (Claude Code가 자주 부른다). stdin의 JSON에서 한도를 꺼내 저장하고, 상태 줄에 보일 한 줄을 찍는다
    static func run(arguments: [String]) {
        guard let configDir = arguments.first else { return }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let windows = limits(from: input) else { return }
        let account = URL(fileURLWithPath: configDir).lastPathComponent
        save(windows, account: account, date: Date())
        print(line(windows, now: Date()))
    }

    /// 상태 줄 입력 → 한도 (5시간, 주간 순). `rate_limits`가 없으면 nil
    static func limits(from json: Data) -> [UsageWindow]? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let rates = object["rate_limits"] as? [String: Any] else { return nil }
        let windows = [("five_hour", 300), ("seven_day", 10_080)].compactMap { key, minutes -> UsageWindow? in
            guard let window = rates[key] as? [String: Any], let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resets)
        }
        return windows.isEmpty ? nil : windows
    }

    /// "5시간 12% · 주간 68%"
    static func line(_ windows: [UsageWindow], now: Date) -> String {
        windows.map { window in
            let name = window.windowMinutes <= 300 ? "5시간" : "주간"
            let reset = window.resetsAt.map { $0 <= now } ?? false
            return "\(name) \(reset ? 0 : Int(window.usedPercent.rounded()))%"
        }.joined(separator: " · ")
    }

    // MARK: - 파일

    private struct Stored: Codable {
        struct Window: Codable {
            var usedPercent: Double
            var windowMinutes: Int
            var resetsAt: Date?
        }
        var windows: [Window]
        var updatedAt: Date
    }

    static func save(_ windows: [UsageWindow], account: String, date: Date,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let folder = limitsFolder(home: home)
        let stored = Stored(windows: windows.map { .init(usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt) },
                            updatedAt: date)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(account).json"), options: .atomic)
    }

    /// 저장해 둔 한도와 받은 시각
    static func load(account: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (windows: [UsageWindow], updatedAt: Date)? {
        let file = limitsFolder(home: home).appendingPathComponent("\(account).json")
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let windows = stored.windows.map { UsageWindow(usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt) }
        return (windows, stored.updatedAt)
    }

    // MARK: - 돌고 있는 세션

    /// Claude Code 프로세스가 적어 두는 `<설정 폴더>/sessions/<pid>.json`: 세션 ID, 상태(idle · busy · waiting).
    /// 설정 폴더마다 찾아본다 (어느 계정으로 도는지도 여기서 안다)
    static func liveSession(pid: pid_t, configDirs: [URL]) -> LiveClaudeSession? {
        for dir in configDirs {
            let file = dir.appendingPathComponent("sessions/\(pid).json")
            guard let data = try? Data(contentsOf: file) else { continue }
            return liveSession(json: data, account: dir.lastPathComponent)
        }
        return nil
    }

    static func liveSession(json: Data, account: String) -> LiveClaudeSession? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        let since = (object["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return LiveClaudeSession(sessionID: sessionID, account: account, status: object["status"] as? String, statusSince: since)
    }
}

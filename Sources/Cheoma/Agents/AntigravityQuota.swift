import Foundation

/// Antigravity CLI(agy) 계정의 한도. 모델 묶음(Gemini, Claude · GPT)마다 주간 한도가 따로 있다
struct AntigravityUsage: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        /// "Gemini Models", "Claude and GPT models"
        var name: String
        var windows: [UsageWindow]
    }

    var email: String?
    var groups: [Group]
    var updatedAt: Date
}

/// `agy -p /usage --output-format json`으로 한도를 묻는다. 모델을 부르지 않고 대화도 만들지 않는다 (agy 1.4.12, 11/2 확인).
/// agy가 한도를 파일에 남기지 않아서 이렇게 묻는다. 한 번에 몇 초 걸리고 부를 때마다 agy 로그 파일이 하나 생겨서 드물게 부른다
enum AntigravityQuota {
    static func read(executable: String) -> AntigravityUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 멈춰 버리면 30초 뒤에 끝낸다
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0, let groups = parse(data) else { return nil }
        return AntigravityUsage(email: lastEmail(), groups: groups, updatedAt: Date())
    }

    /// command.data.groups[].buckets[]: window("weekly" …), remaining_fraction, reset_time
    static func parse(_ data: Data) -> [AntigravityUsage.Group]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? [String: Any], let body = command["data"] as? [String: Any],
              let groups = body["groups"] as? [[String: Any]] else { return nil }
        let formatter = ISO8601DateFormatter()
        return groups.map { group in
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            let windows = buckets.compactMap { bucket -> UsageWindow? in
                guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
                return UsageWindow(usedPercent: max(0, min(100, (1 - remaining) * 100)),
                                   windowMinutes: minutes(bucket["window"] as? String),
                                   resetsAt: (bucket["reset_time"] as? String).flatMap(formatter.date(from:)))
            }
            return AntigravityUsage.Group(name: group["name"] as? String ?? "?", windows: windows)
        }
    }

    /// "weekly" → 10080분
    static func minutes(_ window: String?) -> Int {
        switch window?.lowercased() {
        case "weekly": 10_080
        case "daily": 1_440
        case "hourly": 60
        case let value? where value.hasSuffix("h"): (Int(value.dropLast()) ?? 0) * 60
        default: 0
        }
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude · GPT"
    static func shortName(_ group: String) -> String {
        var name = group.replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
        name = name.replacingOccurrences(of: " and ", with: " · ")
        return name
    }

    /// 로그인한 계정: 가장 최근 agy 로그의 "applyAuthResult: email=…"
    private static func lastEmail() -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/log")
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        for name in logs.reversed().prefix(5) {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                  let range = text.range(of: "email=", options: .backwards) else { continue }
            let email = text[range.upperBound...].prefix { $0 != "," && !$0.isWhitespace }
            if !email.isEmpty { return String(email) }
        }
        return nil
    }
}

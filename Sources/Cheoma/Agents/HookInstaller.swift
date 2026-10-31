import Foundation

/// 에이전트 설정에 Cheoma 훅을 넣고 뺀다.
/// - Claude Code: 설정 폴더마다 settings.json의 hooks에 Cheoma 항목을 합쳐 넣고, 상태 줄(statusLine)이 비어 있으면 Cheoma 상태 줄을 건다
///   (구독 한도는 상태 줄 입력으로만 받을 수 있다). 다른 설정과 훅은 그대로 두고, 처음 고치기 전에 백업한다
/// - Codex: config.toml의 notify가 비어 있을 때만 넣는다 (notify는 프로그램 하나만 받아서, 다른 것이 있으면 건드리지 않는다)
/// 훅 명령은 지금 실행 중인 Cheoma 실행 파일을 부른다. 앱이 없어져도 에이전트가 오류를 내지 않게 `[ -x … ]`로 감싼다
enum HookInstaller {
    /// Claude Code 설정 폴더 하나 (~/.claude, ~/.claude-account2 …)
    struct ClaudeTarget: Equatable, Sendable {
        var configDir: URL
        var hooks: Bool
        var statusLine: StatusLineState

        /// 더 넣을 것이 없다 (상태 줄을 다른 프로그램이 쓰고 있으면 훅만으로 끝)
        var isInstalled: Bool { hooks && statusLine != .notInstalled }
    }

    enum StatusLineState: Equatable, Sendable {
        case notInstalled
        case installed
        /// 다른 상태 줄이 있어서 건드리지 않는다 (구독 한도는 못 받는다)
        case occupied(String)
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

    /// 훅 명령에 들어 있으면 Cheoma 것으로 본다
    static let marker = "--agent-event"
    static let statusLineMarker = "--agent-statusline"
    /// Cheoma가 듣는 Claude Code 훅
    static let claudeEvents = ["Notification", "Stop", "UserPromptSubmit", "SessionStart", "SessionEnd"]
    static let backupSuffix = ".cheoma-backup"

    static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Status {
        let claude = AgentUsageReader.claudeConfigDirs(home: home, environment: environment).map { dir in
            let settings = readJSON(dir.appendingPathComponent("settings.json"))
            return ClaudeTarget(configDir: dir, hooks: isClaudeInstalled(settings: settings), statusLine: statusLineState(settings: settings))
        }
        let config = AgentUsageReader.codexHome(home: home, environment: environment).appendingPathComponent("config.toml")
        let codex: CodexStatus
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            codex = codexStatus(config: text)
        } else {
            let folder = config.deletingLastPathComponent().path
            codex = FileManager.default.fileExists(atPath: folder) ? .notInstalled : .unavailable
        }
        return Status(claude: claude, codex: codex)
    }

    // MARK: - Claude Code

    static func installClaude(configDir: URL, executable: String = currentExecutable) throws {
        let file = configDir.appendingPathComponent("settings.json")
        var settings = try readSettings(file)
        settings = installingClaude(into: settings, command: command(executable: executable, kind: .claude))
        // 다른 상태 줄이 있으면 그대로 둔다
        settings = installingStatusLine(into: settings, command: statusLineCommand(executable: executable, configDir: configDir))
        try write(settings, to: file)
    }

    static func uninstallClaude(configDir: URL) throws {
        let file = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try write(removingStatusLine(from: removingClaude(from: try readSettings(file))), to: file)
    }

    // MARK: - Claude Code 상태 줄

    static func statusLineState(settings: [String: Any]?) -> StatusLineState {
        guard let line = settings?["statusLine"] as? [String: Any] else { return .notInstalled }
        let command = line["command"] as? String ?? ""
        if command.contains(statusLineMarker) && command.contains("Cheoma") { return .installed }
        if command.isEmpty { return .notInstalled }
        return .occupied(command)
    }

    /// 상태 줄이 비어 있거나 Cheoma 것이면 Cheoma 상태 줄로 (다른 상태 줄은 그대로 둔다). 순수 함수
    static func installingStatusLine(into settings: [String: Any], command: String) -> [String: Any] {
        if case .occupied = statusLineState(settings: settings) { return settings }
        var settings = settings
        settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
        return settings
    }

    static func removingStatusLine(from settings: [String: Any]) -> [String: Any] {
        guard statusLineState(settings: settings) == .installed else { return settings }
        var settings = settings
        settings["statusLine"] = nil
        return settings
    }

    static func statusLineCommand(executable: String, configDir: URL) -> String {
        let exe = shellQuoted(executable)
        return "[ -x \(exe) ] && \(exe) \(statusLineMarker) \(shellQuoted(configDir.path)) || true"
    }

    /// settings에 Cheoma 훅을 넣는다 (있던 Cheoma 훅은 지우고 새 명령으로). 순수 함수
    static func installingClaude(into settings: [String: Any], command: String) -> [String: Any] {
        var settings = removingClaude(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var entries = hooks[event] as? [Any] ?? []
            entries.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Cheoma 훅만 뺀다. 비게 된 항목 · 이벤트 · hooks는 지운다. 순수 함수
    static func removingClaude(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            var kept: [Any] = []
            for entry in entries {
                guard var object = entry as? [String: Any], let list = object["hooks"] as? [Any] else {
                    kept.append(entry)
                    continue
                }
                let others = list.filter { !isCheomaHook($0) }
                if others.count == list.count {
                    kept.append(entry)
                } else if !others.isEmpty {
                    object["hooks"] = others
                    kept.append(object)
                }
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func isClaudeInstalled(settings: [String: Any]?) -> Bool {
        guard let hooks = settings?["hooks"] as? [String: Any] else { return false }
        return claudeEvents.allSatisfy { event in
            (hooks[event] as? [Any] ?? []).contains { entry in
                ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isCheomaHook)
            }
        }
    }

    private static func isCheomaHook(_ hook: Any) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        return command.contains(marker) && command.contains("Cheoma")
    }

    // MARK: - Codex

    static func installCodex(executable: String = currentExecutable,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let codexHome = AgentUsageReader.codexHome(home: home, environment: environment)
        guard FileManager.default.fileExists(atPath: codexHome.path) else {
            throw AgentBridgeError(message: "Codex 설정 폴더가 없어요. Codex를 한 번 실행한 뒤 다시 해 주세요")
        }
        let file = codexHome.appendingPathComponent("config.toml")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        switch codexStatus(config: text) {
        case .installed: return
        case .occupied(let other):
            throw AgentBridgeError(message: "Codex notify에 이미 다른 프로그램이 있어요 (\(other)). 건드리지 않았어요")
        case .notInstalled, .unavailable:
            break
        }
        try backup(file)
        try installingCodex(into: text, executable: executable).write(to: file, atomically: true, encoding: .utf8)
    }

    static func uninstallCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let file = AgentUsageReader.codexHome(home: home, environment: environment).appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8), codexStatus(config: text) == .installed else { return }
        try backup(file)
        try removingCodex(from: text).write(to: file, atomically: true, encoding: .utf8)
    }

    /// 맨 위(첫 [표] 앞) notify 줄을 보고 판단한다. 순수 함수
    static func codexStatus(config: String) -> CodexStatus {
        guard let line = topLevelNotify(in: config) else { return .notInstalled }
        let value = config.split(separator: "\n", omittingEmptySubsequences: false)[line]
            .split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if value.contains(marker) && value.contains("Cheoma") { return .installed }
        if value == "[]" || value.isEmpty { return .notInstalled }
        // 첫 인자(프로그램 경로)의 이름만 보여준다
        let program = value.split(separator: "\"").dropFirst().first.map { ($0 as NSString).lastPathComponent } ?? value
        return .occupied(program)
    }

    /// notify 줄을 맨 위에 넣는다 (빈 notify가 있으면 바꾼다). 순수 함수
    static func installingCodex(into config: String, executable: String) -> String {
        let line = "notify = [\(tomlString(executable)), \"\(marker)\", \"codex\"]"
        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = topLevelNotify(in: config) {
            lines[index] = line
        } else {
            lines.insert(line, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func removingCodex(from config: String) -> String {
        guard let index = topLevelNotify(in: config) else { return config }
        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// 첫 [표] 앞의 `notify = …` 줄 번호. 여러 줄 배열은 쓰지 않는다고 본다 (Codex가 쓰는 형식은 한 줄)
    private static func topLevelNotify(in config: String) -> Int? {
        for (index, raw) in config.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if line.hasPrefix("notify"), line.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") { return index }
        }
        return nil
    }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - 명령 · 파일

    static var currentExecutable: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    /// 셸이 실행하는 훅 명령. 앱이 지워졌으면 아무것도 하지 않는다
    static func command(executable: String, kind: AgentKind) -> String {
        let quoted = shellQuoted(executable)
        return "[ -x \(quoted) ] && \(quoted) \(marker) \(kind.rawValue) || true"
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readJSON(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 없으면 빈 설정. 있는데 읽을 수 없으면(주석 · 잘못된 JSON) 고치지 않는다
    private static func readSettings(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let settings = readJSON(file) else {
            throw AgentBridgeError(message: "\(file.path)을 읽을 수 없어서 고치지 않았어요")
        }
        return settings
    }

    private static func write(_ settings: [String: Any], to file: URL) throws {
        try backup(file)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// 처음 고칠 때만 원래 파일을 옆에 남긴다 (나중에 고쳐도 처음 상태가 남게)
    private static func backup(_ file: URL) throws {
        let copy = URL(fileURLWithPath: file.path + backupSuffix)
        guard FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: copy.path) else { return }
        try FileManager.default.copyItem(at: file, to: copy)
    }
}

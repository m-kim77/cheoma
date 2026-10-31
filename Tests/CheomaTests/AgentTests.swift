import XCTest
@testable import Cheoma

/// 실제로 모은 에이전트 화면(scripts/agent-screens)으로 화면 분석을 확인한다
final class AgentScreenParserTests: XCTestCase {
    private static let screens = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/agent-screens")

    private func analyze(_ name: String) throws -> ScreenAnalysis {
        let text = try String(contentsOf: Self.screens.appendingPathComponent("\(name).txt"), encoding: .utf8)
        let kind = AgentKind.allCases.first { name.hasPrefix("\($0.rawValue)-") } ?? .claude
        return AgentScreenParser.analyze(TerminalScreen(text: text, capturedAt: Date()), kind: kind)
    }

    func testStates() throws {
        let expected: [String: AgentState] = [
            "claude-idle": .needsInput, "claude-idle-auto": .needsInput, "claude-typed": .needsInput,
            "claude-finished": .needsInput, "claude-finished-bash": .needsInput, "claude-ctrlc-confirm": .needsInput,
            "claude-working": .working, "claude-permission-bash": .needsChoice, "claude-permission-bash-no": .needsChoice,
            "claude-permission-edit": .needsChoice, "claude-question": .needsChoice, "claude-trust": .needsChoice,
            "claude-trust-down": .needsChoice, "claude-exited": .unknown,
            "codex-idle": .needsInput, "codex-typed": .needsInput, "codex-finished": .needsInput, "codex-finished2": .needsInput,
            "codex-error": .needsInput, "codex-slash-popup": .needsInput, "codex-working": .working, "codex-working2": .working,
            "codex-working3": .working, "codex-approval": .needsChoice, "codex-approval-down": .needsChoice,
            "codex-trust": .needsChoice, "codex-trust-down": .needsChoice, "codex-update": .needsChoice,
            "codex-model-picker": .needsChoice,
            "pi-idle": .needsInput, "pi-typed": .needsInput, "pi-finished": .needsInput, "pi-error": .needsInput,
            "pi-working": .working, "pi-working2": .working, "pi-model-picker": .needsChoice,
            "opencode-idle": .needsInput, "opencode-no-provider": .needsInput,
        ]
        for (name, state) in expected {
            XCTAssertEqual(try analyze(name).state, state, name)
        }
    }

    func testClaudePermission() throws {
        let analysis = try analyze("claude-permission-bash-no")
        XCTAssertEqual(analysis.question, "Do you want to proceed?")
        XCTAssertEqual(analysis.choices.map(\.key), ["1", "2", "3", "4"])
        XCTAssertEqual(analysis.choices.first?.label, "Yes")
        XCTAssertEqual(analysis.choices.filter(\.isHighlighted).map(\.key), ["4"])
        XCTAssertFalse(analysis.choices.contains(where: \.needsEnter))
    }

    func testClaudeQuestionSkipsDescriptionsAndSeparator() throws {
        let analysis = try analyze("claude-question")
        XCTAssertEqual(analysis.question, "Tea or coffee?")
        XCTAssertEqual(analysis.choices.map(\.label), ["Tea", "Coffee", "Type something.", "Chat about this"])
    }

    func testCodexApprovalDropsShortcutHints() throws {
        let analysis = try analyze("codex-approval-down")
        XCTAssertEqual(analysis.question, "Would you like to run the following command?")
        XCTAssertEqual(analysis.choices.map(\.label).first, "Yes, proceed")
        XCTAssertEqual(analysis.choices.last?.label, "No, and tell Codex what to do differently")
        XCTAssertEqual(analysis.choices.filter(\.isHighlighted).map(\.key), ["2"])
    }

    func testUnnumberedMenusUseArrows() throws {
        let trust = try analyze("claude-trust-down")
        XCTAssertEqual(trust.choices.map(\.label), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(trust.choices.map(\.key), ["", ""])
        XCTAssertEqual(trust.choices.map(\.isHighlighted), [false, true])
        let picker = try analyze("pi-model-picker")
        XCTAssertEqual(picker.choices.count, 10)
        XCTAssertEqual(picker.choices.first?.label, "gpt-5.6-terra [openai-codex]")
    }

    func testSummaries() throws {
        XCTAssertEqual(try analyze("claude-working").summary, "Wandering… (1s · thinking with high effort)")
        XCTAssertEqual(try analyze("claude-finished").summary?.hasPrefix("I created hello.txt"), true)
        XCTAssertNil(try analyze("claude-idle").summary)
        XCTAssertEqual(try analyze("codex-finished").summary, "Created a.txt.")
        XCTAssertNil(try analyze("codex-idle").summary)
        XCTAssertEqual(try analyze("codex-update").question, "Update available! 0.147.0 -> 0.166.0")
        XCTAssertEqual(try analyze("pi-finished").summary, "Done.")
    }

    func testHistoryListIsNotAMenu() {
        let screen = """
        ⏺ Here is the plan:
          1. Read the file
          2. Fix the bug
        ────────────────────────────────────────
        ❯\u{A0}
        ────────────────────────────────────────
          ⏸ manual mode on · ? for shortcuts
        """
        let analysis = AgentScreenParser.analyze(TerminalScreen(text: screen, capturedAt: Date()), kind: .claude)
        XCTAssertEqual(analysis.state, .needsInput)
        XCTAssertTrue(analysis.choices.isEmpty)
    }

    func testYesNoQuestion() {
        let screen = "Applying edits…\nAllow creation of new file foo.py? (Y)es/(N)o [Yes]: \nAdd file to the chat? [y/N]"
        let analysis = AgentScreenParser.analyze(TerminalScreen(text: screen, capturedAt: Date()), kind: .aider)
        XCTAssertEqual(analysis.state, .needsChoice)
        XCTAssertEqual(analysis.question, "Add file to the chat?")
        XCTAssertEqual(analysis.choices.map(\.key), ["y", "n"])
        XCTAssertEqual(analysis.choices.map(\.isHighlighted), [false, true])
        XCTAssertTrue(analysis.choices.allSatisfy(\.needsEnter))
    }

    func testANSIPlainStripsColorsAndLinks() {
        let text = "\u{1B}[1;2m› \u{1B}[0mRun \u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\ now\u{A0}"
        XCTAssertEqual(ANSIText.plain(text), "› Run link now ")
        XCTAssertEqual(String(ANSIText.attributed(text).characters), "› Run link now\u{A0}")
    }

    func testParserIsFast() throws {
        let text = try String(contentsOf: Self.screens.appendingPathComponent("pi-idle.txt"), encoding: .utf8)
        let screen = TerminalScreen(text: text, capturedAt: Date())
        let start = Date()
        for _ in 0..<20 { _ = AgentScreenParser.analyze(screen, kind: .pi) }
        // 디버그 빌드 기준. 릴리스는 훨씬 빠르다
        XCTAssertLessThan(Date().timeIntervalSince(start) / 20, 0.01)
    }
}

final class AgentHookTests: XCTestCase {
    func testClaudeNotification() throws {
        let json = #"{"session_id":"abc","cwd":"/tmp/p","transcript_path":"/tmp/t.jsonl","hook_event_name":"Notification","message":"Claude needs your permission to use Bash\nmore","notification_type":"permission_prompt"}"#
        let event = try XCTUnwrap(AgentHooks.event(kind: .claude, json: Data(json.utf8), tty: "/dev/ttys004", agentPID: 42, date: Date()))
        XCTAssertEqual(event.name, "Notification")
        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.cwd, "/tmp/p")
        XCTAssertEqual(event.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.tty, "/dev/ttys004")
        XCTAssertEqual(event.agentPID, 42)
    }

    func testClaudeStopUsesLastMessage() throws {
        let json = #"{"session_id":"abc","hook_event_name":"Stop","last_assistant_message":"Done."}"#
        let event = try XCTUnwrap(AgentHooks.event(kind: .claude, json: Data(json.utf8), tty: nil, agentPID: nil, date: Date()))
        XCTAssertEqual(event.message, "Done.")
    }

    func testCodexNotify() throws {
        let json = #"{"type":"agent-turn-complete","thread-id":"t1","turn-id":"u1","cwd":"/tmp/c","input-messages":["hi"],"last-assistant-message":"Created a.txt."}"#
        let event = try XCTUnwrap(AgentHooks.event(kind: .codex, json: Data(json.utf8), tty: nil, agentPID: nil, date: Date()))
        XCTAssertEqual(event.name, "agent-turn-complete")
        XCTAssertEqual(event.sessionID, "t1")
        XCTAssertEqual(event.message, "Created a.txt.")
    }

    func testBadInput() {
        XCTAssertNil(AgentHooks.event(kind: .claude, json: Data("nope".utf8), tty: nil, agentPID: nil, date: Date()))
        XCTAssertNil(AgentHooks.event(kind: .claude, json: Data("{}".utf8), tty: nil, agentPID: nil, date: Date()))
    }

    func testRoundTripThroughNotification() throws {
        let event = AgentHookEvent(kind: .claude, name: "Stop", sessionID: "s", cwd: "/x", transcriptPath: nil, tty: "/dev/ttys001",
                                   agentPID: 7, message: "hi", notificationType: nil, date: Date(timeIntervalSince1970: 1_000))
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        let notification = Notification(name: AgentHooks.notificationName, object: nil, userInfo: ["event": text])
        XCTAssertEqual(AgentHooks.event(from: notification), event)
    }
}

final class HookInstallerTests: XCTestCase {
    private let command = HookInstaller.command(executable: "/Applications/Cheoma.app/Contents/MacOS/Cheoma", kind: .claude)

    func testCommandIsGuarded() {
        XCTAssertEqual(command, "[ -x '/Applications/Cheoma.app/Contents/MacOS/Cheoma' ] && '/Applications/Cheoma.app/Contents/MacOS/Cheoma' --agent-event claude || true")
        XCTAssertTrue(HookInstaller.command(executable: "/a b/it's/Cheoma", kind: .claude).contains("'/a b/it'\\''s/Cheoma'"))
    }

    func testInstallKeepsOtherHooksAndSettings() {
        let other: [String: Any] = ["type": "command", "command": "afplay ding.aiff"]
        let settings: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [other]]], "PreToolUse": [["matcher": "Bash", "hooks": [other]]]]]
        let installed = HookInstaller.installingClaude(into: settings, command: command)
        XCTAssertTrue(HookInstaller.isClaudeInstalled(settings: installed))
        XCTAssertEqual(installed["model"] as? String, "opus")
        let hooks = installed["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["Stop"] as! [Any]).count, 2)
        XCTAssertEqual((hooks["PreToolUse"] as! [Any]).count, 1)
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.claudeEvents + ["PreToolUse"]))

        // 다시 넣어도 두 번 들어가지 않는다
        let again = HookInstaller.installingClaude(into: installed, command: command)
        XCTAssertEqual(((again["hooks"] as! [String: Any])["Stop"] as! [Any]).count, 2)

        // 빼면 원래대로
        let removed = HookInstaller.removingClaude(from: again)
        XCTAssertFalse(HookInstaller.isClaudeInstalled(settings: removed))
        XCTAssertEqual(NSDictionary(dictionary: removed), NSDictionary(dictionary: settings))
    }

    func testRemoveDropsEmptyHooks() {
        let installed = HookInstaller.installingClaude(into: ["theme": "dark"], command: command)
        let removed = HookInstaller.removingClaude(from: installed)
        XCTAssertNil(removed["hooks"])
        XCTAssertEqual(removed["theme"] as? String, "dark")
    }

    func testCodexStatus() {
        XCTAssertEqual(HookInstaller.codexStatus(config: "model = \"o3\"\n[tui]\nnotify = [\"x\"]"), .notInstalled)
        XCTAssertEqual(HookInstaller.codexStatus(config: "notify = [\"/Apps/Sky.app/Contents/MacOS/SkyClient\", \"turn-ended\"]\n"), .occupied("SkyClient"))
        let installed = HookInstaller.installingCodex(into: "model = \"o3\"\n\n[tui]\nx = 1\n", executable: "/A/Cheoma.app/Contents/MacOS/Cheoma")
        XCTAssertTrue(installed.hasPrefix("notify = [\"/A/Cheoma.app/Contents/MacOS/Cheoma\", \"--agent-event\", \"codex\"]\nmodel"))
        XCTAssertEqual(HookInstaller.codexStatus(config: installed), .installed)
        XCTAssertEqual(HookInstaller.removingCodex(from: installed), "model = \"o3\"\n\n[tui]\nx = 1\n")
    }

    /// 임시 홈 폴더에서 실제 파일로 넣고 빼 본다 (백업도)
    func testFilesInTemporaryHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cheoma-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"}]}]}}"#
        try original.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "model = \"o3\"\n".write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let environment: [String: String] = [:]

        XCTAssertEqual(HookInstaller.status(home: home, environment: environment).claude.map(\.isInstalled), [false])
        XCTAssertEqual(HookInstaller.status(home: home, environment: environment).codex, .notInstalled)

        try HookInstaller.installClaude(configDir: claude, executable: "/X/Cheoma")
        try HookInstaller.installCodex(executable: "/X/Cheoma", home: home, environment: environment)
        let status = HookInstaller.status(home: home, environment: environment)
        XCTAssertEqual(status.claude.map(\.isInstalled), [true])
        XCTAssertEqual(status.claude.map(\.statusLine), [.installed])
        XCTAssertEqual(status.codex, .installed)
        XCTAssertEqual(try String(contentsOf: claude.appendingPathComponent("settings.json.cheoma-backup"), encoding: .utf8), original)

        try HookInstaller.uninstallClaude(configDir: claude)
        try HookInstaller.uninstallCodex(home: home, environment: environment)
        let after = HookInstaller.status(home: home, environment: environment)
        XCTAssertEqual(after.claude.map(\.isInstalled), [false])
        XCTAssertEqual(after.claude.map(\.statusLine), [.notInstalled])
        XCTAssertEqual(after.codex, .notInstalled)
        XCTAssertEqual(try String(contentsOf: codex.appendingPathComponent("config.toml"), encoding: .utf8), "model = \"o3\"\n")
    }

    func testBrokenSettingsAreLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cheoma-broken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ // comment\n}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.installClaude(configDir: dir, executable: "/X/Cheoma"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8), "{ // comment\n}")
    }
}

final class ClaudeStatusLineTests: XCTestCase {
    private let input = #"""
    {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1793431200},"seven_day":{"used_percentage":68.4,"resets_at":1793685600}}}
    """#

    func testReadsLimits() throws {
        let windows = try XCTUnwrap(ClaudeStatusLine.limits(from: Data(input.utf8)))
        XCTAssertEqual(windows.map(\.windowMinutes), [300, 10_080])
        XCTAssertEqual(windows.map(\.usedPercent), [12, 68.4])
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_793_431_200))
        XCTAssertEqual(ClaudeStatusLine.line(windows, now: Date(timeIntervalSince1970: 1_793_420_000)), "5시간 12% · 주간 68%")
        // 초기화 시각이 지났으면 0%
        XCTAssertEqual(ClaudeStatusLine.line(windows, now: Date(timeIntervalSince1970: 1_793_500_000)), "5시간 0% · 주간 68%")
    }

    func testNoLimitsBeforeFirstRequest() {
        XCTAssertNil(ClaudeStatusLine.limits(from: Data(#"{"session_id":"s","model":{"id":"x"}}"#.utf8)))
        XCTAssertNil(ClaudeStatusLine.limits(from: Data("nope".utf8)))
    }

    func testSaveAndLoad() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cheoma-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let windows = try XCTUnwrap(ClaudeStatusLine.limits(from: Data(input.utf8)))
        let date = Date(timeIntervalSince1970: 1_793_420_000)
        ClaudeStatusLine.save(windows, account: ".claude-account2", date: date, home: home)
        let loaded = try XCTUnwrap(ClaudeStatusLine.load(account: ".claude-account2", home: home))
        XCTAssertEqual(loaded.windows, windows)
        XCTAssertEqual(loaded.updatedAt, date)
        XCTAssertNil(ClaudeStatusLine.load(account: ".claude", home: home))
    }

    func testLiveSessionFile() throws {
        let json = #"{"pid":30114,"sessionId":"d4eab328","cwd":"/x","status":"waiting","statusUpdatedAt":1793427614159}"#
        let live = try XCTUnwrap(ClaudeStatusLine.liveSession(json: Data(json.utf8), account: ".claude"))
        XCTAssertEqual(live.sessionID, "d4eab328")
        XCTAssertEqual(live.status, "waiting")
        XCTAssertEqual(live.statusSince, Date(timeIntervalSince1970: 1_793_427_614.159))
        XCTAssertNil(ClaudeStatusLine.liveSession(json: Data("{}".utf8), account: ".claude"))
    }

    func testStatusLineInstallLeavesOtherStatusLineAlone() {
        let command = HookInstaller.statusLineCommand(executable: "/A/Cheoma", configDir: URL(fileURLWithPath: "/Users/me/.claude-account2"))
        XCTAssertEqual(command, "[ -x '/A/Cheoma' ] && '/A/Cheoma' --agent-statusline '/Users/me/.claude-account2' || true")
        let installed = HookInstaller.installingStatusLine(into: ["model": "opus"], command: command)
        XCTAssertEqual(HookInstaller.statusLineState(settings: installed), .installed)
        XCTAssertNil(HookInstaller.removingStatusLine(from: installed)["statusLine"])

        let other: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/my-line.sh"]]
        XCTAssertEqual(HookInstaller.statusLineState(settings: other), .occupied("~/bin/my-line.sh"))
        let kept = HookInstaller.installingStatusLine(into: other, command: command)
        XCTAssertEqual((kept["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/my-line.sh")
        XCTAssertEqual((HookInstaller.removingStatusLine(from: other)["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/my-line.sh")
        // 다른 상태 줄이 있어도 훅만 들어가면 연결된 것으로 친다
        let target = HookInstaller.ClaudeTarget(configDir: URL(fileURLWithPath: "/x"), hooks: true, statusLine: .occupied("x"))
        XCTAssertTrue(target.isInstalled)
    }
}

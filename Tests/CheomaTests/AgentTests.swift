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
        return AgentScreenParser.analyze(TerminalScreen(text: text), kind: kind)
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
            "hermes-idle": .needsInput, "hermes-typed": .needsInput, "hermes-rate-limited": .needsInput,
            "hermes-working": .working, "hermes-working2": .working, "hermes-telemetry": .needsChoice,
            "antigravity-idle": .needsInput, "antigravity-typed": .needsInput, "antigravity-finished": .needsInput,
            "antigravity-working": .working, "antigravity-permission": .needsChoice, "antigravity-trust": .needsChoice,
            "antigravity-trust-down": .needsChoice,
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

    func testHermesTelemetryMenuBelowHint() throws {
        let analysis = try analyze("hermes-telemetry")
        XCTAssertEqual(analysis.question, "Help improve Hermes?")
        XCTAssertEqual(analysis.choices.map(\.label), ["Collect and send to Nous", "Collect locally only", "No thanks"])
        XCTAssertEqual(analysis.choices.filter(\.isHighlighted).map(\.label), ["No thanks"])
        XCTAssertEqual(try analyze("hermes-working2").summary, "(¬‿¬) brainstorming...")
        XCTAssertTrue(try analyze("hermes-rate-limited").summary?.hasPrefix("ChatGPT or Codex Subscription rate-limited") ?? false)
    }

    func testAntigravityScreens() throws {
        let trust = try analyze("antigravity-trust-down")
        XCTAssertEqual(trust.question, "Do you trust the contents of this project?")
        XCTAssertEqual(trust.choices.map(\.label), ["Yes, I trust this folder", "No, exit"])
        XCTAssertEqual(trust.choices.filter(\.isHighlighted).map(\.label), ["No, exit"])
        let permission = try analyze("antigravity-permission")
        XCTAssertEqual(permission.question, "Allow creation of this file?")
        XCTAssertEqual(permission.choices.map(\.key), ["1", "2"])
        XCTAssertEqual(try analyze("antigravity-finished").summary, "done.")
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
        let analysis = AgentScreenParser.analyze(TerminalScreen(text: screen), kind: .claude)
        XCTAssertEqual(analysis.state, .needsInput)
        XCTAssertTrue(analysis.choices.isEmpty)
    }

    func testYesNoQuestion() {
        let screen = "Applying edits…\nAllow creation of new file foo.py? (Y)es/(N)o [Yes]: \nAdd file to the chat? [y/N]"
        let analysis = AgentScreenParser.analyze(TerminalScreen(text: screen), kind: .aider)
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
        let screen = TerminalScreen(text: text)
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

/// 계정 파일 읽기 (.claude.json, ~/.codex/auth.json)
final class AgentAccountsTests: XCTestCase {
    func testClaudeAccountAndCachedLimits() throws {
        let json = """
        {"oauthAccount": {"emailAddress": "a@example.com", "displayName": "A", "organizationType": "claude_max",
          "organizationRateLimitTier": "default_claude_max_20x", "planDisplayName": ""},
         "cachedUsageUtilization": {"fetchedAtMs": 1793419990486, "utilization": {
           "five_hour": {"utilization": 10, "resets_at": "2026-10-31T07:19:59.651958+00:00"},
           "seven_day": {"utilization": 67, "resets_at": "2026-11-05T07:59:00+00:00"},
           "seven_day_opus": null}}}
        """
        let account = try XCTUnwrap(AgentAccounts.claude(json: Data(json.utf8)))
        XCTAssertEqual(account.email, "a@example.com")
        XCTAssertEqual(account.plan, "Max 20x")
        XCTAssertEqual(account.limits.map(\.usedPercent), [10, 67])
        XCTAssertEqual(account.limits.map(\.windowMinutes), [300, 10_080])
        XCTAssertEqual(account.limits.first?.resetsAt, AgentAccounts.date("2026-10-31T07:19:59Z"))
        XCTAssertEqual(account.limitsFetchedAt?.timeIntervalSince1970 ?? 0, 1_793_419_990.486, accuracy: 0.001)
    }

    func testPlanNameAndMissingLogin() {
        XCTAssertEqual(AgentAccounts.planName(["planDisplayName": "Ultra"]), "Ultra")
        XCTAssertEqual(AgentAccounts.planName(["organizationType": "claude_pro"]), "Pro")
        XCTAssertNil(AgentAccounts.claude(json: Data(#"{"pluginUsage": {}}"#.utf8)))
    }

    func testDefaultFolderUsesHomeFile() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(AgentAccounts.claudeFile(configDir: home.appendingPathComponent(".claude"), home: home).path, "/Users/me/.claude.json")
        XCTAssertEqual(AgentAccounts.claudeFile(configDir: home.appendingPathComponent(".claude-work"), home: home).path,
                       "/Users/me/.claude-work/.claude.json")
    }

    func testCodexLoginFromIDToken() throws {
        let claims = #"{"email":"c@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"x.\#(payload).y"}}"#
        let account = try XCTUnwrap(AgentAccounts.codex(authJSON: Data(auth.utf8)))
        XCTAssertEqual(account, AgentAccounts.Codex(mode: "chatgpt", email: "c@example.com", plan: "plus"))
    }
}

/// 이어서 하기 · 다른 계정으로 옮기기
final class AgentResumeTests: XCTestCase {
    func testCommands() {
        let home = "/Users/me"
        let target = AgentResume.Target(kind: .claude, sessionID: "abc", cwd: "/tmp", configDir: nil)
        XCTAssertEqual(AgentResume.resumeCommand(target, configDir: "/Users/me/.claude", home: home), "claude --resume 'abc'")
        XCTAssertEqual(AgentResume.resumeCommand(target, configDir: "/Users/me/.claude-work", home: home),
                       "CLAUDE_CONFIG_DIR='/Users/me/.claude-work' claude --resume 'abc'")
        XCTAssertEqual(AgentResume.launchCommand(.codex, configDir: nil, home: home), "codex")
        XCTAssertEqual(AgentResume.launchCommand(.codex, configDir: "/Users/me/.codex", home: home), "codex")
        XCTAssertEqual(AgentResume.launchCommand(.codex, configDir: "/Users/me/.codex-work", home: home), "CODEX_HOME='/Users/me/.codex-work' codex")
        let codexWork = AgentResume.Target(kind: .codex, sessionID: "019b", cwd: "/tmp", configDir: "/Users/me/.codex-work")
        XCTAssertEqual(AgentResume.resumeCommand(codexWork, configDir: nil, home: home), "CODEX_HOME='/Users/me/.codex-work' codex resume '019b'")
        let codex = AgentResume.Target(kind: .codex, sessionID: "019a", cwd: "/tmp", configDir: nil)
        XCTAssertEqual(AgentResume.resumeCommand(codex, configDir: nil, home: home), "codex resume '019a'")
    }

    func testPrepareCopiesNewestTranscriptToOtherAccount() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cheoma-resume-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let a = root.appendingPathComponent(".claude"), b = root.appendingPathComponent(".claude-work")
        let project = "-Users-me-app"
        let sourceFolder = a.appendingPathComponent("projects/\(project)")
        try manager.createDirectory(at: sourceFolder.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try Data("new\n".utf8).write(to: sourceFolder.appendingPathComponent("s1.jsonl"))
        try Data("sub\n".utf8).write(to: sourceFolder.appendingPathComponent("s1/subagents/x.jsonl"))
        // 다른 계정에 더 오래된 기록이 있었다
        let old = b.appendingPathComponent("projects/\(project)/s1.jsonl")
        try manager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: old)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)

        let target = AgentResume.Target(kind: .claude, sessionID: "s1", cwd: "/Users/me/app", configDir: a.path)
        try AgentResume.prepare(target, for: b.path, among: [a.path, b.path])
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "new\n")
        XCTAssertEqual(try String(contentsOf: old.appendingPathExtension("cheoma-backup"), encoding: .utf8), "old\n")
        XCTAssertTrue(manager.fileExists(atPath: b.appendingPathComponent("projects/\(project)/s1/subagents/x.jsonl").path))
        // 원래 계정의 기록은 그대로
        XCTAssertEqual(try String(contentsOf: sourceFolder.appendingPathComponent("s1.jsonl"), encoding: .utf8), "new\n")

        // 이번엔 b가 가장 새것: a로 돌아갈 때 b의 것을 쓰고, b로 다시 이으면 아무것도 안 한다
        try Data("newer\n".utf8).write(to: old)
        try AgentResume.prepare(target, for: b.path, among: [a.path, b.path])
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "newer\n")
        try AgentResume.prepare(target, for: a.path, among: [a.path, b.path])
        XCTAssertEqual(try String(contentsOf: sourceFolder.appendingPathComponent("s1.jsonl"), encoding: .utf8), "newer\n")

        let missing = AgentResume.Target(kind: .claude, sessionID: "nope", cwd: "/tmp", configDir: a.path)
        XCTAssertThrowsError(try AgentResume.prepare(missing, for: b.path, among: [a.path, b.path]))
    }

    func testPrepareCopiesCodexRolloutToOtherAccount() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cheoma-codex-resume-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let a = root.appendingPathComponent(".codex"), b = root.appendingPathComponent(".codex-work")
        let name = "2026/11/02/rollout-2026-11-02T00-52-50-01a1.jsonl"
        let source = a.appendingPathComponent("sessions/\(name)")
        try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("chat\n".utf8).write(to: source)

        let target = AgentResume.Target(kind: .codex, sessionID: "01a1", cwd: "/Users/me/app", configDir: a.path)
        XCTAssertEqual(AgentResume.codexRollouts(sessionID: "01a1", codexHome: a.path).count, 1)
        try AgentResume.prepare(target, for: b.path, among: [a.path, b.path])
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("sessions/\(name)"), encoding: .utf8), "chat\n")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "chat\n")

        let missing = AgentResume.Target(kind: .codex, sessionID: "nope", cwd: "/tmp", configDir: a.path)
        XCTAssertThrowsError(try AgentResume.prepare(missing, for: b.path, among: [a.path, b.path]))
    }
}

/// 에이전트 탭 크기 제한
final class AgentsSizeTests: XCTestCase {
    func testClampToDefaultAndScreen() {
        let minimum = NotchModel.compactAgentsSize
        let screen = CGSize(width: 1512, height: 982)
        XCTAssertEqual(NotchModel.clampAgents(CGSize(width: 100, height: 100), screen: screen, theme: .basic), minimum)
        let big = NotchModel.clampAgents(CGSize(width: 5_000, height: 5_000), screen: screen, theme: .basic)
        XCTAssertEqual(big, CGSize(width: 1352, height: 862))
        let gate = NotchModel.clampAgents(CGSize(width: 5_000, height: 5_000), screen: screen, theme: .gwanghwamun)
        XCTAssertLessThan(gate.height, big.height)
        XCTAssertLessThanOrEqual(Gwanghwamun.frameSize(content: gate).width, screen.width - 160)
    }
    func testTextScaleRaisesMinimum() {
        let screen = CGSize(width: 1512, height: 982)
        let minimum = NotchModel.agentsMinimumSize(scale: 1.3)
        XCTAssertEqual(minimum, CGSize(width: 884, height: 403))
        XCTAssertEqual(NotchModel.clampAgents(CGSize(width: 680, height: 310), minimum: minimum, screen: screen, theme: .basic), minimum)
        XCTAssertEqual(AgentsTextScale.larger.percent, "130%")
        XCTAssertEqual(AgentsTextScale.allCases.map(\.rawValue), AgentsTextScale.allCases.map(\.rawValue).sorted())
    }
    /// 글자를 키웠다 줄이면 탭도 원래 크기로 돌아온다 (예전에는 줄여도 커진 크기가 남아 계속 커졌다)
    func testTextScaleUpThenDownRestoresSize() {
        let screen = CGSize(width: 1512, height: 982)
        let base = CGSize(width: 900, height: 500)
        XCTAssertEqual(NotchModel.agentsSize(base: base, scale: 1, screen: screen, theme: .basic), base)
        XCTAssertEqual(NotchModel.agentsSize(base: base, scale: 1.5, screen: screen, theme: .basic), CGSize(width: 1350, height: 750))
        XCTAssertEqual(NotchModel.agentsSize(base: base, scale: 1, screen: screen, theme: .basic), base)
        // 화면에 막혀 덜 커졌어도 기준 크기는 그대로라 줄이면 원래 크기
        let wide = CGSize(width: 1300, height: 700)
        XCTAssertEqual(NotchModel.agentsSize(base: wide, scale: 1.5, screen: screen, theme: .basic), CGSize(width: 1352, height: 862))
        XCTAssertEqual(NotchModel.agentsSize(base: wide, scale: 1, screen: screen, theme: .basic), wide)
        // 기본 크기 그대로면 배율만큼만
        XCTAssertEqual(NotchModel.agentsSize(base: DashboardTab.agents.openSize, scale: 1.3, screen: screen, theme: .basic),
                       CGSize(width: 988, height: 525))
    }
}

/// 로컬 모델 서버 응답 읽기 (Ollama /api/ps, LM Studio /api/v0/models, llama-server 인자)
final class LocalModelTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testOllamaRunningModel() throws {
        let item = try json("""
        {"name":"qwen3:8b","model":"qwen3:8b","size":6200000000,"size_vram":6200000000,
         "details":{"parameter_size":"8.2B","quantization_level":"Q4_K_M"},
         "expires_at":"2026-11-02T02:10:00.123456789+09:00","context_length":40960}
        """)
        let model = LocalModelReader.ollamaModel(item)
        XCTAssertEqual(model.name, "qwen3:8b")
        XCTAssertEqual(model.memoryBytes, 6_200_000_000)
        XCTAssertEqual(model.detail, "8.2B · Q4_K_M")
        XCTAssertEqual(model.contextLength, 40_960)
        XCTAssertEqual(model.expiresAt.map { Int($0.timeIntervalSince1970) }, 1_793_553_000)
    }

    func testLMStudioLoadedModel() throws {
        let item = try json("""
        {"id":"qwen3-8b","type":"llm","arch":"qwen3","quantization":"Q4_K_M","state":"loaded",
         "max_context_length":40960,"loaded_context_length":8192}
        """)
        let model = LocalModelReader.lmStudioModel(item)
        XCTAssertEqual(model.name, "qwen3-8b")
        XCTAssertEqual(model.detail, "qwen3 · Q4_K_M")
        XCTAssertEqual(model.contextLength, 8_192)
    }

    func testLlamaServerArguments() {
        let plain = LocalModelReader.llamaServerArguments(["llama-server", "-m", "/m/Qwen3-8B-Q4_K_M.gguf", "--port", "8099", "-c", "8192"])
        XCTAssertEqual(plain.model.map(LocalModelReader.modelName), "Qwen3-8B-Q4_K_M")
        XCTAssertEqual(plain.port, 8099)
        let alias = LocalModelReader.llamaServerArguments(["llama-server", "--model", "/m/x.gguf", "--alias", "gemma-4-12B"])
        XCTAssertEqual(alias.model, "gemma-4-12B")
        XCTAssertEqual(alias.port, 8080)
    }
}

/// agy -p /usage --output-format json 읽기 (agy 1.4.12에서 받은 모양)
final class AntigravityQuotaTests: XCTestCase {
    func testParseUsage() throws {
        let json = """
        {"conversation_id":"","status":"SUCCESS","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9869831800460815,"reset_time":"2026-11-08T16:40:04Z"}]},
          {"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-08T16:50:27Z"}]}]}}}
        """
        let groups = try XCTUnwrap(AntigravityQuota.parse(Data(json.utf8)))
        XCTAssertEqual(groups.map(\.name), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(groups[0].windows.first?.windowMinutes, 10_080)
        XCTAssertEqual(groups[0].windows.first?.usedPercent ?? 0, 1.3, accuracy: 0.01)
        XCTAssertEqual(groups[1].windows.first?.usedPercent, 0)
        XCTAssertEqual(groups[0].windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-08T16:40:04Z"))
        XCTAssertEqual(groups.map { AntigravityQuota.shortName($0.name) }, ["Gemini", "Claude · GPT"])
        XCTAssertNil(AntigravityQuota.parse(Data("error: not logged in".utf8)))
    }

    func testConversationRecordFields() throws {
        XCTAssertEqual(AntigravityRecords.workspace("[\"file:///Users/me/My%20App\"]"), "/Users/me/My App")
        XCTAssertNil(AntigravityRecords.workspace("[]"))
        XCTAssertEqual(AntigravityRecords.parseDate("2026-11-02 02:35:03.772847+00:00").map { Int($0.timeIntervalSince1970) }, 1_793_586_903)
        XCTAssertNil(AntigravityRecords.parseDate("0001-01-01 00:00:00+00:00"))
        let target = AgentResume.Target(kind: .antigravity, sessionID: "220f0db8", cwd: "/tmp", configDir: nil)
        XCTAssertEqual(AgentResume.resumeCommand(target, configDir: nil), "agy --conversation '220f0db8'")
    }
}

/// 계정 추가: 다음 번호, alias 한 줄 덧붙이기
final class AccountSetupTests: XCTestCase {
    func testPlanAndPrepare() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("cheoma-accounts-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: home) }
        try manager.createDirectory(at: home.appendingPathComponent(".claude-account2"), withIntermediateDirectories: true)
        try "export A=1\nalias claude2='CLAUDE_CONFIG_DIR=~/.claude-account2 claude'".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let claude = try XCTUnwrap(AccountSetup.plan(.claude, home: home, shell: "/bin/zsh"))
        XCTAssertEqual(claude.number, 3)
        XCTAssertEqual(claude.aliasName, "claude3")
        XCTAssertEqual(claude.aliasLine, "alias claude3='CLAUDE_CONFIG_DIR=\"$HOME/.claude-account3\" claude'")
        XCTAssertFalse(claude.aliasExists)
        XCTAssertTrue(claude.loginCommand.hasPrefix("CLAUDE_CONFIG_DIR='"))
        try AccountSetup.prepare(claude)
        XCTAssertTrue(manager.fileExists(atPath: home.appendingPathComponent(".claude-account3").path))
        let rc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(rc.hasPrefix("export A=1\nalias claude2="))
        XCTAssertTrue(rc.hasSuffix("\n\n# Cheoma: Claude Code 계정 account3\nalias claude3='CLAUDE_CONFIG_DIR=\"$HOME/.claude-account3\" claude'\n"))

        // 다음은 4, Codex는 처음이라 2, bash는 .bashrc
        XCTAssertEqual(AccountSetup.plan(.claude, home: home)?.number, 4)
        let codex = try XCTUnwrap(AccountSetup.plan(.codex, home: home, shell: "/bin/bash"))
        XCTAssertEqual(codex.number, 2)
        XCTAssertEqual(codex.shellFile.lastPathComponent, ".bashrc")
        XCTAssertTrue(codex.loginCommand.hasSuffix("codex login"))
        XCTAssertNil(AccountSetup.plan(.antigravity, home: home))
    }
}

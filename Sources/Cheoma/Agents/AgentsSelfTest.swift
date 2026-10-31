import Foundation

/// `Cheoma --agents --selftest`: 프로세스 찾기 · Terminal 스크립트 · tmux 연동을 확인한다 (개발용).
/// Terminal에는 Apple Event를 보내지 않는다: 스크립트 만들기와 결과 읽기만 글자로 확인하고,
/// osascript는 앱을 부르지 않는 순수 AppleScript로만 돌린다.
/// tmux는 따로 띄운 테스트 서버(-S 소켓)에서 진짜로 돌려 보고 끝나면 서버째 지운다. 사용자의 tmux 서버는 건드리지 않는다
enum AgentsSelfTest {
    nonisolated(unsafe) private static var failures = 0

    static func run() -> Bool {
        failures = 0
        scannerRules()
        terminalScripts()
        osascriptOutput()
        tmuxPureFunctions()
        tmuxLive()
        scanNow()
        print(failures == 0 ? "\n모두 통과" : "\n실패 \(failures)개")
        return failures == 0
    }

    private static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ok   \(name)")
        } else {
            failures += 1
            let extra = detail()
            print("  FAIL \(name)" + (extra.isEmpty ? "" : "\n       \(extra)"))
        }
    }

    // MARK: - 프로세스 종류

    private static func scannerRules() {
        print("프로세스 종류")
        let cases: [(String, [String], AgentKind?)] = [
            ("/Users/me/.local/share/claude/versions/2.1.314", ["claude"], .claude),
            ("/Users/me/.local/share/claude/versions/2.1.314", ["claude", "--resume"], .claude),
            // Claude Code가 자기 실행 파일을 rg로 다시 띄우는 경우: 경로로는 claude지만 맨 위만 남기므로 상관없다
            ("/opt/homebrew/bin/claude", ["claude"], .claude),
            ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], .claude),
            ("/Applications/Claude.app/Contents/MacOS/Claude", ["/Applications/Claude.app/Contents/MacOS/Claude"], nil),
            ("/Applications/Claude.app/Contents/Resources/claude", ["claude"], nil),
            ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/codex"], .codex),
            ("/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex",
             ["codex"], .codex),
            ("/Users/me/.vscode/extensions/openai.chatgpt-26.1021.22027-darwin-arm64/bin/macos-aarch64/codex",
             ["codex", "app-server"], .codex),
            ("/opt/homebrew/Cellar/opencode/2.1.0/bin/opencode", ["opencode"], .opencode),
            ("/opt/homebrew/Cellar/node/24.1.0/bin/node",
             ["/opt/homebrew/opt/node/bin/node", "/opt/homebrew/Cellar/pi-coding-agent/1.3.0/libexec/bin/pi"], .pi),
            // pi는 process.title을 "pi"로 바꿔서 인자가 덮인다
            ("/opt/homebrew/Cellar/node/25.2.1/bin/node", ["pi"], .pi),
            ("/opt/homebrew/bin/node", ["node", "--no-warnings", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"], .gemini),
            ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/gemini"], .gemini),
            ("/Users/me/.local/share/uv/tools/aider-chat/bin/python3.12", ["python3", "/Users/me/.local/bin/aider"], .aider),
            ("/usr/bin/python3", ["python3", "-m", "aider", "--model", "x"], .aider),
            ("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
             ["python3", "/usr/local/bin/aider"], .aider),
            // 에이전트가 아닌 것
            ("/opt/homebrew/bin/node", ["node", "/Users/me/app/server.js", "--root", "/Users/me/claude"], nil),
            ("/opt/homebrew/bin/node", ["node"], nil),
            ("/usr/bin/python3", ["python3", "/usr/local/bin/codex"], nil),
            ("/bin/zsh", ["-zsh"], nil),
            ("/Users/me/.local/share/claude/versions/2.1.314", ["rg", "--files"], .claude),
            ("/usr/local/bin/2.0", ["something"], nil),
        ]
        for (path, arguments, expected) in cases {
            let kind = AgentScanner.kind(executablePath: path, arguments: arguments)
            check(kind == expected, "\((path as NSString).lastPathComponent) \(arguments.dropFirst().first ?? "") → \(expected?.rawValue ?? "nil")",
                  "got \(kind?.rawValue ?? "nil")")
        }
        let hosts: [(String, String?)] = [
            ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "Terminal"),
            ("/opt/homebrew/Cellar/tmux/3.8/bin/tmux", "tmux"),
            ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", "VS Code"),
            ("/Applications/Cursor.app/Contents/MacOS/Cursor", "Cursor"),
            ("/Applications/iTerm.app/Contents/MacOS/iTerm2", "iTerm2"),
            ("/Applications/Ghostty.app/Contents/MacOS/ghostty", "Ghostty"),
            ("/Applications/WezTerm.app/Contents/MacOS/wezterm-gui", "WezTerm"),
            ("/Applications/Warp.app/Contents/MacOS/stable", "Warp"),
            ("/bin/zsh", nil),
            ("/usr/bin/login", nil),
        ]
        for (path, expected) in hosts {
            let name = AgentScanner.hostName(executablePath: path)
            check(name == expected, "host \((path as NSString).lastPathComponent) → \(expected ?? "nil")", "got \(name ?? "nil")")
        }
    }

    // MARK: - Terminal 스크립트 (글자로만)

    private static func terminalScripts() {
        print("\nTerminal 스크립트")
        check(TerminalAppScript.escaped(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#, "AppleScript 이스케이프")
        check(TerminalAppScript.singleLine("a\nb\r\nc\rd") == "a b c d", "여러 줄 → 한 줄")
        check(TerminalAppScript.shellCommand("claude", in: "/Users/me/it's here") == #"cd '/Users/me/it'\''s here' && claude"#,
              "폴더 작은따옴표", TerminalAppScript.shellCommand("claude", in: "/Users/me/it's here"))
        check(TerminalAppScript.shellCommand("claude", in: nil) == "claude", "폴더 없음")

        let send = TerminalAppScript.send(text: "fix \"this\"\nnow \\ ok", tty: "/dev/ttys004")
        check(send.contains(#"do script "fix \"this\" now \\ ok" in tab i of w"#), "do script 글자", send)
        check(send.contains(#"set targetTTY to "/dev/ttys004""#), "tty 비교")
        check(send.hasPrefix(#"if application id "com.apple.Terminal" is not running then return "CHEOMA_NOT_RUNNING""#),
              "꺼져 있으면 켜지 않음")
        for (name, script) in [("tabs", TerminalAppScript.tabs()), ("capture", TerminalAppScript.capture(tty: "/dev/ttys001")),
                               ("send", send), ("reveal", TerminalAppScript.reveal(tty: "/dev/ttys001")),
                               ("open", TerminalAppScript.openWindow(command: "cd '/tmp' && ls"))] {
            check(balanced(script), "\(name): tell/repeat/if/try 짝", script)
        }

        let sample = "12\u{1F}1\u{1F}/dev/ttys004\u{1F}true\u{1F}\u{1F}login\u{1D}-zsh\u{1D}claude\u{1E}"
            + "12\u{1F}2\u{1F}/dev/ttys005\u{1F}false\u{1F}빌드 창\u{1F}login\u{1D}-zsh\u{1E}"
            + "40\u{1F}1\u{1F}\u{1F}false\u{1F}\u{1F}\u{1E}"
        let tabs = TerminalAppScript.parseTabs(sample)
        check(tabs == [
            TerminalAppTab(tty: "/dev/ttys004", windowID: 12, tabIndex: 1, title: nil, isBusy: true, processes: ["login", "-zsh", "claude"]),
            TerminalAppTab(tty: "/dev/ttys005", windowID: 12, tabIndex: 2, title: "빌드 창", isBusy: false, processes: ["login", "-zsh"]),
        ], "탭 목록 읽기 (tty 없는 탭은 뺀다)", "\(tabs)")

        check((try? TerminalAppScript.checkSentinel("CHEOMA_OK:hello")) == "hello", "OK 표시 떼기")
        check(thrownMessage { try TerminalAppScript.checkSentinel("CHEOMA_NO_TAB") } == TerminalAppScript.Message.tabMissing, "탭 없음")
        check(thrownMessage { try TerminalAppScript.checkSentinel("CHEOMA_NOT_RUNNING") } == TerminalAppScript.Message.notRunning, "꺼짐")
        let denied = "36:120: execution error: Not authorized to send Apple events to Terminal. (-1743)\n"
        check(TerminalAppScript.errorCode(in: denied) == -1743, "오류 번호 읽기")
        check(TerminalAppScript.message(forError: denied) == TerminalAppScript.Message.denied, "권한 없음 메시지")
        check(TerminalAppScript.message(forError: "execution error: Terminal got an error: AppleEvent timed out. (-1712)")
              == TerminalAppScript.Message.timeout, "응답 없음 메시지")
        check(TerminalAppScript.screenText("a\r\nb   \n\n  \n\n") == "a\nb   ", "화면 끝 빈 줄 지우기")
    }

    /// 블록 여는 줄과 닫는 줄 수가 맞는지 (한 줄짜리 `if … then …`은 블록이 아니다)
    private static func balanced(_ script: String) -> Bool {
        var stack: [String] = []
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("end ") || line == "end" {
                guard let open = stack.popLast(), line == "end \(open)" else { return false }
            } else if line.hasPrefix("tell ") && !line.contains(" to ") {
                stack.append("tell")
            } else if line.hasPrefix("repeat") {
                stack.append("repeat")
            } else if line.hasPrefix("if ") && line.hasSuffix(" then") {
                stack.append("if")
            } else if line == "try" {
                stack.append("try")
            }
        }
        return stack.isEmpty
    }

    private static func thrownMessage(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return error.localizedDescription }
    }

    /// osascript가 문자열 결과를 그대로(제어 문자 · 한글 포함) 내보내는지, 이스케이프가 맞는지. 앱을 부르지 않는다
    private static func osascriptOutput() {
        print("\nosascript (앱 없이)")
        let tricky = #"say "안녕" \ C:\path 'quoted'"#
        let script = """
        set us to character id 31
        set rs to character id 30
        return "\(TerminalAppScript.okMark)" & "\(TerminalAppScript.escaped(tricky))" & us & "b" & rs
        """
        guard let result = try? AgentCommandRunner.run("/usr/bin/osascript", [], input: script, timeout: 5) else {
            check(false, "osascript 실행")
            return
        }
        var output = result.output
        if output.hasSuffix("\n") { output.removeLast() }
        check(result.status == 0 && output == "\(TerminalAppScript.okMark)\(tricky)\u{1F}b\u{1E}", "결과 글자 그대로",
              "status \(result.status) out \(output.debugDescription) err \(result.error)")
        let failing = try? AgentCommandRunner.run("/usr/bin/osascript", [], input: "error \"boom\" number -1743", timeout: 5)
        check(failing.map { TerminalAppScript.errorCode(in: $0.error) == -1743 } ?? false, "오류 번호가 stderr 끝에 온다",
              failing?.error ?? "")
    }

    // MARK: - tmux

    private static func tmuxPureFunctions() {
        print("\ntmux 순수 함수")
        let s = TmuxBridge.separator
        let panes = TmuxBridge.parsePanes(
            ["%0", "work", "work:0.0", "/dev/ttys010", "123", "claude", "/Users/me/a b"].joined(separator: s) + "\n"
                + ["%4", "cheoma-codex-1", "cheoma-codex-1:0.0", "/dev/ttys011", "456", "zsh", "/tmp"].joined(separator: s) + "\n",
            clients: "/dev/ttys004\(s)work\n/dev/ttys006\(s)work\n")
        check(panes.count == 2 && panes[0].clientTTYs == ["/dev/ttys004", "/dev/ttys006"] && panes[0].currentPath == "/Users/me/a b"
              && panes[1].clientTTYs.isEmpty && panes[1].pid == 456, "패널 · 클라이언트 읽기", "\(panes)")
        check(TmuxBridge.keyName(.ctrlC) == "C-c" && TmuxBridge.keyName(.backspace) == "BSpace" && TmuxBridge.keyName(.escape) == "Escape",
              "특수 키 이름")
        check(TmuxBridge.shellScript(shell: "/bin/zsh", command: "claude")
              == "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; claude; exec '/bin/zsh' -l", "zsh 실행 글",
              TmuxBridge.shellScript(shell: "/bin/zsh", command: "claude"))
        check(TmuxBridge.shellScript(shell: "/opt/homebrew/bin/fish", command: "codex").hasPrefix("set -e CLAUDECODE; set -e CLAUDE_CODE_ENTRYPOINT; codex;"),
              "fish 실행 글")
        check(TmuxBridge.shellScript(shell: "/opt/homebrew/bin/nu", command: "pi").hasPrefix("env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT pi;"),
              "모르는 셸은 env -u")
        check(TmuxBridge.attachCommand(executable: "/opt/homebrew/bin/tmux", socketPath: nil, session: "cheoma-claude-1")
              == "'/opt/homebrew/bin/tmux' attach -t 'cheoma-claude-1'", "attach 명령")
        check(TmuxBridge.isNoServer("no server running on /private/tmp/tmux-501/default")
              && TmuxBridge.isNoServer("error connecting to /private/tmp/tmux-501/default (No such file or directory)"), "서버 없음 알아보기")
        check(TmuxBridge.message(forError: "can't find pane: %99") == TmuxBridge.Message.paneMissing, "패널 없음 메시지")
    }

    private static func tmuxLive() {
        print("\ntmux 실제 (테스트 서버)")
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("cheoma-selftest-\(getpid()).sock").path
        let tmux = TmuxBridge(socketPath: socket)
        guard tmux.executable != nil else {
            print("  tmux가 없어서 건너뜀")
            return
        }
        defer {
            _ = try? tmux.run(["kill-server"])
            try? FileManager.default.removeItem(atPath: socket)
        }
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        let folder = FileManager.default.temporaryDirectory.path

        check((try? tmux.panes()) == [], "서버가 없으면 빈 목록")

        // 1) 해 없는 명령으로 launch: 로그인 셸 · 폴더 · 크기 · CLAUDECODE 지우기 · 끝나면 셸이 남는지
        let command = #"printf '\033[31mred\033[0m\n'; echo "CC=${CLAUDECODE:-none} EP=${CLAUDE_CODE_ENTRYPOINT:-none}"; echo "PWD=$PWD"; echo launched-ok"#
        let launched: TerminalLocation
        do {
            launched = try tmux.launch(command: command, namePrefix: "cheoma-test-\(tag)", in: folder)
        } catch {
            check(false, "launch", error.localizedDescription)
            return
        }
        guard case .tmux(let paneID, let tty) = launched else { check(false, "launch 위치"); return }
        check(paneID.hasPrefix("%") && tty.hasPrefix("/dev/ttys"), "launch → \(paneID) \(tty)")
        let second = try? tmux.launch(command: "sleep 30", namePrefix: "cheoma-test-\(tag)", in: folder)

        let panes = (try? tmux.panes()) ?? []
        let pane = panes.first { $0.paneID == paneID }
        check(pane?.sessionName == "cheoma-test-\(tag)-1" && pane?.tty == tty, "panes()에 보임",
              panes.map { "\($0.paneID) \($0.sessionName) \($0.tty) \($0.currentCommand)" }.joined(separator: " | "))
        check(panes.contains { $0.sessionName == "cheoma-test-\(tag)-2" }, "이름 번호 늘리기 (-2)")
        let size = (try? tmux.run(["display-message", "-p", "-t", paneID, "#{pane_width}x#{pane_height}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check(size == "160x48", "크기 160x48", size ?? "")

        let screen = waitForScreen(tmux, launched) { $0.contains("launched-ok") }
        print("       화면: \(ANSIText.plain(screen).split(separator: "\n").suffix(5).joined(separator: " ⏎ "))")
        check(screen.contains("\u{1B}[31mred"), "색 코드 그대로 (-e)", screen.debugDescription)
        check(screen.contains("CC=none EP=none"), "CLAUDECODE · CLAUDE_CODE_ENTRYPOINT 지움")
        check(screen.contains("PWD=\(folder)") || screen.contains("PWD=/private\(folder)"), "시작 폴더")
        check(!screen.hasSuffix("\n"), "끝 빈 줄 지움")

        // 2) 글자 보내기 · Enter · 특수 키 (에이전트가 끝난 뒤 남은 로그인 셸에서)
        let before = AgentScanner.lastOutput(tty: tty)
        Thread.sleep(forTimeInterval: 0.3)
        do {
            try tmux.send(text: "echo typed-$((40+2))", pressEnter: true, to: launched)
            let typed = waitForScreen(tmux, launched) { $0.contains("typed-42") && !$0.hasSuffix("typed-$((40+2))") }
            check(ANSIText.plain(typed).contains("\ntyped-42"), "글자 + Enter")
            let after = AgentScanner.lastOutput(tty: tty)
            check(before != nil && after != nil && after! > before!, "출력하면 tty 수정 시각이 바뀜",
                  "\(String(describing: before)) → \(String(describing: after))")

            try tmux.send(text: "echo not-run", pressEnter: false, to: launched)
            Thread.sleep(forTimeInterval: 0.3)
            try tmux.send(key: .ctrlC, to: launched)
            try tmux.send(key: .escape, to: launched)
            try tmux.send(text: "echo after-ctrl-c", pressEnter: true, to: launched)
            let cancelled = waitForScreen(tmux, launched) { ANSIText.plain($0).contains("\nafter-ctrl-c") }
            check(!ANSIText.plain(cancelled).contains("\nnot-run"), "Enter 없이 보낸 글자는 실행 안 됨, Ctrl-C로 지움")

            try tmux.send(text: "echo line-one\necho line-two", pressEnter: true, to: launched)
            let pasted = waitForScreen(tmux, launched) { ANSIText.plain($0).contains("\nline-two") }
            check(ANSIText.plain(pasted).contains("\nline-one") && ANSIText.plain(pasted).contains("\nline-two"), "여러 줄 붙여넣기")
        } catch {
            check(false, "보내기", error.localizedDescription)
        }

        // 3) attach 명령, 끝내기
        let attach = tmux.attachCommand(for: launched)
        check(attach == "'\(tmux.executable!)' -S '\(socket)' attach -t 'cheoma-test-\(tag)-1'", "attachCommand", attach ?? "nil")

        _ = try? tmux.run(["new-session", "-d", "-s", "other-\(tag)", "-x", "80", "-y", "24", "sleep", "30"])
        if let other = ((try? tmux.panes()) ?? []).first(where: { $0.sessionName == "other-\(tag)" }) {
            let location = TerminalLocation.tmux(paneID: other.paneID, tty: other.tty)
            check(thrownMessage { try tmux.kill(location) } == "Cheoma가 띄운 tmux 세션만 끝낼 수 있어요", "cheoma- 아닌 세션은 안 끝냄")
        } else {
            check(false, "다른 세션 만들기")
        }
        do {
            try tmux.kill(launched)
            if let second { try tmux.kill(second) }
            let left = ((try? tmux.panes()) ?? []).map(\.sessionName)
            check(left == ["other-\(tag)"], "kill-session", "\(left)")
        } catch {
            check(false, "kill", error.localizedDescription)
        }
        check(thrownMessage { try tmux.capture(.tmux(paneID: "%999", tty: "")) } == TmuxBridge.Message.paneMissing, "없는 패널")
        check(thrownMessage { try tmux.send(key: .enter, to: .terminalApp(tty: "/dev/ttys001")) } == "tmux 세션이 아니에요", "다른 위치")
    }

    private static func waitForScreen(_ tmux: TmuxBridge, _ location: TerminalLocation, until done: (String) -> Bool) -> String {
        var text = ""
        for _ in 0..<40 {
            text = (try? tmux.capture(location).text) ?? ""
            if done(text) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return text
    }

    // MARK: - 지금 이 맥

    private static func scanNow() {
        print("\n지금 도는 에이전트")
        var best = Double.infinity
        var agents: [AgentProcess] = []
        for _ in 0..<5 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            agents = AgentScanner.scan()
            best = min(best, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
        }
        print("  \(agents.count)개, 가장 빠른 scan \(String(format: "%.1f", best))ms")
        check(best < 30, "scan이 가볍다")
        let me = ProcessInfo.processInfo.processIdentifier
        check(!agents.contains { $0.pid == me }, "자기 자신은 없음")
    }
}

import Foundation

/// tmux 패널 하나
struct TmuxPane: Hashable, Sendable {
    /// "%3" 같은 tmux 고유 ID
    var paneID: String
    var sessionName: String
    /// "세션:창.패널"
    var target: String
    var tty: String
    /// 패널의 첫 프로세스 (보통 셸)
    var pid: pid_t
    var currentCommand: String
    var currentPath: String
    /// 이 세션에 붙어 있는 클라이언트 tty들 (Terminal 탭에서 tmux attach 중이면 그 탭의 tty)
    var clientTTYs: [String]
}

/// tmux 연동. 사용자가 직접 띄운 세션도 보이도록 기본 tmux 서버를 쓴다.
/// 앱은 PATH가 짧은 GUI 프로세스라 tmux를 알려진 위치에서 찾고, 명령마다 2초 안에 끝나지 않으면 끊는다
final class TmuxBridge: TerminalBridge, Sendable {
    static let shared = TmuxBridge()
    /// Cheoma가 띄운 세션 이름의 앞부분
    static let sessionPrefix = "cheoma-"

    private static let timeout: TimeInterval = 2
    /// 새로 띄우는 세션의 크기. 노치 미리보기와 나중에 붙을 Terminal 창에 둘 다 무난한 크기
    private static let launchSize = (columns: 160, rows: 48)
    /// 출력 형식에서 칸을 나누는 글자 (세션 이름 · 경로에 나올 일이 없는 제어 문자)
    static let separator = "\u{1F}"

    /// 기본 서버 대신 쓸 소켓 (`-S`). 테스트에서만 쓴다: 사용자의 tmux 서버를 건드리지 않게
    let socketPath: String?

    init(socketPath: String? = nil) {
        self.socketPath = socketPath
    }

    /// tmux 실행 파일 경로 (/opt/homebrew/bin/tmux, /usr/local/bin/tmux, PATH). 없으면 nil
    var executable: String? {
        let known = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
        return (known + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 모든 세션의 패널. tmux 서버가 안 떠 있으면 빈 배열
    func panes() throws -> [TmuxPane] {
        let format = ["#{pane_id}", "#{session_name}", "#{session_name}:#{window_index}.#{pane_index}", "#{pane_tty}",
                      "#{pane_pid}", "#{pane_current_command}", "#{pane_current_path}"].joined(separator: Self.separator)
        guard let paneOutput = try runIfServer(["list-panes", "-a", "-F", format]) else { return [] }
        let clientOutput = try runIfServer(["list-clients", "-F", "#{client_tty}\(Self.separator)#{client_session}"]) ?? ""
        return Self.parsePanes(paneOutput, clients: clientOutput)
    }

    /// 새 tmux 세션에서 에이전트를 띄운다. 사용자 로그인 셸로 실행해서 PATH · 별칭이 터미널에서와 같다
    func launch(_ kind: AgentKind, in folder: String) throws -> TerminalLocation {
        try launch(command: kind.command, namePrefix: Self.sessionPrefix + kind.rawValue, in: folder)
    }

    /// launch의 본체. 테스트에서는 에이전트 대신 해 없는 명령(echo hi; sleep 30)으로 부른다
    func launch(command: String, namePrefix: String, in folder: String) throws -> TerminalLocation {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentBridgeError(message: "그 폴더를 찾지 못했어요")
        }
        let shell = Self.loginShell()
        let existing = Set(try runIfServer(["list-sessions", "-F", "#{session_name}"])?.split(separator: "\n").map(String.init) ?? [])
        var number = 1
        // 그 사이 같은 이름이 생기면(duplicate session) 다음 번호로 다시 해 본다
        for _ in 0..<5 {
            while existing.contains("\(namePrefix)-\(number)") { number += 1 }
            let name = "\(namePrefix)-\(number)"
            let arguments = Self.launchArguments(sessionName: name, folder: folder, shell: shell, command: command)
            do {
                let output = try run(arguments)
                let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: Self.separator)
                guard fields.count == 2, fields[0].hasPrefix("%") else {
                    throw AgentBridgeError(message: "tmux 세션을 만들었지만 패널을 찾지 못했어요")
                }
                return .tmux(paneID: fields[0], tty: fields[1])
            } catch let error as AgentBridgeError where error.message.contains("duplicate session") {
                number += 1
            }
        }
        throw AgentBridgeError(message: "tmux 세션 이름을 정하지 못했어요")
    }

    /// 그 패널의 세션을 붙이는 명령 (`tmux attach -t …`). Terminal 새 탭에서 열 때 쓴다
    func attachCommand(for location: TerminalLocation) -> String? {
        guard let executable, let session = try? sessionName(of: location) else { return nil }
        return Self.attachCommand(executable: executable, socketPath: socketPath, session: session)
    }

    /// Cheoma가 띄운 세션을 끝낸다
    func kill(_ location: TerminalLocation) throws {
        let session = try sessionName(of: location)
        guard session.hasPrefix(Self.sessionPrefix) else {
            throw AgentBridgeError(message: "Cheoma가 띄운 tmux 세션만 끝낼 수 있어요")
        }
        _ = try run(["kill-session", "-t", "=" + session])
    }

    /// 보이는 화면 그대로 (ANSI 색 코드 포함)
    func capture(_ location: TerminalLocation) throws -> TerminalScreen {
        let pane = try Self.paneID(of: location)
        let output = try run(["capture-pane", "-p", "-e", "-t", pane])
        return TerminalScreen(text: AgentCommandRunner.trimmingTrailingBlankLines(output), capturedAt: Date())
    }

    /// 글자를 그대로(-l) 보낸다. 여러 줄이면 붙여넣기로 보내서 줄바꿈이 중간에 Enter로 들어가지 않게 한다
    func send(text: String, pressEnter: Bool, to location: TerminalLocation) throws {
        let pane = try Self.paneID(of: location)
        if !text.isEmpty {
            if text.contains("\n") || text.contains("\r") {
                let buffer = "cheoma-send"
                _ = try run(["set-buffer", "-b", buffer, "--", text])
                // -p: 앱이 bracketed paste를 켰으면 붙여넣기 표시로 감싼다. -d: 다 쓰면 버퍼를 지운다
                _ = try run(["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane])
            } else {
                _ = try run(["send-keys", "-t", pane, "-l", "--", text])
            }
            // Codex · Claude Code는 글자가 몰려 들어오면 붙여넣기로 보고 바로 뒤 Enter를 줄바꿈으로 받는다. 조금 쉬었다 누른다
            if pressEnter { Thread.sleep(forTimeInterval: 0.15) }
        }
        if pressEnter {
            _ = try run(["send-keys", "-t", pane, "Enter"])
        }
    }

    func send(key: TerminalKey, to location: TerminalLocation) throws {
        let pane = try Self.paneID(of: location)
        _ = try run(["send-keys", "-t", pane, Self.keyName(key)])
    }

    /// 그 세션이 이미 Terminal 탭에 붙어 있으면 그 탭을, 아니면 Terminal 새 창에서 세션을 붙인다
    func reveal(_ location: TerminalLocation) throws {
        let session = try sessionName(of: location)
        let terminal = TerminalAppBridge.shared
        if terminal.isRunning {
            let clients = try run(["list-clients", "-t", "=" + session, "-F", "#{client_tty}"])
                .split(separator: "\n").map(String.init)
            if !clients.isEmpty, let tab = try terminal.tabs().first(where: { clients.contains($0.tty) }) {
                try terminal.reveal(.terminalApp(tty: tab.tty))
                return
            }
        }
        guard let executable else { throw AgentBridgeError(message: Self.Message.notInstalled) }
        try terminal.openTab(command: Self.attachCommand(executable: executable, socketPath: socketPath, session: session), in: nil)
    }

    // MARK: - 순수 함수 (`--agents --selftest`에서 확인)

    enum Message {
        static let notInstalled = "tmux를 찾지 못했어요. brew install tmux로 설치해 주세요"
        static let timeout = "tmux가 응답하지 않아요"
        static let paneMissing = "그 tmux 패널을 찾지 못했어요"
        static let noServer = "tmux가 꺼져 있어요"
    }

    static func keyName(_ key: TerminalKey) -> String {
        switch key {
        case .enter: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .backspace: "BSpace"
        case .ctrlC: "C-c"
        }
    }

    static func parsePanes(_ output: String, clients: String) -> [TmuxPane] {
        var clientTTYs: [String: [String]] = [:]
        for line in clients.split(separator: "\n") {
            let fields = line.components(separatedBy: separator)
            guard fields.count == 2, !fields[0].isEmpty else { continue }
            clientTTYs[fields[1], default: []].append(fields[0])
        }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: separator)
            guard fields.count == 7, fields[0].hasPrefix("%") else { return nil }
            return TmuxPane(paneID: fields[0], sessionName: fields[1], target: fields[2], tty: fields[3],
                            pid: pid_t(fields[4]) ?? 0, currentCommand: fields[5], currentPath: fields[6],
                            clientTTYs: clientTTYs[fields[1]] ?? [])
        }
    }

    /// 새 세션 인자. 셸을 로그인 · 대화형으로 띄워 사용자 설정(PATH, 별칭)을 읽고, 에이전트가 끝나면 그 자리에 셸을 남겨 출력이 보이게 한다.
    /// tmux 서버를 다른 Claude Code 세션 안에서 띄웠다면 서버 환경에 CLAUDECODE가 남아 있어 새 Claude Code가 자기를 하위 세션으로 착각한다. 그래서 지운다
    static func launchArguments(sessionName: String, folder: String, shell: String, command: String) -> [String] {
        ["new-session", "-d", "-P", "-F", "#{pane_id}\(separator)#{pane_tty}",
         "-s", sessionName, "-c", folder, "-x", "\(launchSize.columns)", "-y", "\(launchSize.rows)",
         shell, "-l", "-i", "-c", shellScript(shell: shell, command: command)]
    }

    /// 로그인 셸 안에서 돌릴 글. 셸 별칭이 먹도록 `env -u` 대신 셸의 unset을 쓴다
    static func shellScript(shell: String, command: String) -> String {
        let name = (shell as NSString).lastPathComponent
        let variables = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        let unset: String
        switch name {
        case "fish": unset = variables.map { "set -e \($0)" }.joined(separator: "; ") + "; "
        case "zsh", "bash", "sh", "ksh", "dash", "mksh": unset = "unset \(variables.joined(separator: " ")); "
        // 모르는 셸은 이 명령만 env로 감싼다 (별칭은 못 쓴다)
        default: return "env \(variables.map { "-u \($0)" }.joined(separator: " ")) \(command); exec \(AgentCommandRunner.shellQuoted(shell)) -l"
        }
        return "\(unset)\(command); exec \(AgentCommandRunner.shellQuoted(shell)) -l"
    }

    static func attachCommand(executable: String, socketPath: String?, session: String) -> String {
        let socket = socketPath.map { " -S \(AgentCommandRunner.shellQuoted($0))" } ?? ""
        return "\(AgentCommandRunner.shellQuoted(executable))\(socket) attach -t \(AgentCommandRunner.shellQuoted(session))"
    }

    /// tmux 오류 출력을 화면에 보여줄 말로
    static func message(forError error: String) -> String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoServer(text) { return Message.noServer }
        if text.contains("can't find pane") || text.contains("can't find window") || text.contains("can't find session") {
            return Message.paneMissing
        }
        if text.contains("duplicate session") { return "같은 이름의 tmux 세션이 있어요 (duplicate session)" }
        return "tmux 명령이 실패했어요" + (text.isEmpty ? "" : ": " + (text.split(separator: "\n").first.map(String.init) ?? text))
    }

    static func isNoServer(_ error: String) -> Bool {
        error.contains("no server running") || (error.contains("error connecting to") && error.contains("No such file or directory"))
    }

    /// 사용자 로그인 셸 (계정 설정). 못 읽으면 macOS 기본인 zsh
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    // MARK: - 실행

    private static func paneID(of location: TerminalLocation) throws -> String {
        guard case .tmux(let paneID, _) = location else { throw AgentBridgeError(message: "tmux 세션이 아니에요") }
        return paneID
    }

    private func sessionName(of location: TerminalLocation) throws -> String {
        let pane = try Self.paneID(of: location)
        let name = try run(["display-message", "-p", "-t", pane, "#{session_name}"]).trimmingCharacters(in: .newlines)
        guard !name.isEmpty else { throw AgentBridgeError(message: Message.paneMissing) }
        return name
    }

    /// 서버가 없으면 nil (오류 아님)
    private func runIfServer(_ arguments: [String]) throws -> String? {
        do {
            return try run(arguments, allowNoServer: true)
        } catch RunError.noServer {
            return nil
        }
    }

    private enum RunError: Error { case noServer }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        try run(arguments, allowNoServer: false)
    }

    private func run(_ arguments: [String], allowNoServer: Bool) throws -> String {
        guard let executable else { throw AgentBridgeError(message: Message.notInstalled) }
        // -u: 앱 환경에 LANG이 없어도 한글 · 상자 글자를 UTF-8로 주고받는다 (없으면 _로 바뀐다)
        let socket = socketPath.map { ["-S", $0] } ?? []
        let result: AgentCommandRunner.Result
        do {
            result = try AgentCommandRunner.run(executable, ["-u"] + socket + arguments,
                                                environment: Self.environment(), timeout: Self.timeout)
        } catch {
            throw AgentBridgeError(message: "tmux를 실행하지 못했어요: \(error.localizedDescription)")
        }
        if result.timedOut { throw AgentBridgeError(message: Message.timeout) }
        guard result.status == 0 else {
            if allowNoServer, Self.isNoServer(result.error) { throw RunError.noServer }
            throw AgentBridgeError(message: Self.message(forError: result.error))
        }
        return result.output
    }

    /// tmux에 넘길 환경. 처음 서버를 띄우면 이 환경이 모든 세션에 물려진다
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // 다른 Claude Code 안에서 띄운 Cheoma(--agents 등)라도 서버에 이 값이 남지 않게
        environment["CLAUDECODE"] = nil
        environment["CLAUDE_CODE_ENTRYPOINT"] = nil
        if environment["LANG"] == nil && environment["LC_ALL"] == nil && environment["LC_CTYPE"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }
}

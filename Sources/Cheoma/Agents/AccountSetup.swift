import Foundation

/// 구독 계정을 하나 더 추가한다: 설정 폴더를 만들고, 셸 설정에 alias를 넣고, Terminal에서 그 계정 로그인을 시작한다.
/// 폴더로 계정을 나눌 수 있는 Claude Code(CLAUDE_CONFIG_DIR)와 Codex(CODEX_HOME)만. Antigravity CLI(agy)는 로그인을
/// macOS 키체인에 둬서 폴더를 나눠도 같은 계정이 된다 (agy 1.4.12, 11/2 확인)
enum AccountSetup {
    struct Plan: Equatable {
        var kind: AgentKind
        /// 계정 번호 (account3 → 3)
        var number: Int
        /// 설정 폴더 (~/.claude-account3)
        var folder: URL
        /// 셸 설정 파일 (~/.zshrc)
        var shellFile: URL
        /// "claude3"
        var aliasName: String
        /// "alias claude3='CLAUDE_CONFIG_DIR=~/.claude-account3 claude'"
        var aliasLine: String
        /// 이미 같은 이름의 alias가 있어서 셸 설정은 건드리지 않는다
        var aliasExists: Bool
        /// Terminal에서 실행할 로그인 명령
        var loginCommand: String
    }

    static func canAdd(_ kind: AgentKind) -> Bool {
        kind == .claude || kind == .codex
    }

    /// 다음 계정 번호와 할 일. 이미 있는 ~/.claude-accountN · ~/.codex-accountN 다음 번호 (처음이면 2)
    static func plan(_ kind: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> Plan? {
        guard canAdd(kind) else { return nil }
        let prefix = kind == .claude ? ".claude-account" : ".codex-account"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let used = names.compactMap { name in name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil }
        let number = max(used.max() ?? 1, 1) + 1
        let folder = home.appendingPathComponent(prefix + "\(number)")
        let shellFile = home.appendingPathComponent(shell.hasSuffix("bash") ? ".bashrc" : ".zshrc")
        let aliasName = kind.command + "\(number)"
        // 지금 쓰는 모양과 같게: alias claude2='CLAUDE_CONFIG_DIR=~/.claude-account2 claude'
        let variable = kind == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let aliasLine = "alias \(aliasName)='\(variable)=\"$HOME/\(prefix)\(number)\" \(kind.command)'"
        let existing = (try? String(contentsOf: shellFile, encoding: .utf8)) ?? ""
        let aliasExists = existing.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("alias \(aliasName)=") }
        // Claude Code는 처음 띄우면 로그인부터 한다. Codex는 login 명령이 브라우저로 ChatGPT 로그인을 연다
        let quoted = AgentCommandRunner.shellQuoted(folder.path)
        let login = kind == .claude ? "CLAUDE_CONFIG_DIR=\(quoted) claude" : "CODEX_HOME=\(quoted) codex login"
        return Plan(kind: kind, number: number, folder: folder, shellFile: shellFile, aliasName: aliasName,
                    aliasLine: aliasLine, aliasExists: aliasExists, loginCommand: login)
    }

    /// 폴더를 만들고 셸 설정 끝에 alias를 덧붙인다 (원래 내용은 그대로, 같은 이름이 있으면 건드리지 않는다).
    /// 파일을 새로 쓰지 않고 끝에 붙여서 dotfiles 저장소로 이어진 링크도 그대로 둔다
    static func prepare(_ plan: Plan) throws {
        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        guard !plan.aliasExists else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: plan.shellFile.path) { manager.createFile(atPath: plan.shellFile.path, contents: nil) }
        let handle = try FileHandle(forUpdating: plan.shellFile)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var needsNewline = false
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            needsNewline = try handle.read(upToCount: 1) != Data("\n".utf8)
            try handle.seekToEnd()
        }
        let text = (needsNewline ? "\n" : "") + "\n# Cheoma: \(plan.kind.displayName) 계정 account\(plan.number)\n\(plan.aliasLine)\n"
        try handle.write(contentsOf: Data(text.utf8))
    }
}

import Foundation

/// 끝난 세션을 이어서 하기 (`claude --resume <id>`, `codex resume <id>`), 다른 Claude 계정으로 이어서 하기.
/// Claude Code는 `<설정 폴더>/projects/<폴더 이름>/<세션 ID>.jsonl`에서 이을 대화를 찾는다. 그래서 다른 계정으로 이을 때는
/// 그 기록(과 옆의 `<세션 ID>/` 폴더: 하위 에이전트 · 긴 도구 결과)을 그 계정의 같은 자리로 복사한 뒤 그 계정으로 띄운다.
/// Codex는 `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-…-<세션 ID>.jsonl`에서 찾아서, 그 기록을 다른 계정 폴더의 같은 자리로 복사한다
/// (codex 0.166에서 이렇게 복사한 세션을 `CODEX_HOME=… codex resume <id>`로 이을 수 있었다, 11/2 확인).
/// 원래 계정의 기록은 그대로 둔다
enum AgentResume {
    /// 이어서 할 세션
    struct Target: Equatable, Sendable {
        var kind: AgentKind
        var sessionID: String
        var cwd: String
        /// 지금 기록이 있는 Claude 설정 폴더 (Codex면 CODEX_HOME 폴더) 전체 경로 (모르면 nil: 설정 폴더를 다 찾아본다)
        var configDir: String?
    }

    /// 이 에이전트는 이어서 할 수 있다
    static func canResume(_ kind: AgentKind) -> Bool {
        kind == .claude || kind == .codex || kind == .antigravity
    }

    /// 기본 설정 폴더(~/.claude)면 CLAUDE_CONFIG_DIR를 붙이지 않는다. 기본 계정의 로그인 정보는 ~/.claude.json에 있어서
    /// CLAUDE_CONFIG_DIR=~/.claude로 띄우면 로그인이 안 된 것처럼 된다
    static func isDefault(configDir: String, home: String = NSHomeDirectory()) -> Bool {
        URL(fileURLWithPath: configDir).standardizedFileURL.path == URL(fileURLWithPath: home + "/.claude").standardizedFileURL.path
    }

    /// 기본 Codex 폴더(~/.codex)면 CODEX_HOME을 붙이지 않는다
    static func isDefault(codexHome: String, home: String = NSHomeDirectory()) -> Bool {
        URL(fileURLWithPath: codexHome).standardizedFileURL.path == URL(fileURLWithPath: home + "/.codex").standardizedFileURL.path
    }

    /// 새로 띄우는 명령. Claude는 계정(설정 폴더)을, Codex는 계정(CODEX_HOME)을 고를 수 있다
    static func launchCommand(_ kind: AgentKind, configDir: String?, home: String = NSHomeDirectory()) -> String {
        guard let configDir else { return kind.command }
        switch kind {
        case .claude where !isDefault(configDir: configDir, home: home):
            return "CLAUDE_CONFIG_DIR=\(AgentCommandRunner.shellQuoted(configDir)) \(kind.command)"
        case .codex where !isDefault(codexHome: configDir, home: home):
            return "CODEX_HOME=\(AgentCommandRunner.shellQuoted(configDir)) \(kind.command)"
        default:
            return kind.command
        }
    }

    /// 이어서 하는 명령
    static func resumeCommand(_ target: Target, configDir: String?, home: String = NSHomeDirectory()) -> String {
        let id = AgentCommandRunner.shellQuoted(target.sessionID)
        switch target.kind {
        case .codex: return "\(launchCommand(.codex, configDir: configDir ?? target.configDir, home: home)) resume \(id)"
        case .antigravity: return "\(target.kind.command) --conversation \(id)"
        default: return "\(launchCommand(target.kind, configDir: configDir, home: home)) --resume \(id)"
        }
    }

    /// 그 계정으로 이을 수 있게 기록을 옮겨 둔다. 계정마다 같은 세션이 있으면 가장 최근에 쓴 것을 쓴다
    /// (그 계정에 더 새 기록이 있으면 아무것도 하지 않는다). 기록을 못 찾으면 오류
    static func prepare(_ target: Target, for configDir: String, among configDirs: [String]) throws {
        if target.kind == .codex { return try prepareCodex(target, for: configDir, among: configDirs) }
        guard target.kind == .claude else { return }
        let manager = FileManager.default
        let candidates = (target.configDir.map { [$0] } ?? []) + configDirs
        var newest: (url: URL, date: Date)?
        for dir in Set(candidates) {
            for file in transcripts(sessionID: target.sessionID, configDir: dir) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.date { newest = (file, date) }
            }
        }
        guard let source = newest?.url else { throw AgentBridgeError(message: "대화 기록 없음") }
        let projects = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        // 이미 그 계정의 기록이 가장 새것이다
        if source.path.hasPrefix(projects.standardizedFileURL.path + "/") { return }
        // 폴더 이름은 작업 폴더로 정해지니 원래 계정과 같은 이름을 쓴다
        let folder = projects.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        // 그 계정에 있던 더 오래된 기록은 지우지 않고 옆에 남겨 둔다 (.jsonl이 아니라 Claude Code는 읽지 않는다)
        if manager.fileExists(atPath: destination.path) {
            try replace(destination.appendingPathExtension("cheoma-backup"), with: destination)
        }
        try replace(destination, with: source)
        let extras = source.deletingPathExtension()
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: extras.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try replace(folder.appendingPathComponent(extras.lastPathComponent), with: extras)
        }
    }

    /// Codex: 가장 최근 기록을 그 계정 폴더의 sessions/ 아래 같은 자리로 복사한다
    private static func prepareCodex(_ target: Target, for codexHome: String, among codexHomes: [String]) throws {
        var newest: (url: URL, date: Date)?
        for home in Set((target.configDir.map { [$0] } ?? []) + codexHomes + [codexHome]) {
            for file in codexRollouts(sessionID: target.sessionID, codexHome: home) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.date { newest = (file, date) }
            }
        }
        guard let source = newest?.url else { throw AgentBridgeError(message: "대화 기록 없음") }
        let sessions = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions").standardizedFileURL
        // 이미 그 계정의 기록이 가장 새것이다
        if source.path.hasPrefix(sessions.path + "/") { return }
        // sessions/ 아래 경로(YYYY/MM/DD/파일)를 그대로 쓴다
        guard let range = source.path.range(of: "/sessions/", options: .backwards) else {
            throw AgentBridgeError(message: "Codex 기록 위치를 알 수 없음")
        }
        let destination = sessions.appendingPathComponent(String(source.path[range.upperBound...]))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try replace(destination.appendingPathExtension("cheoma-backup"), with: destination)
        }
        try replace(destination, with: source)
    }

    /// `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-…-<세션 ID>.jsonl`
    static func codexRollouts(sessionID: String, codexHome: String) -> [URL] {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        let suffix = "-\(sessionID).jsonl"
        var result: [URL] = []
        func children(_ url: URL) -> [URL] { (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] }
        for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    result += children(day).filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix(suffix) }
                }
            }
        }
        return result.map(\.standardizedFileURL)
    }

    /// `<설정 폴더>/projects/*/<세션 ID>.jsonl`
    static func transcripts(sessionID: String, configDir: String) -> [URL] {
        let projects = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.standardizedFileURL)
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
    }
}

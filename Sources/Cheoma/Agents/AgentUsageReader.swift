import Foundation

/// 에이전트 기록 파일에서 사용량과 최근 세션을 읽는다 (내 맥 안의 파일만, 네트워크 없음).
/// - Codex: ~/.codex/sessions/**/rollout-*.jsonl 의 token_count 이벤트 → rate_limits (5시간 · 1주 사용 %, 리셋 시각)
/// - Claude Code: ~/.claude*/projects/**/*.jsonl (설정 폴더마다 계정 하나) → 오늘 · 지금 5시간 구간의 비용과 토큰, 세션 제목
/// 파일마다 어디까지 읽었는지 기억해서 바뀐 부분만 이어서 읽는다. 바뀐 게 없으면 파일 상태만 확인한다. 백그라운드 큐에서 부른다
final class AgentUsageReader {
    /// 이 시간 안에 바뀐 Claude 기록만 읽는다 (오늘 + 진행 중인 5시간 구간을 찾으려면 그 앞의 빈 시간까지 필요하다)
    static let usageWindow: TimeInterval = 48 * 3_600
    static let recentWindow: TimeInterval = 24 * 3_600
    static let blockLength: TimeInterval = 5 * 3_600
    static let maxRecentSessions = 30

    private let home: String
    private let environment: [String: String]
    private let lock = NSLock()
    var buffer = [UInt8]()

    // Claude
    private var claudeAccounts: [String: ClaudeAccount] = [:]
    var modelIndexes: [String: Int] = [:]
    var modelNames: [String] = []
    private var costSamples: [String: (stat: JSONLFile.Stat, sample: CostStateSample?)] = [:]
    private var rates: [String: Double] = [:]

    // Codex
    private var codexFiles: [String: CodexFile] = [:]
    private var codexTails: [String: (stat: JSONLFile.Stat, limits: CodexLimits?)] = [:]
    private var codexTitles: [String: String] = [:]
    private var codexIndex: (stat: JSONLFile.Stat, offset: Int64)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home.path
        self.environment = environment
    }

    func read() -> AgentUsage {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var usage = AgentUsage()
        var sessions: [RecordedSession] = []

        let dirs = Self.claudeConfigDirs(home: URL(fileURLWithPath: home), environment: environment).map(\.path)
        for dir in dirs {
            let account = claudeAccounts[dir] ?? ClaudeAccount(dir: dir)
            claudeAccounts[dir] = account
            refreshClaude(account, now: now)
        }
        claudeAccounts = claudeAccounts.filter { dirs.contains($0.key) }
        learnRates(accounts: dirs.compactMap { claudeAccounts[$0] }, now: now)
        for dir in dirs {
            guard let account = claudeAccounts[dir], FileManager.default.fileExists(atPath: dir + "/projects") else { continue }
            usage.claude.append(summarize(account, now: now))
            sessions += recentSessions(account, now: now)
        }

        let codexHome = Self.codexHome(home: URL(fileURLWithPath: home), environment: environment).path
        usage.codex = refreshCodex(codexHome: codexHome, now: now, sessions: &sessions)

        usage.recentSessions = Array(sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(Self.maxRecentSessions))
        return usage
    }

    // MARK: - 설정 폴더

    /// Claude Code 설정 폴더들: $CLAUDE_CONFIG_DIR, ~/.claude, 그리고 projects/가 있는 ~/.claude-* (계정마다 하나)
    static func claudeConfigDirs(home: URL, environment: [String: String]) -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !result.contains(where: { $0.path == standardized.path }) else { return }
            result.append(standardized)
        }
        add(home.appendingPathComponent(".claude"))
        let others = (try? manager.contentsOfDirectory(atPath: home.path)) ?? []
        for name in others.sorted() where name.hasPrefix(".claude-") {
            let dir = home.appendingPathComponent(name)
            if manager.fileExists(atPath: dir.appendingPathComponent("projects").path) { add(dir) }
        }
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            add(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        return result
    }

    static func codexHome(home: URL, environment: [String: String]) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        return home.appendingPathComponent(".codex")
    }

    // MARK: - Claude

    private func refreshClaude(_ account: ClaudeAccount, now: Double) {
        let windowStart = now - Self.usageWindow
        let projects = account.dir + "/projects"
        var sessionFiles: [(path: String, stat: JSONLFile.Stat)] = []
        var transcripts: [(path: String, stat: JSONLFile.Stat, isSubagent: Bool, session: String)] = []
        for (project, isDirectory) in JSONLFile.list(projects) where isDirectory {
            let folder = projects + "/" + project
            let entries = JSONLFile.list(folder)
            var activeSessions = Set<String>()
            for (name, isDirectory) in entries where !isDirectory && name.hasSuffix(".jsonl") {
                let path = folder + "/" + name
                guard let stat = JSONLFile.stat(path) else { continue }
                let session = String(name.dropLast(6))
                sessionFiles.append((path, stat))
                transcripts.append((path, stat, false, session))
                if stat.mtime >= windowStart { activeSessions.insert(session) }
            }
            // 하위 에이전트 기록은 부모 세션이 최근에 움직였을 때만 찾는다 (오래된 세션 폴더 수천 개를 매번 훑지 않으려고)
            for (name, isDirectory) in entries where isDirectory && activeSessions.contains(name) {
                for path in Self.jsonlFiles(under: folder + "/" + name, depth: 4) {
                    guard let stat = JSONLFile.stat(path) else { continue }
                    transcripts.append((path, stat, true, name))
                }
            }
        }
        account.sessionFiles = sessionFiles

        var needsReset = false
        var alive = Set<String>()
        for item in transcripts {
            alive.insert(item.path)
            if let file = account.files[item.path] {
                if file.stat == item.stat { continue }
                // 파일이 바뀌어 쓰였거나 줄어들었으면 처음부터 다시 읽는다 (중복 제거 상태가 꼬이지 않게 계정 전체를)
                if file.stat.inode != item.stat.inode || item.stat.size < file.offset {
                    needsReset = true
                    break
                }
                file.stat = item.stat
                parseClaude(file, path: item.path, account: account, windowStart: windowStart)
            } else if item.stat.mtime >= windowStart {
                let file = ClaudeFile(stat: item.stat, isSubagent: item.isSubagent, sessionID: item.session)
                account.files[item.path] = file
                parseClaude(file, path: item.path, account: account, windowStart: windowStart)
            }
        }
        if needsReset {
            account.reset()
            refreshClaude(account, now: now)
            return
        }
        if account.files.count > alive.count { account.files = account.files.filter { alive.contains($0.key) } }
        if account.needsSort {
            account.records.sort { $0.time < $1.time }
            account.needsSort = false
        }
        if let first = account.records.first, first.time < windowStart {
            account.records.removeAll { $0.time < windowStart }
        }
    }

    private func parseClaude(_ file: ClaudeFile, path: String, account: ClaudeAccount, windowStart: Double) {
        file.offset = JSONLFile.readLines(path: path, from: file.offset, to: file.stat.size, buffer: &buffer) { line in
            parseClaudeLine(line, file: file, account: account, windowStart: windowStart)
        }
    }

    static func jsonlFiles(under dir: String, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        var result: [String] = []
        for (name, isDirectory) in JSONLFile.list(dir) {
            let path = dir + "/" + name
            if isDirectory {
                result += jsonlFiles(under: path, depth: depth - 1)
            } else if name.hasSuffix(".jsonl") {
                result.append(path)
            }
        }
        return result
    }

    /// 최근에 끝난 세션들의 cost-state로 모델별 단가를 배운다. 바뀐 파일만 끝부분을 다시 읽는다
    private func learnRates(accounts: [ClaudeAccount], now: Double) {
        var changed = false
        var wanted = Set<String>()
        for account in accounts {
            // 최근 24시간 세션은 모두 (세션 비용에 쓴다), 그보다 오래된 것은 최근 60개만
            let sorted = account.sessionFiles.sorted { $0.stat.mtime > $1.stat.mtime }
            for (index, item) in sorted.enumerated() where index < 60 || item.stat.mtime >= now - Self.recentWindow {
                wanted.insert(item.path)
                if costSamples[item.path]?.stat == item.stat { continue }
                costSamples[item.path] = (item.stat, readCostState(path: item.path, stat: item.stat))
                changed = true
            }
        }
        if costSamples.count > wanted.count {
            costSamples = costSamples.filter { wanted.contains($0.key) }
            changed = true
        }
        if changed || rates.isEmpty { rates = Self.learnRates(from: costSamples.values.compactMap(\.sample)) }
    }

    private func modelRates() -> [Double?] {
        modelNames.map { Self.rate(for: $0, in: rates) }
    }

    private func summarize(_ account: ClaudeAccount, now: Double) -> ClaudeUsage {
        let rates = modelRates()
        let todayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        var todayCost = 0.0
        var todayTokens = 0
        // ccusage와 같은 5시간 구간: 앞 요청과 5시간 넘게 떨어졌거나 구간이 5시간을 넘으면 새 구간. 시작은 정시로 내린다
        var blockStart: Double?
        var blockCost = 0.0
        var lastTime = -Double.infinity
        for record in account.records {
            let cost = (rates[record.model] ?? 0) * record.weight
            if record.time >= todayStart {
                todayCost += cost
                todayTokens += record.tokens
            }
            if blockStart == nil || record.time - blockStart! > Self.blockLength || record.time - lastTime > Self.blockLength {
                blockStart = (record.time / 3_600).rounded(.down) * 3_600
                blockCost = 0
            }
            blockCost += cost
            lastTime = record.time
        }
        var usage = ClaudeUsage(account: URL(fileURLWithPath: account.dir).lastPathComponent, todayCostUSD: todayCost, todayTokens: todayTokens,
                                blockCostUSD: 0, blockStartedAt: nil, blockEndsAt: nil,
                                updatedAt: account.records.last.map { Date(timeIntervalSince1970: $0.time) })
        if let blockStart, now - lastTime < Self.blockLength, now < blockStart + Self.blockLength {
            usage.blockCostUSD = blockCost
            usage.blockStartedAt = Date(timeIntervalSince1970: blockStart)
            usage.blockEndsAt = Date(timeIntervalSince1970: blockStart + Self.blockLength)
        }
        return usage
    }

    private func recentSessions(_ account: ClaudeAccount, now: Double) -> [RecordedSession] {
        let rates = modelRates()
        var subagentWeights: [String: [Int: Double]] = [:]
        for file in account.files.values where file.isSubagent {
            subagentWeights[file.sessionID, default: [:]].merge(file.weights, uniquingKeysWith: +)
        }
        var result: [RecordedSession] = []
        for item in account.sessionFiles where item.stat.mtime >= now - Self.recentWindow {
            guard let file = account.files[item.path], file.hasMessages else { continue }
            let weights = file.weights.merging(subagentWeights[file.sessionID] ?? [:], uniquingKeysWith: +)
            var estimate: Double?
            for (model, weight) in weights {
                guard let rate = rates[model] else { continue }
                estimate = (estimate ?? 0) + rate * weight
            }
            // 끝난 세션은 cost-state가 정확하다. 이어 한 세션은 cost-state가 일부만 셀 수 있어서 큰 쪽을 쓴다
            let recorded = costSamples[item.path]?.sample?.totalCostUSD
            let cost: Double? = switch (estimate, recorded) {
            case let (a?, b?): max(a, b)
            case let (a, b): a ?? b
            }
            result.append(RecordedSession(id: file.sessionID, kind: .claude, cwd: file.cwd, title: file.title ?? file.summary,
                                          lastActivity: Date(timeIntervalSince1970: item.stat.mtime), costUSD: cost,
                                          lastMessage: file.lastMessage, isTurnComplete: file.isTurnComplete))
        }
        return result
    }

    // MARK: - Codex

    private func refreshCodex(codexHome: String, now: Double, sessions: inout [RecordedSession]) -> CodexUsage? {
        let rollouts = Self.jsonlFiles(under: codexHome + "/sessions", depth: 4)
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("rollout-") }
            .compactMap { path in JSONLFile.stat(path).map { (path: path, stat: $0) } }
        guard !rollouts.isEmpty else {
            codexFiles = [:]
            return nil
        }
        let recentStart = now - Self.recentWindow
        var alive = Set<String>()
        for item in rollouts where item.stat.mtime >= recentStart {
            alive.insert(item.path)
            let file: CodexFile
            if let existing = codexFiles[item.path] {
                if existing.stat == item.stat { continue }
                if existing.stat.inode != item.stat.inode || item.stat.size < existing.offset {
                    file = CodexFile(stat: item.stat)
                    codexFiles[item.path] = file
                } else {
                    file = existing
                    file.stat = item.stat
                }
            } else {
                file = CodexFile(stat: item.stat)
                codexFiles[item.path] = file
            }
            file.offset = JSONLFile.readLines(path: item.path, from: file.offset, to: item.stat.size, buffer: &buffer) { line in
                parseCodexLine(line, file: file)
            }
        }
        codexFiles = codexFiles.filter { alive.contains($0.key) }
        refreshCodexTitles(codexHome: codexHome)

        for (path, file) in codexFiles {
            guard let stat = rollouts.first(where: { $0.path == path })?.stat, stat.mtime >= recentStart else { continue }
            let id = file.sessionID ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            sessions.append(RecordedSession(id: id, kind: .codex, cwd: file.cwd, title: file.sessionID.flatMap { codexTitles[$0] },
                                            lastActivity: Date(timeIntervalSince1970: stat.mtime), costUSD: nil,
                                            lastMessage: file.lastMessage, isTurnComplete: file.isTurnComplete))
        }

        // 한도는 가장 최근 기록에서. 마지막 세션이 오류로 끝나면 rate_limits가 없어서 그 앞 파일들까지 끝부분을 본다
        var best = codexFiles.values.compactMap(\.limits).max { $0.time < $1.time }
        let newest = rollouts.sorted { $0.stat.mtime > $1.stat.mtime }.prefix(6)
        for item in newest {
            let limits: CodexLimits?
            if let cached = codexTails[item.path], cached.stat == item.stat {
                limits = cached.limits
            } else {
                let file = CodexFile(stat: item.stat)
                JSONLFile.readTail(path: item.path, size: item.stat.size, maxBytes: 512 << 10, buffer: &buffer) { line in
                    parseCodexLine(line, file: file)
                }
                limits = file.limits
                codexTails[item.path] = (item.stat, limits)
            }
            if let limits, limits.time > (best?.time ?? 0) { best = limits }
        }
        let newestPaths = Set(newest.map(\.path))
        codexTails = codexTails.filter { newestPaths.contains($0.key) }
        return best?.usage
    }

    /// session_index.jsonl: 세션 ID → 제목 (뒤에 적힌 것이 최신)
    private func refreshCodexTitles(codexHome: String) {
        let path = codexHome + "/session_index.jsonl"
        guard let stat = JSONLFile.stat(path) else { return }
        var offset: Int64 = 0
        if let index = codexIndex {
            if index.stat == stat { return }
            if index.stat.inode == stat.inode, stat.size >= index.offset { offset = index.offset } else { codexTitles = [:] }
        }
        offset = JSONLFile.readLines(path: path, from: offset, to: stat.size, buffer: &buffer) { line in
            if let (id, name) = parseCodexIndexLine(line) { codexTitles[id] = name }
        }
        codexIndex = (stat, offset)
    }
}

import Darwin
import Foundation

/// 내 계정에서 도는 코드 에이전트 프로세스를 찾는다 (libproc, 권한 불필요).
/// 프로세스 이름·인자로 종류를 가리고, tty · 작업 폴더 · 시작 시각 · 띄운 앱을 채운다.
/// 전체 프로세스의 BSD 정보만 훑고, 이름이 후보인 것만 경로·인자를 더 읽어서 한 번에 몇 ms 안에 끝난다.
enum AgentScanner {
    /// 지금 도는 에이전트 프로세스 전부. 백그라운드 큐에서 몇 초마다 부르므로 가볍게 (몇 ms 안)
    static func scan() -> [AgentProcess] {
        let uid = getuid()
        var table: [pid_t: Entry] = [:]
        for pid in allPIDs() where pid > 0 {
            if let entry = shortInfo(pid) { table[pid] = entry }
        }

        var found: [pid_t: AgentKind] = [:]
        for (pid, entry) in table where entry.uid == uid && isCandidate(entry.name) {
            let path = executablePath(of: pid)
            guard let kind = kind(executablePath: path, arguments: arguments(of: pid) ?? []) else { continue }
            found[pid] = kind
        }

        var hosts: [pid_t: String?] = [:]  // 여러 에이전트가 같은 Terminal · tmux 서버를 거치므로 한 번만 읽는다
        var result: [AgentProcess] = []
        for (pid, kind) in found {
            let ancestors = ancestorChain(of: pid, in: table)
            // 에이전트가 띄운 같은 종류의 자식이나 도우미(Codex의 node → 실제 codex 등)는 맨 위 하나만 센다
            if ancestors.contains(where: { found[$0] != nil }) { continue }
            let host = hostApp(ancestors: ancestors, table: table, cache: &hosts)
            // Claude 데스크톱 앱 안에서 도는 Claude Code는 터미널 세션이 아니다
            if host == desktopClaude { continue }
            guard let info = bsdInfo(pid) else { continue }  // 그 사이 끝났다
            let tty = ttyPath(info.e_tdev)
            // 터미널도 앱도 없이 launchd 밑에서 도는 것은 백그라운드 서비스다 (opencode serve --service 등)
            if tty == nil, host == nil, info.pbi_ppid == 1 { continue }
            let startedAt = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
            result.append(AgentProcess(pid: pid, kind: kind, tty: tty, cwd: workingDirectory(of: pid),
                                       startedAt: startedAt, hostApp: host))
        }
        return result.sorted { ($0.startedAt ?? .distantPast, $0.pid) < ($1.startedAt ?? .distantPast, $1.pid) }
    }

    /// tty에 마지막으로 출력이 나간 시각 (tty 장치의 수정 시각). 화면이 바뀌는 중인지 Apple Event 없이 싸게 알 수 있다.
    /// 이 맥(macOS 26, tmux 3.8)에서 확인: tty에 글자가 쓰이면(에이전트 출력, 입력한 글자의 에코) st_mtime이 µs 단위로 바뀌고,
    /// 가만히 있으면 그대로다. 입력을 읽기만 하면 st_atime만 바뀐다. 그래서 mtime = 마지막 출력 시각으로 쓸 수 있다
    static func lastOutput(tty: String) -> Date? {
        var info = stat()
        guard stat(tty, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    /// 프로세스가 아직 살아 있는지
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: - 종류 가리기 (순수 함수: `--agents --selftest`에서 확인)

    /// 바로 실행되는 에이전트 실행 파일 이름
    private static let nativeNames: [String: AgentKind] = [
        "claude": .claude, "codex": .codex, "opencode": .opencode, "pi": .pi, "gemini": .gemini, "aider": .aider,
    ]

    /// 인터프리터(node 등)로 도는 CLI: 스크립트 경로에 이 글자가 들어 있으면 그 종류
    private static let scriptMarkers: [(String, AgentKind)] = [
        ("@anthropic-ai/claude-code", .claude),
        ("@openai/codex", .codex),
        ("@google/gemini-cli", .gemini),
        ("pi-coding-agent", .pi),
        ("opencode-ai", .opencode),
    ]

    /// 실행 파일 경로와 인자(argv)로 에이전트 종류를 가린다. 에이전트가 아니면 nil
    static func kind(executablePath path: String, arguments: [String]) -> AgentKind? {
        let execName = (path as NSString).lastPathComponent
        let lowered = execName.lowercased()

        if isScriptInterpreter(lowered) {
            // 옵션(--no-warnings 등)을 건너뛴 첫 인자가 실행할 스크립트다. 그 뒤 인자는 보지 않는다 (엉뚱한 경로에 속지 않게)
            var rest = arguments.dropFirst()[...]
            if lowered.hasPrefix("python") {
                // python -m aider
                if let index = rest.firstIndex(of: "-m"), rest.index(after: index) < rest.endIndex {
                    let module = rest[rest.index(after: index)]
                    if module == "aider" || module.hasPrefix("aider.") { return .aider }
                }
            }
            // process.title을 바꾼 CLI (pi): 인자 자리가 "pi" 하나로 덮여서 스크립트 경로가 안 보인다
            if let title = arguments.first.map({ ($0 as NSString).lastPathComponent }), let kind = nativeNames[title],
               kind != .aider, !lowered.hasPrefix("python") {
                return kind
            }
            while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst() }
            guard let script = rest.first else { return nil }
            if let marker = scriptMarkers.first(where: { script.contains($0.0) }) { return marker.1 }
            let scriptName = (script as NSString).lastPathComponent
            if let kind = nativeNames[scriptName] {
                // python으로 도는 건 aider뿐, node로 도는 aider는 없다
                if lowered.hasPrefix("python") { return kind == .aider ? kind : nil }
                return kind == .aider ? nil : kind
            }
            return nil
        }

        // 앱 번들 안의 실행 파일(Claude 데스크톱 앱 등)은 CLI 세션이 아니다
        if path.contains(".app/") { return nil }
        if let kind = nativeNames[execName] { return kind }
        // Claude Code 네이티브 설치는 실행 파일 이름이 버전 번호다 (~/.local/share/claude/versions/2.1.314). argv[0]은 "claude"
        if path.contains("/claude/versions/") { return .claude }
        if isVersion(execName), let first = arguments.first {
            let name = (first as NSString).lastPathComponent
            if let kind = nativeNames[name] { return kind }
        }
        return nil
    }

    private static func isScriptInterpreter(_ name: String) -> Bool {
        name == "node" || name == "bun" || name == "deno" || name.hasPrefix("python")
    }

    private static func isVersion(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// 경로·인자를 더 읽어 볼 프로세스인지 (BSD 정보의 이름만으로 거른다)
    private static func isCandidate(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return nativeNames[name] != nil || isScriptInterpreter(lowered) || isVersion(name)
    }

    // MARK: - 띄운 앱

    private static let desktopClaude = "Claude"

    /// 부모를 거슬러 올라가며 처음 알아보는 앱 이름. 경로 → 이름 규칙은 순수 함수 hostName으로 뺐다
    private static func hostApp(ancestors: [pid_t], table: [pid_t: Entry], cache: inout [pid_t: String?]) -> String? {
        for pid in ancestors {
            let name: String?
            if let cached = cache[pid] {
                name = cached
            } else {
                // root 프로세스(login 등)는 경로를 못 읽는다. 이름으로라도 본다
                let path = executablePath(of: pid)
                name = hostName(executablePath: path.isEmpty ? (table[pid]?.name ?? "") : path)
                cache[pid] = .some(name)
            }
            if let name { return name }
        }
        return nil
    }

    /// 실행 파일 경로로 알아보는 터미널·편집기 이름. 모르면 nil
    static func hostName(executablePath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if path.contains("/Terminal.app/") { return "Terminal" }
        if name == "tmux" || name.hasPrefix("tmux: ") { return "tmux" }
        if path.contains("/Visual Studio Code.app/") || path.contains("/Visual Studio Code - Insiders.app/")
            || path.contains("/VSCodium.app/") { return "VS Code" }
        if path.contains("/Cursor.app/") { return "Cursor" }
        if path.contains("/iTerm.app/") || path.contains("/iTerm2.app/") { return "iTerm2" }
        if path.contains("/Ghostty.app/") { return "Ghostty" }
        if path.contains("/WezTerm.app/") || name == "wezterm-gui" { return "WezTerm" }
        if path.contains("/Warp.app/") || path.contains("/WarpPreview.app/") { return "Warp" }
        if path.contains("/Claude.app/") { return desktopClaude }
        return nil
    }

    /// 훅 프로세스를 띄운 에이전트: 부모를 거슬러 올라가 처음 만나는 에이전트 프로세스의 pid와 tty.
    /// 훅은 보통 셸(`sh -c`)을 거쳐 뜨므로 몇 단계만 본다. 에이전트를 못 찾으면 tty가 있는 가장 가까운 조상이라도 준다
    static func launchingAgent(of pid: pid_t = getpid()) -> (pid: pid_t, tty: String?)? {
        var current = shortInfo(pid)?.ppid ?? 0
        var fallback: (pid: pid_t, tty: String?)?
        for _ in 0..<8 {
            guard current > 1, let entry = shortInfo(current) else { break }
            let tty = bsdInfo(current).flatMap { ttyPath($0.e_tdev) }
            if isCandidate(entry.name),
               kind(executablePath: executablePath(of: current), arguments: arguments(of: current) ?? []) != nil {
                return (current, tty)
            }
            if fallback == nil, tty != nil { fallback = (current, tty) }
            current = entry.ppid
        }
        return fallback
    }

    // MARK: - libproc

    /// 모든 프로세스에서 읽는 짧은 정보 (PROC_PIDT_SHORTBSDINFO). 긴 BSD 정보와 달리 root 프로세스(login 등)도 읽혀서
    /// 부모를 Terminal까지 거슬러 올라갈 수 있고, 두 배쯤 빠르다
    private struct Entry {
        var ppid: pid_t
        var uid: uid_t
        /// 실행 파일 이름 (16자까지)
        var name: String
    }

    /// 부모, 부모의 부모 … (launchd 직전까지)
    private static func ancestorChain(of pid: pid_t, in table: [pid_t: Entry]) -> [pid_t] {
        var chain: [pid_t] = []
        var current = table[pid]?.ppid ?? 0
        while current > 1, chain.count < 64, let entry = table[current] {
            chain.append(current)
            current = entry.ppid
        }
        return chain
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    private static func shortInfo(_ pid: pid_t) -> Entry? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Entry(ppid: pid_t(info.pbsi_ppid), uid: info.pbsi_uid, name: name)
    }

    /// tty · 시작 시각용. 내 계정 프로세스만 읽힌다
    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// e_tdev → "/dev/ttys004". 제어 터미널이 없으면(NODEV) nil
    private static func ttyPath(_ tdev: UInt32) -> String? {
        guard tdev != UInt32.max, tdev != 0 else { return nil }
        ttyLock.lock()
        defer { ttyLock.unlock() }
        if let cached = ttyNames[tdev] { return cached }
        // devname은 /dev를 훑어서 느리다 (3초마다 에이전트 수만큼 부르면 CPU 대부분이 여기). 장치 번호의 이름은 바뀌지 않으니 기억해 둔다
        guard let name = devname(dev_t(bitPattern: tdev), S_IFCHR) else { return nil }
        let text = String(cString: name)
        let path = text.isEmpty || text == "??" ? nil : "/dev/" + text
        if let path { ttyNames[tdev] = path }
        return path
    }

    private static let ttyLock = NSLock()
    nonisolated(unsafe) private static var ttyNames: [UInt32: String] = [:]

    /// 실행 인자(KERN_PROCARGS2)를 읽을 버퍼. 크기를 물으면 kern.argmax(1MB)가 나와서 매번 만들지 않고 하나를 같이 쓴다
    private static let argumentsLock = NSLock()
    nonisolated(unsafe) private static var argumentsBuffer = [UInt8]()

    /// 실행 인자 전부. 다른 계정이거나 이미 끝난 프로세스면 nil
    private static func arguments(of pid: pid_t) -> [String]? {
        argumentsLock.lock()
        defer { argumentsLock.unlock() }
        if argumentsBuffer.isEmpty {
            argumentsBuffer = [UInt8](repeating: 0, count: Int(Sysctl.read("kern.argmax", initial: Int32(1 << 20)) ?? 1 << 20))
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentsBuffer.count
        let ok = argumentsBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok, size > MemoryLayout<Int32>.size else { return nil }
        return argumentsBuffer.withUnsafeBufferPointer { parseArguments(UnsafeBufferPointer(rebasing: $0[..<size])) }
    }

    /// argc(Int32) · 실행 파일 경로 · \0 패딩 · argv[0] · … · argv[argc-1] · 환경 변수 …
    private static func parseArguments(_ buffer: UnsafeBufferPointer<UInt8>) -> [String]? {
        let size = buffer.count
        let argc = Int(UnsafeRawBufferPointer(buffer).loadUnaligned(as: Int32.self))
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<index]), as: UTF8.self))
            index += 1
        }
        return result
    }
}

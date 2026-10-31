import Darwin
import Foundation

/// 앱 하나의 사용량. 같은 앱 번들 안의 도우미 프로세스(크롬 렌더러 등)는 합치고,
/// 앱 밖 프로세스(node, python 같은 CLI)는 이름이 같으면 합친다.
struct AppUsage: Identifiable, Equatable {
    let id: String
    let name: String
    /// 아이콘을 그릴 앱 번들 경로. 앱 밖 프로세스면 nil
    let bundlePath: String?
    /// 코어 1개를 다 쓰면 1 (활성 상태 보기의 % CPU와 같은 기준)
    var cpu: Double = 0
    /// CPU가 이 앱을 돌리느라 쓴 전력 추정치 (GPU는 들어가지 않는다)
    var cpuWatts: Double = 0
    /// 활성 상태 보기의 '메모리'와 같은 값 (phys_footprint)
    var memory: UInt64 = 0
}

/// 내 계정으로 실행 중인 프로세스의 CPU 시간 · CPU 에너지 · 메모리를 앱 단위로 묶는다.
/// 다른 계정(root, _windowserver 등)의 프로세스는 권한이 없어 읽지 못한다. 한 번 훑는 데 3ms 정도.
final class AppUsageSampler {
    private struct Counters {
        var start: UInt64    // 프로세스 시작 시각: pid가 재사용됐는지 가린다
        var cpuTime: UInt64  // mach 시간 단위
        var energy: UInt64   // nJ
    }

    private struct Group {
        var start: UInt64
        var key: String
        var name: String
        var bundlePath: String?
    }

    private var previous: [pid_t: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var groups: [pid_t: Group] = [:]
    /// 프로세스가 exec로 다른 프로그램이 되면 pid와 시작 시각이 그대로라 이름이 안 바뀐다. 가끔 묶음을 새로 계산한다
    private var samplesSinceRegroup = 0
    private static let regroupInterval = 30
    private var bundleNames: [String: String] = [:]
    /// 실행 인자(KERN_PROCARGS2)를 읽을 버퍼. 처음 필요할 때 kern.argmax 크기로 만든다.
    private lazy var arguments = [UInt8](repeating: 0, count: Int(Sysctl.read("kern.argmax", initial: Int32(1 << 20)) ?? 1 << 20))
    private let nanosecondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
    }

    /// 처음 한 번(또는 오래 쉬었다가 다시 잴 때)은 기준값만 잡고 nil
    func sample() -> [AppUsage]? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - previousTime) / 1e9
        // 너무 오래된 기준값으로 재면 긴 시간의 평균이 되어버려서 버린다
        let hasBaseline = previousTime > 0 && elapsed > 0 && elapsed < 10
        var current: [pid_t: Counters] = [:]
        var apps: [String: AppUsage] = [:]
        samplesSinceRegroup += 1
        if samplesSinceRegroup >= Self.regroupInterval {
            samplesSinceRegroup = 0
            groups.removeAll()
        }

        for pid in Self.allPIDs() {
            guard let info = Self.usage(of: pid) else { continue }
            let counters = Counters(start: info.ri_proc_start_abstime,
                                    cpuTime: info.ri_user_time + info.ri_system_time,
                                    energy: info.ri_energy_nj)
            current[pid] = counters
            let group = group(of: pid, start: counters.start)
            var app = apps[group.key] ?? AppUsage(id: group.key, name: group.name, bundlePath: group.bundlePath)
            app.memory += info.ri_phys_footprint
            if hasBaseline, let old = previous[pid], old.start == counters.start,
               old.cpuTime <= counters.cpuTime, old.energy <= counters.energy {
                app.cpu += Double(counters.cpuTime - old.cpuTime) * nanosecondsPerTick / 1e9 / elapsed
                app.cpuWatts += Double(counters.energy - old.energy) / 1e9 / elapsed
            }
            apps[group.key] = app
        }

        previous = current
        previousTime = now
        groups = groups.filter { current[$0.key] != nil }
        return hasBaseline ? Array(apps.values) : nil
    }

    private func group(of pid: pid_t, start: UInt64) -> Group {
        if let cached = groups[pid], cached.start == start { return cached }
        let path = Self.executablePath(of: pid)
        let group: Group
        if let bundle = Self.outermostAppBundle(in: path) {
            group = Group(start: start, key: bundle, name: bundleName(bundle), bundlePath: bundle)
        } else {
            let name = processName(of: pid, path: path)
            group = Group(start: start, key: "process:" + name, name: name, bundlePath: nil)
        }
        groups[pid] = group
        return group
    }

    /// Finder에 보이는 이름 (예: Terminal.app → 터미널)
    private func bundleName(_ path: String) -> String {
        if let cached = bundleNames[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        bundleNames[path] = name
        return name
    }

    /// 앱 밖 프로세스의 이름. argv[0]의 첫 단어를 쓰고("tool --serve" → tool),
    /// 그것도 버전 번호뿐이면(…/tool/versions/2.1.3) 위 폴더에서 이름을 찾는다.
    private func processName(of pid: pid_t, path: String) -> String {
        let candidates = [commandName(of: pid).map { String($0.prefix { $0 != " " }) }, (path as NSString).lastPathComponent]
        if let name = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty && !Self.isVersion($0) }) {
            return name
        }
        let skipped: Set<String> = ["versions", "bin", "current", "libexec"]
        let folder = path.split(separator: "/").map(String.init).reversed().dropFirst()
            .first { !skipped.contains($0) && !Self.isVersion($0) }
        return folder ?? "pid \(pid)"
    }

    private static func isVersion(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// argv[0]의 마지막 부분. 실행 파일 이름이 버전 번호인 CLI(…/versions/2.1.3 등)도 부르는 이름으로 나온다.
    private func commandName(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = arguments.count
        let ok = arguments.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok, size > MemoryLayout<Int32>.size,
              arguments.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) > 0 else { return nil }
        // argc(Int32) · 실행 파일 경로 · \0 패딩 · argv[0] · …
        var index = MemoryLayout<Int32>.size
        while index < size, arguments[index] != 0 { index += 1 }
        while index < size, arguments[index] == 0 { index += 1 }
        let start = index
        while index < size, arguments[index] != 0 { index += 1 }
        guard index > start, let argument = String(bytes: arguments[start..<index], encoding: .utf8) else { return nil }
        let name = (argument as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name  // 로그인 셸은 "-zsh"
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // 그 사이 새 프로세스가 생겨도 들어가도록 여유를 둔다
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    /// 다른 계정의 프로세스면 nil (EPERM)
    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    /// 경로 안의 가장 바깥 .app. 앱 안에 든 도우미 앱(…/Google Chrome.app/…/Google Chrome Helper.app)은 바깥 앱으로 묶는다.
    private static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
    }
}

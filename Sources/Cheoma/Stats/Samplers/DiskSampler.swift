import Foundation

struct DiskStats: Equatable {
    var rate: ThroughputRate?   // in = 읽기, out = 쓰기
    var free: Int64
    var total: Int64

    var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

final class DiskSampler {
    private var rate = CounterRate<UInt64>()
    /// 레지스트리 번호 → 디스크 이미지(DMG)인지. DMG를 읽으면 그 파일이 있는 실제 디스크도 같이 읽혀서 두 번 세게 된다
    private var isDiskImage: [UInt64: Bool] = [:]
    /// 여유 공간 계산(정리 가능한 공간 포함)은 한 번에 수십 ms가 걸려서 1분에 한 번만 한다
    private var capacity: (free: Int64, total: Int64, time: TimeInterval)?
    private static let capacityInterval: TimeInterval = 60

    func sample() -> DiskStats? {
        let now = MonotonicClock.now
        if capacity.map({ now - $0.time > Self.capacityInterval }) ?? true, let fresh = Self.readCapacity() {
            capacity = (fresh.free, fresh.total, now)
        }
        guard let capacity else { return nil }
        let rate = rate.update(readCounters(), now: now)
        return DiskStats(rate: rate, free: capacity.free, total: capacity.total)
    }

    /// 장치마다 (읽은 바이트, 쓴 바이트)
    private func readCounters() -> CounterRate<UInt64>.Counters {
        var counters: CounterRate<UInt64>.Counters = [:]
        var seen = Set<UInt64>()
        IORegistry.forEach(matching: "IOBlockStorageDriver") { service in
            guard let id = IORegistry.entryID(of: service) else { return }
            seen.insert(id)
            let diskImage = isDiskImage[id] ?? {
                let found = IORegistry.parentClassName(of: service)?.contains("DiskImage") ?? false
                isDiskImage[id] = found
                return found
            }()
            guard !diskImage, let stats = IORegistry.property("Statistics", of: service) as? [String: Any] else { return }
            counters[id] = (UInt64(max(stats.int64("Bytes (Read)") ?? 0, 0)), UInt64(max(stats.int64("Bytes (Write)") ?? 0, 0)))
        }
        // 빠진 장치는 잊는다
        if isDiskImage.count > seen.count { isDiskImage = isDiskImage.filter { seen.contains($0.key) } }
        return counters
    }

    /// Finder와 같은 기준(정리 가능한 공간 포함)의 여유 공간
    private static func readCapacity() -> (free: Int64, total: Int64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity,
              let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return (free, Int64(total))
    }
}

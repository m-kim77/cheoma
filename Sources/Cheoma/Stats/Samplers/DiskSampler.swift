import Foundation

struct DiskStats: Equatable {
    var rate: ThroughputRate?   // in = 읽기, out = 쓰기
    var free: Int64
    var total: Int64

    var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

final class DiskSampler {
    private var previous: (read: UInt64, written: UInt64, time: Date)?
    /// 여유 공간 계산(정리 가능한 공간 포함)은 한 번에 수십 ms가 걸려서 1분에 한 번만 한다
    private var capacity: (free: Int64, total: Int64, time: Date)?
    private static let capacityInterval: TimeInterval = 60

    func sample() -> DiskStats? {
        if capacity == nil || Date().timeIntervalSince(capacity!.time) > Self.capacityInterval,
           let fresh = Self.readCapacity() {
            capacity = (fresh.free, fresh.total, Date())
        }
        guard let capacity else { return nil }
        let (read, written) = Self.readCounters()
        let now = Date()
        var rate: ThroughputRate?
        if let previous {
            let dt = now.timeIntervalSince(previous.time)
            if dt > 0 {
                rate = ThroughputRate(inPerSecond: Double(read &- previous.read) / dt,
                                      outPerSecond: Double(written &- previous.written) / dt)
            }
        }
        previous = (read, written, now)
        return DiskStats(rate: rate, free: capacity.free, total: capacity.total)
    }

    private static func readCounters() -> (UInt64, UInt64) {
        var read: UInt64 = 0
        var written: UInt64 = 0
        for value in IORegistry.property("Statistics", matching: "IOBlockStorageDriver") {
            guard let stats = value as? [String: Any] else { continue }
            read += UInt64(stats.int64("Bytes (Read)") ?? 0)
            written += UInt64(stats.int64("Bytes (Write)") ?? 0)
        }
        return (read, written)
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

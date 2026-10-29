import Darwin
import Foundation

struct ThroughputRate: Equatable {
    var inPerSecond: Double
    var outPerSecond: Double
}

/// 물리 인터페이스(en*: Wi-Fi, 이더넷)의 누적 바이트 차이로 속도 계산.
/// VPN(utun) 등을 같이 세면 같은 트래픽이 두 번 잡히므로 제외한다.
final class NetworkSampler {
    private var previous: (rx: UInt64, tx: UInt64, time: Date)?
    /// 인터페이스 번호 → 물리 인터페이스(en*)인지. 이름을 매번 찾지 않도록 기억해 둔다.
    private var isPhysical: [UInt16: Bool] = [:]
    private var cacheTime = Date.distantPast

    func sample() -> ThroughputRate? {
        // 인터페이스가 새로 생기거나 없어질 수 있으니 가끔 비운다
        if Date().timeIntervalSince(cacheTime) > 60 {
            isPhysical.removeAll()
            cacheTime = Date()
        }
        guard let (rx, tx) = readCounters() else { return nil }
        let now = Date()
        defer { previous = (rx, tx, now) }
        guard let previous else { return nil }
        let dt = now.timeIntervalSince(previous.time)
        guard dt > 0 else { return nil }
        return ThroughputRate(inPerSecond: Double(rx &- previous.rx) / dt,
                              outPerSecond: Double(tx &- previous.tx) / dt)
    }

    private func readCounters() -> (UInt64, UInt64)? {
        // if_data는 32비트라 4GB에서 넘치므로 64비트 카운터가 있는 IFLIST2 사용
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += Int(header.ifm_msglen) }
                guard header.ifm_msglen > 0 else { offset = length; return }
                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }

                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_flags & IFF_LOOPBACK == 0 else { continue }
                let physical = isPhysical[message.ifm_index] ?? {
                    let found = if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil
                        && String(cString: nameBuffer).hasPrefix("en")
                    isPhysical[message.ifm_index] = found
                    return found
                }()
                guard physical else { continue }
                rx += message.ifm_data.ifi_ibytes
                tx += message.ifm_data.ifi_obytes
            }
        }
        return (rx, tx)
    }
}

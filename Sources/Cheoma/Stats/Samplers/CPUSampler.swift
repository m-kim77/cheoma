import Darwin

/// 코어별 tick 누적값의 차이로 사용률 계산
final class CPUSampler {
    private let host = mach_host_self()
    private var previous: [[UInt32]] = []

    func sample() -> (total: Double, cores: [Double])? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let current = (0..<Int(coreCount)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var busySum: UInt64 = 0
        var allSum: UInt64 = 0
        var cores: [Double] = []
        for (now, before) in zip(current, previous) {
            let delta = zip(now, before).map { UInt64($0 &- $1) }
            let all = delta.reduce(0, +)
            let busy = all - delta[Int(CPU_STATE_IDLE)]
            busySum += busy
            allSum += all
            cores.append(all > 0 ? Double(busy) / Double(all) : 0)
        }
        return (allSum > 0 ? Double(busySum) / Double(allSum) : 0, cores)
    }
}

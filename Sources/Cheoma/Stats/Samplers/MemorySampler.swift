import Darwin

struct MemoryStats: Equatable {
    enum Pressure { case normal, warning, critical }

    var used: UInt64
    var total: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var pressure: Pressure

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// 활성 상태 보기의 "사용된 메모리" 기준: 앱 메모리 + 와이어드 + 압축
final class MemorySampler {
    private let host = mach_host_self()
    private let total = Sysctl.read("hw.memsize", initial: UInt64(0)) ?? 0

    func sample() -> MemoryStats? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(vm.internal_page_count - vm.purgeable_count) * page
        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page
        let swap = Sysctl.read("vm.swapusage", initial: xsw_usage())?.xsu_used ?? 0

        let pressure: MemoryStats.Pressure = switch Sysctl.read("kern.memorystatus_vm_pressure_level", initial: Int32(0)) {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
        return MemoryStats(used: app + wired + compressed, total: total,
                           compressed: compressed, swapUsed: swap, pressure: pressure)
    }
}

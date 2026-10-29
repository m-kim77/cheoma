import Foundation
import CheomaShared

struct ThermalStats: Equatable {
    struct Fan: Equatable {
        var rpm: Double
        var minimum: Double
        var maximum: Double

        var fraction: Double { maximum > minimum ? (rpm - minimum) / (maximum - minimum) : 0 }
    }

    var cpu: Double?
    var cpuMax: Double?
    var gpu: Double?
    var gpuMax: Double?
    var ssd: Double?
    var battery: Double?
    var fans: [Fan] = []
}

/// SMC 온도/팬 센서. 키 이름은 Apple Silicon에서 통용되는 접두어 규칙을 따른다:
/// Tp* CPU 코어, Tg* GPU, TH0x SSD, TB*T 배터리, F{n}Ac 팬 실제 RPM.
final class ThermalSampler {
    private let smc: SMC?
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    private let ssdKeys: [String]
    private let batteryKeys: [String]
    /// 팬 최소/최대 RPM은 바뀌지 않으므로 시작할 때 한 번만 읽는다
    private let fanLimits: [(minimum: Double, maximum: Double)]

    /// GPU 센서는 80개가 넘고 값이 거의 같아서, 매초 전부 읽지 않고 고르게 몇 개만 읽는다
    private static let gpuSensorLimit = 8

    init() {
        let smc = SMC()
        self.smc = smc
        // 센서가 연결되지 않은 키는 0이나 터무니없는 값을 주므로 처음에 한 번 걸러낸다
        let keys = (smc?.allKeys() ?? []).filter { key in
            key.hasPrefix("T") && smc?.float(key).map { Self.isPlausible(Double($0)) } == true
        }
        // CPU는 가장 뜨거운 코어를 놓치지 않도록 전부 읽는다
        cpuKeys = keys.filter { $0.hasPrefix("Tp") }
        gpuKeys = Self.evenlySpaced(keys.filter { $0.hasPrefix("Tg") }, limit: Self.gpuSensorLimit)
        ssdKeys = keys.filter { $0 == "TH0x" }
        batteryKeys = keys.filter { $0.hasPrefix("TB") && $0.hasSuffix("T") }
        fanLimits = (0..<8).map { index in
            (Double(smc?.float("F\(index)Mn") ?? 0), Double(smc?.float("F\(index)Mx") ?? 0))
        }
    }

    private static func evenlySpaced(_ keys: [String], limit: Int) -> [String] {
        guard keys.count > limit else { return keys }
        let step = Double(keys.count) / Double(limit)
        return (0..<limit).map { keys[Int(Double($0) * step)] }
    }

    private static func isPlausible(_ celsius: Double) -> Bool { celsius > 5 && celsius < 130 }

    func sample() -> ThermalStats? {
        guard let smc else { return nil }
        let cpu = readings(cpuKeys, smc)
        let gpu = readings(gpuKeys, smc)
        return ThermalStats(
            cpu: Self.average(cpu), cpuMax: cpu.max(),
            gpu: Self.average(gpu), gpuMax: gpu.max(),
            ssd: Self.average(readings(ssdKeys, smc)),
            battery: Self.average(readings(batteryKeys, smc)),
            fans: fans(smc)
        )
    }

    /// 팬 RPM만 읽는다 (키 몇 개라 온도 전체보다 훨씬 싸다)
    func sampleFans() -> [ThermalStats.Fan] {
        smc.map(fans) ?? []
    }

    /// 매번 읽는 온도 센서 수 (측정용)
    var sensorCount: Int { cpuKeys.count + gpuKeys.count + ssdKeys.count + batteryKeys.count }

    private func readings(_ keys: [String], _ smc: SMC) -> [Double] {
        keys.compactMap { smc.float($0).map(Double.init) }.filter(Self.isPlausible)
    }

    private func fans(_ smc: SMC) -> [ThermalStats.Fan] {
        var result: [ThermalStats.Fan] = []
        for index in 0..<8 {
            guard let rpm = smc.float("F\(index)Ac") else { break }
            result.append(ThermalStats.Fan(rpm: Double(rpm),
                                           minimum: fanLimits[index].minimum,
                                           maximum: fanLimits[index].maximum))
        }
        return result
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

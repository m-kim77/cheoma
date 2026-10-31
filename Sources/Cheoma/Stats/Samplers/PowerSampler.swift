import Foundation
import CheomaShared
import IOKit
import IOKit.ps

struct PowerStats: Equatable {
    var systemWatts: Double?          // 기기 전체 소비 전력
    var components: IOReportEnergy.Reading?
    var adapterInputWatts: Double?    // 어댑터에서 들어오는 전력
    var adapterRatedWatts: Int?       // 어댑터 정격 (예: 140W)
    var batteryWatts: Double          // + 충전 / - 방전
    var batteryLevel: Int
    var isPluggedIn: Bool
    var isCharging: Bool
    var health: Double?               // 설계 용량 대비 현재 최대 용량
    var cycleCount: Int?
    var temperature: Double?          // °C
    var minutesRemaining: Int?
}

/// 배터리 컨트롤러(AppleSmartBattery) + SMC 실시간 전력 + IOReport 구성요소별 전력
final class PowerSampler {
    private let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    private let energy = IOReportEnergy()
    private let smc = SMC()
    /// 배터리 레지스트리는 약 1분마다만 바뀌는데 통째로 읽는 데 몇 ms가 걸려서 10초마다만 읽는다.
    /// 어댑터 정격도 그때 같이 읽는다 (IPC라 매번 부르지 않는다). 실시간 전력은 SMC에서 매번 읽고,
    /// 충전기를 꽂거나 빼면 powerSourceChanged()로 바로 다시 읽는다
    private var batteryProperties: (values: [String: Any], adapterWatts: Int?, time: TimeInterval)?
    private static let batteryRefreshInterval: TimeInterval = 10

    /// 충전기 연결·배터리 상태가 바뀌었을 때 (SystemEventMonitor가 알려 준다)
    func powerSourceChanged() {
        batteryProperties = nil
    }

    deinit {
        if battery != 0 { IOObjectRelease(battery) }
    }

    /// 구성요소별 전력(IOReport)은 한 번 읽는 데 4ms쯤 걸려서 readEnergy일 때만 읽고, 아니면 직전 값을 쓴다.
    /// 에너지 누적값의 차이라 읽는 간격이 길어도 그 사이 평균은 정확하다.
    private var lastComponents: IOReportEnergy.Reading?

    func sample(readEnergy: Bool = true) -> PowerStats? {
        if readEnergy, let energy { lastComponents = energy.sample() }
        let components = lastComponents
        let now = MonotonicClock.now
        if battery != 0, batteryProperties.map({ now - $0.time > Self.batteryRefreshInterval }) ?? true,
           let fresh = IORegistry.properties(of: battery) {
            let pluggedIn = fresh["ExternalConnected"] as? Bool ?? false
            let adapter = pluggedIn
                ? (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?.int64(kIOPSPowerAdapterWattsKey).map(Int.init)
                : nil
            batteryProperties = (fresh, adapter, now)
        }
        guard let props = batteryProperties?.values else { return nil }

        let voltage = props.double("Voltage") ?? 0       // mV
        let amperage = props.int64("Amperage") ?? 0      // mA, 방전 시 음수
        let batteryWatts = voltage * Double(amperage) / 1_000_000
        let isPluggedIn = props["ExternalConnected"] as? Bool ?? false

        // 실시간 값은 SMC(PSTR: 시스템 전체, PDTR: 어댑터 입력), 없으면 1분 간격 레지스트리 값으로 대체
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        var systemWatts = smc?.float("PSTR").map(Double.init) ?? telemetry?.double("SystemLoad").map { $0 / 1000 }
        if systemWatts == nil || systemWatts == 0, !isPluggedIn, batteryWatts < 0 {
            systemWatts = -batteryWatts
        }
        let adapterInput = isPluggedIn
            ? smc?.float("PDTR").map(Double.init) ?? telemetry?.double("SystemPowerIn").map { $0 / 1000 }
            : nil
        let adapterRated = isPluggedIn ? batteryProperties?.adapterWatts : nil

        let health: Double? = {
            guard let raw = props.double("AppleRawMaxCapacity"), let design = props.double("DesignCapacity"),
                  design > 0 else { return nil }
            return raw / design
        }()
        let estimate = IOPSGetTimeRemainingEstimate()

        return PowerStats(
            systemWatts: systemWatts,
            components: components,
            adapterInputWatts: adapterInput,
            adapterRatedWatts: adapterRated,
            batteryWatts: batteryWatts,
            batteryLevel: Int(props.int64("CurrentCapacity") ?? 0),
            isPluggedIn: isPluggedIn,
            isCharging: props["IsCharging"] as? Bool ?? false,
            health: health,
            cycleCount: props.int64("CycleCount").map(Int.init),
            temperature: props.double("Temperature").map { $0 / 100 },
            minutesRemaining: estimate > 0 ? Int(estimate / 60) : nil
        )
    }
}

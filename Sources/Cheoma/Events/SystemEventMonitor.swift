import AppKit
import IOKit.ps

struct BatteryState: Equatable {
    var level: Int
    var isPluggedIn: Bool
    var isCharging: Bool
}

/// 공개 API로 감지 가능한 시스템 이벤트들 (충전기 연결/해제, 잠금 해제, 발열, 메모리 압력)
@MainActor
final class SystemEventMonitor {
    var onBatteryChange: ((BatteryState, BatteryState?) -> Void)?
    var onScreenUnlocked: (() -> Void)?
    var onThermalStateChange: ((ProcessInfo.ThermalState) -> Void)?
    var onMemoryPressure: ((DispatchSource.MemoryPressureEvent) -> Void)?

    private var battery: BatteryState?
    private var powerSource: CFRunLoopSource?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshBattery() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        refreshBattery()

        // Touch ID / 암호로 잠금 해제했을 때
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreenUnlocked?() }
        })

        // 발열 때문에 시스템이 성능을 낮출 때
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onThermalStateChange?(ProcessInfo.processInfo.thermalState) }
        })

        // 메모리 압력이 경고·위험으로 오를 때 (활성 상태 보기의 메모리 압력 노랑·빨강)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.onMemoryPressure?(event)
            }
        }
        source.resume()
        memoryPressure = source
    }

    private func refreshBattery() {
        guard let new = Self.readBattery(), new != battery else { return }
        let old = battery
        battery = new
        onBatteryChange?(new, old)
    }

    private static func readBattery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryState(level: max > 0 ? current * 100 / max : current,
                                isPluggedIn: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}

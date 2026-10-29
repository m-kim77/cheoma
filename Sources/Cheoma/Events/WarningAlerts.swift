import SwiftUI

/// 과열 · 메모리 부족 · 배터리 부족을 노치로 알린다. 시스템이 알려주는 상태 변화만 쓰고 따로 측정하지 않는다.
/// 같은 종류는 10분에 한 번만 띄우되, 더 심해지면 바로 띄운다. `⌄` 우클릭 메뉴에서 끌 수 있다.
@MainActor
final class WarningAlerts {
    private static let defaultsKey = "warningAlerts"
    private static let cooldown: TimeInterval = 600

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    var onAlert: ((NotchAlert) -> Void)?

    private enum Kind { case thermal, memory, battery }
    /// 종류별로 마지막에 띄운 시각과 심각도 (1: 경고, 2: 위험)
    private var lastShown: [Kind: (date: Date, level: Int)] = [:]

    func thermalStateChanged(to state: ProcessInfo.ThermalState) {
        post(.thermal, level: state == .critical ? 2 : 1, Self.thermal(state))
    }

    func memoryPressureChanged(to event: DispatchSource.MemoryPressureEvent) {
        post(.memory, level: event.contains(.critical) ? 2 : 1, Self.memory(event))
    }

    /// 배터리로 쓰는 중에 20%, 10% 아래로 내려갈 때
    func batteryChanged(_ new: BatteryState, from old: BatteryState) {
        guard !new.isPluggedIn, let threshold = [10, 20].first(where: { new.level <= $0 && old.level > $0 }) else { return }
        post(.battery, level: threshold == 10 ? 2 : 1, Self.battery(level: new.level))
    }

    private func post(_ kind: Kind, level: Int, _ alert: NotchAlert?) {
        guard let alert, Self.isEnabled else { return }
        let now = Date()
        if let last = lastShown[kind], now.timeIntervalSince(last.date) < Self.cooldown, level <= last.level { return }
        lastShown[kind] = (now, level)
        onAlert?(alert)
    }

    // MARK: - 알림 모양 (미리보기에서도 쓴다)

    static func thermal(_ state: ProcessInfo.ThermalState) -> NotchAlert? {
        switch state {
        case .serious: NotchAlert(symbol: "thermometer.high", tint: .orange, text: "발열 높음")
        case .critical: NotchAlert(symbol: "thermometer.high", tint: .red, text: "과열 주의")
        default: nil
        }
    }

    static func memory(_ event: DispatchSource.MemoryPressureEvent) -> NotchAlert? {
        if event.contains(.critical) { return NotchAlert(symbol: "memorychip", tint: .red, text: "메모리 매우 부족") }
        if event.contains(.warning) { return NotchAlert(symbol: "memorychip", tint: .yellow, text: "메모리 부족") }
        return nil
    }

    static func battery(level: Int) -> NotchAlert {
        NotchAlert(symbol: level <= 10 ? "battery.0percent" : "battery.25percent",
                   tint: level <= 10 ? .red : .orange, text: "배터리 \(level)%")
    }
}

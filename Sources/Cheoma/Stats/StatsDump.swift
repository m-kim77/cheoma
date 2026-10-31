import Foundation

/// `Cheoma --stats`: UI 없이 3초간 측정값을 출력 (센서 값 검증용)
@MainActor
enum StatsDump {
    static func run() {
        let store = StatsStore(savesHistory: false)
        store.start()
        // 대시보드가 열린 것처럼 매초 재야 3초 안에 구성요소별 전력(2초 간격)까지 나온다
        store.isDashboardOpen = true
        var remaining = 3
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                print(describe(store.snapshot))
                remaining -= 1
                if remaining == 0 { exit(0) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }

    private static func describe(_ s: StatsSnapshot) -> String {
        var lines = ["---"]
        lines.append("CPU \(Format.percent(s.cpu)) (\(s.cores.count) cores)  GPU \(Format.percent(s.gpu))")
        if let m = s.memory {
            lines.append("MEM \(Format.memory(m.used)) / \(Format.memory(m.total)) compressed \(Format.memory(m.compressed)) swap \(Format.memory(m.swapUsed)) \(m.pressure)")
        }
        lines.append("NET ↓\(Format.rate(s.network?.inPerSecond)) ↑\(Format.rate(s.network?.outPerSecond))")
        if let d = s.disk {
            lines.append("DISK R \(Format.rate(d.rate?.inPerSecond)) W \(Format.rate(d.rate?.outPerSecond)) free \(Format.storage(d.free)) / \(Format.storage(d.total))")
        }
        if let p = s.power {
            let c = p.components
            lines.append("POWER system \(Format.watts(p.systemWatts)) cpu \(Format.watts(c?.cpu)) gpu \(Format.watts(c?.gpu)) ane \(Format.watts(c?.ane)) dram \(Format.watts(c?.dram)) disp \(Format.watts(c?.display))")
            lines.append("BATT \(p.batteryLevel)% plugged \(p.isPluggedIn) charging \(p.isCharging) battery \(Format.watts(p.batteryWatts)) adapter \(p.adapterRatedWatts.map { "\($0)W" } ?? "-") in \(Format.watts(p.adapterInputWatts)) health \(Format.percent(p.health)) cycles \(p.cycleCount ?? -1) temp \(p.temperature ?? -1)")
        }
        if let t = s.thermal {
            let fans = t.fans.map { "\(Int($0.rpm))/\(Int($0.maximum))rpm" }.joined(separator: " ")
            lines.append("TEMP cpu \(t.cpu ?? -1) (max \(t.cpuMax ?? -1)) gpu \(t.gpu ?? -1) ssd \(t.ssd ?? -1) batt \(t.battery ?? -1) fans \(fans)")
        }
        lines.append("DISPLAY \(s.refreshRate.map { "\($0)Hz" } ?? "-")")
        return lines.joined(separator: "\n")
    }
}

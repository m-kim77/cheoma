import AppKit
import IOKit.ps
import CheomaShared
import SwiftUI

/// `Cheoma --bench [초]`: 상황마다 이 앱이 CPU를 얼마나 쓰는지 잰다 (개발용, 최적화 전후 비교).
/// 대시보드는 1% 불투명도로 띄우고 마우스도 통과시켜서 화면에는 사실상 보이지 않는다. 팬은 건드리지 않는다.
@MainActor
enum Benchmark {
    /// only가 있으면 그 탭만 잰다 (프로파일러를 붙여서 볼 때)
    static func run(seconds: TimeInterval, only: DashboardTab? = nil) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let savedTab = UserDefaults.standard.object(forKey: "dashboardTab")
        defer { UserDefaults.standard.set(savedTab, forKey: "dashboardTab") }

        if only == nil { measureSamplers() }

        let stats = StatsStore()
        let fans = FanController()
        let model = NotchModel()
        stats.start()
        print("== 상황별 CPU 사용률 (\(Int(seconds))초씩)")
        if only == nil { measure("대시보드 닫힘", seconds: seconds) }

        let size = CGSize(width: NotchModel.maxOpenSize.width + 60, height: NotchModel.maxOpenSize.height + 40)
        let panel = OverlayPanel(size: size)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.01
        panel.contentView = FirstMouseHostingView(rootView: NotchView(model: model, stats: stats, fans: fans, agents: AgentStore.preview()))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height))
        }
        panel.orderFrontRegardless()

        for tab in DashboardTab.allCases where only == nil || tab == only {
            model.previewOpen(tab)
            stats.isDashboardOpen = true
            stats.showsApps = tab == .apps
            stats.showsFans = tab == .fans || tab == .thermal
            // 열리는 애니메이션이 끝난 뒤부터 잰다
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            measure("\(tab.rawValue) 탭 열림", seconds: seconds)
        }
        panel.orderOut(nil)
    }

    private static func measure(_ name: String, seconds: TimeInterval) {
        let cpuStart = cpuTime()
        let wallStart = Date()
        let drawsStart = TimeGraph.drawCount
        RunLoop.main.run(until: wallStart.addingTimeInterval(seconds))
        let elapsed = Date().timeIntervalSince(wallStart)
        let percent = (cpuTime() - cpuStart) / elapsed * 100
        let draws = Double(TimeGraph.drawCount - drawsStart) / elapsed
        print(name.padding(toLength: 14, withPad: " ", startingAt: 0)
              + String(format: "%6.2f%%   그래프 %5.1f번/초", percent, draws))
    }

    /// 이 프로세스가 지금까지 쓴 CPU 시간 (모든 스레드, 초)
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// 센서마다 한 번 읽는 데 걸리는 시간
    private static func measureSamplers() {
        print("== 센서 한 번 읽기 (20번 평균)")
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let gpu = GPUSampler()
        let network = NetworkSampler()
        let disk = DiskSampler()
        let power = PowerSampler()
        let thermal = ThermalSampler()
        let apps = AppUsageSampler()
        time("CPU") { _ = cpu.sample() }
        time("메모리") { _ = memory.sample() }
        time("GPU") { _ = gpu.sample() }
        time("네트워크") { _ = network.sample() }
        time("디스크") { _ = disk.sample() }
        time("전력") { _ = power.sample() }
        let energy = IOReportEnergy()
        let smc = SMC()
        time("  └ IOReport") { _ = energy?.sample() }
        time("  └ SMC PSTR·PDTR") { _ = smc?.float("PSTR"); _ = smc?.float("PDTR") }
        time("  └ 어댑터 정보") { _ = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() }
        time("  └ 남은 시간 추정") { _ = IOPSGetTimeRemainingEstimate() }
        time("온도 전체 (\(thermal.sensorCount)개)") { _ = thermal.sample() }
        time("팬 RPM만") { _ = thermal.sampleFans() }
        time("앱별 사용량") { _ = apps.sample() }
    }

    private static func time(_ name: String, _ body: () -> Void) {
        body()  // 처음 한 번은 캐시를 채우느라 느릴 수 있어서 빼고 잰다
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<20 { body() }
        let milliseconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 20 / 1e6
        print(name.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: "%7.3f ms", milliseconds))
    }
}

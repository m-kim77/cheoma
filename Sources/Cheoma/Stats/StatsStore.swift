import AppKit

struct StatsSnapshot: Equatable {
    var cpu: Double?
    var cores: [Double] = []
    var gpu: Double?
    var memory: MemoryStats?
    var network: ThroughputRate?
    var disk: DiskStats?
    var power: PowerStats?
    var thermal: ThermalStats?
    var refreshRate: Int?
    /// 앱 탭을 볼 때만 채운다
    var apps: [AppUsage]?
}

/// 1초마다 모든 센서를 읽는다. 읽기 자체는 1ms 안팎이라 상시 돌려도 부담이 거의 없다.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var snapshot = StatsSnapshot()
    @Published private(set) var history = StatsHistory()

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let power = PowerSampler()
    private let thermal = ThermalSampler()
    private let appUsage = AppUsageSampler()
    private var timer: Timer?
    private var saveTimer: Timer?
    private var tickCount = 0
    /// 노치 대시보드가 열려 있을 때만 1초마다, 닫혀 있으면 2초마다 측정한다 (대기 중 CPU 절약)
    var isDashboardOpen = false {
        didSet { if isDashboardOpen && !oldValue { tick() } }
    }
    /// 온도는 천천히 변하고 센서 35개를 읽는 데 4~6ms가 걸려서, 열려 있으면 2초·닫혀 있으면 4초마다만 읽는다
    private var lastThermal: ThermalStats?
    /// 온도·팬 탭을 보고 있으면 팬이 목표 속도로 따라가는 게 바로 보이도록 팬 RPM만 매초 따로 읽는다 (키 몇 개라 싸다)
    var showsFans = false
    /// 앱별 사용량은 앱 탭을 보고 있을 때만 잰다
    var showsApps = false {
        didSet {
            guard showsApps != oldValue else { return }
            lastApps = nil
            // 기준값을 미리 잡아두면 다음 측정부터 바로 값이 나온다
            if showsApps { _ = appUsage.sample() }
        }
    }
    private var lastApps: [AppUsage]?

    private static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cheoma/history.plist")

    func start() {
        guard timer == nil else { return }
        loadHistory()
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        timer.tolerance = 0.2
        // 메뉴가 열려 있는 동안에도 갱신되도록 common 모드
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 갑자기 꺼져도 최대 5분치만 잃도록 주기적으로 저장
        let saveTimer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
        saveTimer.tolerance = 30
        RunLoop.main.add(saveTimer, forMode: .common)
        self.saveTimer = saveTimer
    }

    /// 앱을 끌 때는 synchronously로 저장을 마치고 끝낸다
    func saveHistory(synchronously: Bool = false) {
        let history = self.history
        let url = Self.historyURL
        let write: @Sendable () -> Void = {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(history) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if synchronously { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              var saved = try? PropertyListDecoder().decode(StatsHistory.self, from: data) else { return }
        saved.prune(now: Date().timeIntervalSinceReferenceDate)
        saved.discardImpossibleValues()
        history = saved
    }

    private func timerFired() {
        tickCount += 1
        guard isDashboardOpen || tickCount % 2 == 0 else { return }
        tick()
    }

    private func tick() {
        let cpuSample = cpu.sample()
        var s = StatsSnapshot()
        s.cpu = cpuSample?.total
        s.cores = cpuSample?.cores ?? []
        s.gpu = gpu.sample()
        s.memory = memory.sample()
        s.network = network.sample()
        s.disk = disk.sample()
        // 비싼 센서(온도 35개, 구성요소별 전력)는 열려 있으면 2초, 닫혀 있으면 4초마다만 읽는다
        let slowTick = lastThermal == nil || tickCount % (isDashboardOpen ? 2 : 4) == 0
        s.power = power.sample(readEnergy: slowTick)
        if slowTick {
            lastThermal = thermal.sample()
        } else if showsFans, var current = lastThermal {
            current.fans = thermal.sampleFans()
            lastThermal = current
        }
        s.thermal = lastThermal
        // 순위가 너무 자주 뒤바뀌지 않도록 2초마다 잰다
        if showsApps {
            if lastApps == nil || tickCount % 2 == 0 { lastApps = appUsage.sample() ?? lastApps }
            s.apps = lastApps
        }
        s.refreshRate = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
        snapshot = s
        history.append(s, at: Date().timeIntervalSinceReferenceDate)
    }

    #if DEBUG
    /// 미리보기 렌더링용: 지난 24시간치 가짜 기록을 채운다
    func fillSampleHistory() {
        let now = Date().timeIntervalSinceReferenceDate
        var history = StatsHistory()
        for second in stride(from: 86_400.0, to: 0, by: -1) {
            let t = now - second
            let wave = (sin(t / 37) + 1) / 2
            let burst = sin(t / 11) > 0.92 ? 0.5 : 0
            history.record(.cpu, min(0.08 + wave * 0.3 + burst, 1), at: t)
            history.record(.gpu, min(0.2 + (sin(t / 23) + 1) * 0.15, 1), at: t)
            history.record(.systemPower, 24 + wave * 18 + burst * 40, at: t)
            history.record(.cpuPower, 3 + wave * 8 + burst * 25, at: t)
            history.record(.gpuPower, 0.5 + (sin(t / 23) + 1) * 2, at: t)
            history.record(.networkIn, max(0, sin(t / 7)) * 2_400_000 + 30_000, at: t)
            history.record(.networkOut, max(0, sin(t / 13)) * 600_000 + 10_000, at: t)
            history.record(.cpuTemperature, 46 + wave * 12 + burst * 20, at: t)
            history.record(.gpuTemperature, 42 + (sin(t / 23) + 1) * 6, at: t)
        }
        self.history = history
    }
    #endif
}

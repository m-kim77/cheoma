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

/// 1초(닫혀 있으면 2초)마다 센서를 읽는다. 읽기는 Sensors가 백그라운드 queue에서 하고, 결과만 메인 스레드에 반영한다:
/// IOReport 약 4ms, 온도 35개 약 5ms, 앱 목록 약 1.5ms라 메인에서 읽으면 120Hz 한 프레임(8.3ms)을 넘길 수 있다.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var snapshot = StatsSnapshot()
    @Published private(set) var history = StatsHistory()

    private let sensors = Sensors()
    private let queue = DispatchQueue(label: "io.github.m-kim77.cheoma.stats", qos: .utility)
    /// 앞의 측정이 아직 안 끝났으면 다음 측정은 건너뛴다
    private var isReading = false
    private var timer: Timer?
    private var saveTimer: Timer?
    private var tickCount = 0
    /// 노치 대시보드가 열려 있을 때만 1초마다, 닫혀 있으면 2초마다 측정한다 (대기 중 CPU 절약)
    var isDashboardOpen = false {
        didSet { if isDashboardOpen && !oldValue { tick() } }
    }
    /// 온도·팬 탭을 보고 있으면 팬이 목표 속도로 따라가는 게 바로 보이도록 팬 RPM만 매초 따로 읽는다 (키 몇 개라 싸다)
    var showsFans = false
    /// 앱별 사용량은 앱 탭을 보고 있을 때만 잰다
    var showsApps = false {
        didSet {
            guard showsApps != oldValue else { return }
            let shows = showsApps
            queue.async { [sensors] in sensors.setShowsApps(shows) }
        }
    }
    /// 화면 주사율. 화면 구성이 바뀔 때만 다시 읽는다
    private var refreshRate: Int??
    private var screenObserver: NSObjectProtocol?
    /// `--bench`처럼 잠깐 띄우는 경우 본 앱의 기록 파일을 덮어쓰지 않게 끈다
    private let savesHistory: Bool

    init(savesHistory: Bool = true) {
        self.savesHistory = savesHistory
    }

    private static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cheoma/history.plist")

    func start() {
        guard timer == nil else { return }
        loadHistory()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRate = nil }
        }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        timer.tolerance = 0.2
        // 메뉴가 열려 있는 동안에도 갱신되도록 common 모드
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 갑자기 꺼져도 최대 5분치만 잃도록 주기적으로 저장
        guard savesHistory else { return }
        let saveTimer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
        saveTimer.tolerance = 30
        RunLoop.main.add(saveTimer, forMode: .common)
        self.saveTimer = saveTimer
    }

    /// 앱을 끌 때는 synchronously로 저장을 마치고 끝낸다
    func saveHistory(synchronously: Bool = false) {
        guard savesHistory else { return }
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

    /// 충전기를 꽂거나 빼면 배터리 정보를 바로 다시 읽는다 (안 그러면 최대 10초 늦게 보인다)
    func powerSourceChanged() {
        queue.async { [sensors] in sensors.powerSourceChanged() }
    }

    private func timerFired() {
        tickCount += 1
        guard isDashboardOpen || tickCount % 2 == 0 else { return }
        tick()
    }

    private func tick() {
        guard !isReading else { return }
        isReading = true
        // 비싼 센서(온도 35개, 구성요소별 전력)는 열려 있으면 2초, 닫혀 있으면 4초마다만 읽는다.
        // 앱 순위는 너무 자주 뒤바뀌지 않도록 2초마다 잰다
        let request = Sensors.Request(slow: tickCount % (isDashboardOpen ? 2 : 4) == 0,
                                      fans: showsFans,
                                      apps: showsApps ? tickCount % 2 == 0 : nil)
        queue.async { [sensors] in
            let snapshot = sensors.read(request)
            let time = Date().timeIntervalSinceReferenceDate
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finish(snapshot, at: time) }
            }
        }
    }

    private func finish(_ reading: StatsSnapshot, at time: TimeInterval) {
        isReading = false
        var s = reading
        if refreshRate == nil {
            refreshRate = .some(NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.maximumFramesPerSecond
                ?? NSScreen.screens.first?.maximumFramesPerSecond)
        }
        s.refreshRate = refreshRate ?? nil
        snapshot = s
        history.append(s, at: time)
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

/// 센서 묶음. StatsStore의 queue에서만 쓴다 (그래서 @unchecked Sendable). 지난 값(온도, 앱 목록)도 여기서 기억한다
private final class Sensors: @unchecked Sendable {
    struct Request {
        /// 온도 전체와 구성요소별 전력도 읽는다
        var slow: Bool
        /// 온도를 안 읽는 차례에도 팬 RPM만 따로 읽는다
        var fans: Bool
        /// 앱 탭을 보고 있으면 이번에 앱 목록을 새로 잴 차례인지, 안 보고 있으면 nil
        var apps: Bool?
    }

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let power = PowerSampler()
    private let thermal = ThermalSampler()
    /// 앱 탭을 닫으면 새로 만들어서 프로세스 기록과 실행 인자 버퍼(1MB)를 놓는다
    private var appUsage = AppUsageSampler()
    private var lastThermal: ThermalStats?
    private var lastApps: [AppUsage]?

    func read(_ request: Request) -> StatsSnapshot {
        let cpuSample = cpu.sample()
        var s = StatsSnapshot()
        s.cpu = cpuSample?.total
        s.cores = cpuSample?.cores ?? []
        s.gpu = gpu.sample()
        s.memory = memory.sample()
        s.network = network.sample()
        s.disk = disk.sample()
        let slow = request.slow || lastThermal == nil
        s.power = power.sample(readEnergy: slow)
        if slow {
            lastThermal = thermal.sample()
        } else if request.fans, var current = lastThermal {
            current.fans = thermal.sampleFans()
            lastThermal = current
        }
        s.thermal = lastThermal
        if let due = request.apps {
            if lastApps == nil || due { lastApps = appUsage.sample() ?? lastApps }
            s.apps = lastApps
        }
        return s
    }

    func setShowsApps(_ shows: Bool) {
        lastApps = nil
        // 기준값을 미리 잡아두면 다음 측정부터 바로 값이 나온다
        if shows { _ = appUsage.sample() } else { appUsage = AppUsageSampler() }
    }

    func powerSourceChanged() {
        power.powerSourceChanged()
    }
}

import AppKit
import CheomaShared

/// 관리자 권한 팬 도우미(CheomaFanHelper)와 XPC로 통신해서 팬 속도를 바꾼다.
/// 모드: 자동(macOS가 조절) · 고정(팬마다 RPM, 멈춤) · 온도별(온도-RPM 커브).
/// 고른 모드와 값은 기억했다가 앱을 다시 켜면 이어서 적용한다. 앱을 끄거나 앱이 멈추면 도우미가 자동으로 되돌린다.
@MainActor
final class FanController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic = "자동"
        case fixed = "고정"
        case curve = "온도별"

        var id: String { rawValue }
    }

    /// 커브의 점 사이를 잇는 방식
    enum CurveStyle: String, CaseIterable, Identifiable {
        /// 점 사이를 이어서 온도에 따라 자연스럽게 바뀐다
        case linear = "곡선"
        /// 다음 점의 온도에 닿을 때까지 그대로 있다가 한 번에 바뀐다
        case step = "계단"

        var id: String { rawValue }
    }

    enum HelperState: Equatable {
        case notInstalled
        /// 설치된 도우미를 이 앱이 쓸 수 없다 (앱 위치가 바뀌었거나 도우미가 새 버전). 이유를 보여준다.
        case needsReinstall(String)
        case working
        case installed
    }

    /// 커브의 점이 놓인 온도들 (°C)
    static let curveTemperatures: [Double] = [30, 40, 50, 60, 70, 80, 90, 100]
    static let maximumSavedSpeeds = 4
    /// 온도가 내려갈 때는 이만큼 더 식어야 속도를 낮춘다 (경계에서 팬이 오르내리지 않게)
    static let hysteresis: Double = 3

    @Published private(set) var mode: Mode
    /// 고정 모드의 팬별 RPM. 0이면 멈춤
    @Published private(set) var fixedRPMs: [Double]
    /// 고정 모드에서 모든 팬을 같은 속도로 맞춘다
    @Published private(set) var isLinked: Bool
    /// 저장해 둔 고정 속도들 (각각 팬별 RPM)
    @Published private(set) var savedSpeeds: [[Double]]
    /// 온도별 모드: curveTemperatures 각 온도의 RPM. 팬 최소보다 낮은 값(0)은 그 구간을 자동으로 둔다는 뜻
    @Published private(set) var curve: [Double]
    @Published private(set) var curveStyle: CurveStyle
    /// 온도별 모드의 기준 온도: CPU · GPU 평균 중 높은 값
    @Published private(set) var ruleTemperature: Double?
    /// 지금 도우미에 걸어 둔 팬별 목표 RPM (nil이면 자동)
    @Published private(set) var appliedRPMs: [Double]?
    @Published private(set) var helperState: HelperState
    @Published private(set) var message: String?
    /// 팬별 최소~최대 RPM. 팬이 없는 맥(MacBook Air 등)이면 비어 있다
    let fanLimits: [ClosedRange<Double>]

    var hasFans: Bool { !fanLimits.isEmpty }
    /// 가장 낮은 최소 ~ 가장 높은 최대
    var rpmRange: ClosedRange<Double>? {
        guard let low = fanLimits.map(\.lowerBound).min(), let high = fanLimits.map(\.upperBound).max() else { return nil }
        return low...high
    }
    var isStopped: Bool { mode == .fixed && fixedRPMs.allSatisfy { $0 == 0 } }

    private var connection: NSXPCConnection?
    private var keepAliveTimer: Timer?
    private var verifyWork: DispatchWorkItem?
    /// appliedRPMs를 마지막으로 바꾼 시각 (팬이 목표에 닿을 시간을 줬는지 볼 때)
    private var appliedAt = Date.distantPast
    private var pendingReconcile: DispatchWorkItem?
    /// 온도별 모드에서 마지막으로 고른 RPM. 식는 중에 3°C를 더 기다릴 기준인데, appliedRPMs를 쓰면
    /// 고정에서 온도별로 바꿀 때 고정 속도가 기준이 돼서 그 속도에 묶인다
    private var curveRPM: Double?
    private var wakeObserver: NSObjectProtocol?
    private let smc: SMC?

    private enum Key {
        static let mode = "fan.mode"
        static let fixedRPMs = "fan.fixedRPMs"
        static let linked = "fan.linked"
        static let savedSpeeds = "fan.savedSpeeds"
        static let curve = "fan.curve"
        static let curveStyle = "fan.curveStyle"
        /// 팬 하나 값만 있던 예전 설정
        static let legacyFixedRPM = "fan.fixedRPM"
    }

    init() {
        let smc = SMC()
        self.smc = smc
        let limits = Self.readFanLimits(smc)
        fanLimits = limits
        let fanCount = max(limits.count, 1)

        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Key.mode).flatMap(Mode.init) ?? .automatic
        let middle = limits.isEmpty ? 2500
            : Self.rounded((limits.map(\.lowerBound).min()! + limits.map(\.upperBound).max()!) / 2)
        let fixed = defaults.array(forKey: Key.fixedRPMs) as? [Double]
            ?? [defaults.object(forKey: Key.legacyFixedRPM) as? Double ?? middle]
        fixedRPMs = Self.fitted(fixed, count: fanCount)
        isLinked = defaults.object(forKey: Key.linked) as? Bool ?? true
        savedSpeeds = defaults.array(forKey: Key.savedSpeeds) as? [[Double]] ?? []
        let savedCurve = defaults.array(forKey: Key.curve) as? [Double]
        curve = Self.nonDecreasing(savedCurve?.count == Self.curveTemperatures.count ? savedCurve! : Self.defaultCurve(for: limits))
        curveStyle = defaults.string(forKey: Key.curveStyle).flatMap(CurveStyle.init) ?? .linear
        helperState = Self.installedState()

        // 잠자는 동안 도우미가 되돌렸을 수 있으니 깨어나면 바로 상태를 물어 맞춘다
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendKeepAlive() }
        }
    }

    // MARK: - 모드

    func setMode(_ mode: Mode) {
        if mode != self.mode { curveRPM = nil }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Key.mode)
        message = nil
        reconcile()
    }

    // MARK: - 고정

    /// 고정 속도를 바꾼다. fan이 nil이거나 좌우를 묶어 뒀으면 모든 팬을 같이 바꾼다.
    /// 슬라이더를 끄는 중(commit: false)에도 0.2초에 한 번씩 도우미에 보내서 팬이 바로 따라오게 하고, 손을 떼면 저장한다.
    func setFixedRPM(_ rpm: Double, fan: Int? = nil, commit: Bool = true) {
        if let fan, !isLinked, fixedRPMs.indices.contains(fan) {
            fixedRPMs[fan] = normalized(rpm, fan: fan)
        } else {
            let value = normalized(rpm)
            fixedRPMs = fixedRPMs.map { _ in value }
        }
        if commit {
            UserDefaults.standard.set(fixedRPMs, forKey: Key.fixedRPMs)
            reconcile()
        } else {
            reconcileSoon()
        }
    }

    /// 좌우를 묶으면 팬 1의 속도로 맞춘다
    func setLinked(_ linked: Bool) {
        isLinked = linked
        UserDefaults.standard.set(linked, forKey: Key.linked)
        guard linked, let first = fixedRPMs.first else { return }
        fixedRPMs = fixedRPMs.map { _ in first }
        UserDefaults.standard.set(fixedRPMs, forKey: Key.fixedRPMs)
        reconcile()
    }

    /// 모든 팬을 멈춘다 (고정 0 RPM). 이 맥이 받아들이지 않으면 확인 단계에서 자동으로 되돌린다
    func stopFans() {
        fixedRPMs = fixedRPMs.map { _ in 0 }
        UserDefaults.standard.set(fixedRPMs, forKey: Key.fixedRPMs)
        setMode(.fixed)
    }

    func saveCurrentSpeed() {
        guard savedSpeeds.count < Self.maximumSavedSpeeds, !savedSpeeds.contains(fixedRPMs) else { return }
        savedSpeeds.append(fixedRPMs)
        UserDefaults.standard.set(savedSpeeds, forKey: Key.savedSpeeds)
    }

    func applySavedSpeed(_ speed: [Double]) {
        fixedRPMs = Self.fitted(speed, count: fixedRPMs.count)
        // 팬마다 다른 속도를 저장해 뒀으면 좌우 묶음을 푼다
        isLinked = Set(fixedRPMs).count == 1
        UserDefaults.standard.set(fixedRPMs, forKey: Key.fixedRPMs)
        UserDefaults.standard.set(isLinked, forKey: Key.linked)
        setMode(.fixed)
    }

    func removeSavedSpeed(_ speed: [Double]) {
        savedSpeeds.removeAll { $0 == speed }
        UserDefaults.standard.set(savedSpeeds, forKey: Key.savedSpeeds)
    }

    // MARK: - 온도별 커브

    func setCurve(_ values: [Double]) {
        guard values.count == Self.curveTemperatures.count else { return }
        curve = Self.nonDecreasing(values.map(curvePoint))
        UserDefaults.standard.set(curve, forKey: Key.curve)
        reconcile()
    }

    /// 점 하나를 바꾸면서 커브가 뜨거운 쪽으로 갈수록 내려가지 않게 맞춘다:
    /// 더 뜨거운 점이 이 값보다 낮으면 같이 올리고, 더 시원한 점이 이 값보다 높으면 같이 내린다
    static func editing(_ values: [Double], index: Int, to value: Double) -> [Double] {
        values.indices.map { i in
            i == index ? value : i > index ? max(values[i], value) : min(values[i], value)
        }
    }

    /// 앞(더 시원한) 점보다 낮은 점은 앞 점 값으로 올린다
    private static func nonDecreasing(_ values: [Double]) -> [Double] {
        var highest = 0.0
        return values.map { value in
            highest = max(highest, value)
            return highest
        }
    }

    func setCurveStyle(_ style: CurveStyle) {
        curveStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Key.curveStyle)
        reconcile()
    }

    func resetCurve() {
        setCurve(Self.defaultCurve(for: fanLimits))
    }

    /// 커브 점 하나를 정리한다: 팬 최소보다 낮으면 0(그 구간은 자동), 아니면 100 RPM 단위로 범위 안에
    func curvePoint(_ rpm: Double) -> Double {
        guard let range = rpmRange, rpm >= range.lowerBound else { return 0 }
        return min(max(Self.rounded(rpm), range.lowerBound), range.upperBound)
    }

    /// 커브에서 이 온도의 RPM. 30°C 아래는 첫 점, 100°C 위는 마지막 점 값을 쓴다.
    static func curveRPM(at temperature: Double, values: [Double], style: CurveStyle) -> Double {
        guard let upper = curveTemperatures.firstIndex(where: { $0 > temperature }) else { return values.last ?? 0 }
        guard upper > 0 else { return values.first ?? 0 }
        let lower = upper - 1
        switch style {
        case .step:
            return values[lower]
        case .linear:
            let t = (temperature - curveTemperatures[lower]) / (curveTemperatures[upper] - curveTemperatures[lower])
            return values[lower] + (values[upper] - values[lower]) * t
        }
    }

    /// 온도를 새로 읽을 때마다 불린다. 온도별 모드면 커브에서 속도를 다시 고르고, 도우미 연결이 끊겼으면 다시 적용한다.
    func temperatureChanged(_ thermal: ThermalStats?) {
        // 화면에는 정수로 보여서 0.5°C 단위로만 바꾼다 (값이 그대로면 팬 탭을 다시 그리지 않게)
        let temperature = [thermal?.cpu, thermal?.gpu].compactMap { $0 }.max().map { ($0 * 2).rounded() / 2 }
        if temperature != ruleTemperature { ruleTemperature = temperature }
        reconcile()
    }

    // MARK: - 도우미에 적용

    /// 지금 모드가 원하는 속도
    private func desiredRPMs() -> [Double]? {
        switch mode {
        case .automatic: nil
        case .fixed: fixedRPMs
        case .curve: ruleTemperature.flatMap(curveTarget(at:))
        }
    }

    /// 온도별 모드의 목표. 식는 중이면 3°C 더 식을 때까지 지금 속도를 지키고, 팬 최소보다 낮은 구간이면 자동(nil)
    private func curveTarget(at temperature: Double) -> [Double]? {
        guard let range = rpmRange else { return nil }
        var rpm = Self.curveRPM(at: temperature, values: curve, style: curveStyle)
        if let current = curveRPM, rpm < current {
            rpm = min(current, Self.curveRPM(at: temperature + Self.hysteresis, values: curve, style: curveStyle))
        }
        guard rpm >= range.lowerBound else {
            curveRPM = nil
            return nil
        }
        let target = min(Self.rounded(rpm), range.upperBound)
        curveRPM = target
        return fanLimits.map { _ in target }
    }

    /// 지금 모드가 원하는 속도를 도우미에 맞춰 둔다
    private func reconcile() {
        pendingReconcile?.cancel()
        pendingReconcile = nil
        guard helperState == .installed else { return }
        let desired = desiredRPMs()
        if desired != appliedRPMs { apply(desired) }
    }

    /// 슬라이더를 끄는 동안: 0.2초에 한 번만 보낸다 (그때의 마지막 값으로)
    private func reconcileSoon() {
        guard pendingReconcile == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func apply(_ rpms: [Double]?) {
        appliedRPMs = rpms
        appliedAt = Date()
        updateKeepAlive()
        if rpms == nil {
            verifyWork?.cancel()
            verifyWork = nil
        }
        let proxy = remoteProxy { [weak self] error in self?.connectionFailed(error) }
        proxy?.setFanSpeeds(rpms?.map { NSNumber(value: $0) }) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail(error)
                } else if rpms != nil {
                    self.scheduleVerification()
                }
            }
        }
    }

    /// 도우미가 재시작하는 중(연결 중단)이면 다음 측정 때 다시 적용하고, 아예 연결할 수 없을 때만 실패로 본다
    private func connectionFailed(_ error: Error) {
        if (error as NSError).code == NSXPCConnectionInterrupted {
            AppLog.write("팬: 도우미 연결이 잠깐 끊김, 다시 적용함")
            appliedRPMs = nil
            updateKeepAlive()
            return
        }
        fail("도우미에 연결하지 못했어요. 다시 설치해보세요.", detail: error.localizedDescription)
    }

    /// 도우미가 거절하거나 팬이 따라오지 않으면 자동으로 돌리고 이유를 보여준다.
    /// 2초마다 다시 시도하지 않도록 모드도 자동으로 바꿔 둔다.
    private func fail(_ text: String, detail: String? = nil) {
        mode = .automatic
        UserDefaults.standard.set(Mode.automatic.rawValue, forKey: Key.mode)
        appliedRPMs = nil
        updateKeepAlive()
        report(text, detail: detail)
    }

    /// 앱을 끌 때: 도우미는 연결이 끊기면 알아서 되돌리지만, 확실하게 자동으로 돌려놓고 끝낸다 (고른 모드는 기억해 둔다).
    /// 도우미가 답하지 않아도 앱이 안 꺼지는 일이 없도록 1초까지만 기다린다
    func restoreAutomaticBeforeQuit() {
        guard appliedRPMs != nil, let connection else { return }
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? FanHelperProtocol
        proxy?.setFanSpeeds(nil) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    /// 팬이 목표 속도에 닿는 데 걸리는 시간
    private nonisolated static let verificationDelay: TimeInterval = 8

    /// SMC가 수동 설정을 받아들였는지 실제 RPM으로 확인한다. 온도별 모드처럼 목표가 자주 바뀌어도
    /// 확인이 끝없이 미뤄지지 않게, 이미 잡힌 확인은 그대로 두고 그때 걸려 있는 목표로 확인한다
    private func scheduleVerification(after delay: TimeInterval = verificationDelay) {
        guard verifyWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.verifyWork = nil
                guard let targets = self.appliedRPMs else { return }
                // 목표가 방금 바뀌었으면 팬이 따라올 시간을 더 준다
                let waited = Date().timeIntervalSince(self.appliedAt)
                if waited < Self.verificationDelay {
                    self.scheduleVerification(after: Self.verificationDelay - waited)
                } else {
                    self.verify(targets)
                }
            }
        }
        verifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func verify(_ targets: [Double]) {
        guard let smc, appliedRPMs == targets else { return }
        var checked = 0
        var reached = 0
        for (index, limits) in fanLimits.enumerated() {
            guard let rpm = smc.float("F\(index)Ac").map(Double.init) else { continue }
            let target = targets[min(index, targets.count - 1)]
            checked += 1
            if target <= 0 {
                // 멈춤: 거의 멈췄으면 된 것
                if rpm < limits.lowerBound / 2 { reached += 1 }
            } else {
                let expected = min(max(target, limits.lowerBound), limits.upperBound)
                if abs(rpm - expected) <= (limits.upperBound - limits.lowerBound) * 0.25 { reached += 1 }
            }
        }
        guard checked > 0, reached == 0 else { return }
        let stopping = targets.allSatisfy { $0 <= 0 }
        apply(nil)
        if stopping {
            // 다음에 고정을 고르면 다시 멈추려 하지 않도록 최저 속도로 바꿔 둔다
            fixedRPMs = fanLimits.indices.map { normalized(fanLimits[$0].lowerBound, fan: $0) }
            UserDefaults.standard.set(fixedRPMs, forKey: Key.fixedRPMs)
        }
        fail(stopping ? "이 맥은 팬을 직접 멈출 수 없어요. 자동으로 되돌렸어요 (시원할 때는 macOS가 알아서 멈춰요)."
                      : "팬이 설정한 속도로 바뀌지 않았어요. 이 맥은 수동 팬 제어를 받아들이지 않는 것 같아 자동으로 되돌렸어요.")
    }

    // MARK: - 도우미 연결

    private func remoteProxy(onError: @escaping (Error) -> Void) -> FanHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: FanHelper.machServiceName, options: .privileged)
            connection.remoteObjectInterface = FanHelper.makeInterface()
            // 새 연결로 바꾼 뒤에 옛 연결의 알림이 늦게 와도 새 연결을 지우지 않도록 어느 연결인지 확인한다
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in self?.connectionLost(connection, invalidated: true) }
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                Task { @MainActor in self?.connectionLost(connection, invalidated: false) }
            }
            connection.resume()
            self.connection = connection
        }
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in onError(error) }
        }
        return proxy as? FanHelperProtocol
    }

    /// 도우미가 재시작했거나(중단) 연결이 끝났을 때(무효). 도우미는 연결이 끊기면 스스로 자동으로 되돌리므로
    /// 다음 온도 측정 때 지금 모드를 다시 적용한다. 중단된 연결은 XPC가 다시 이어 주지만 깔끔하게 새로 만든다
    private func connectionLost(_ lost: NSXPCConnection?, invalidated: Bool) {
        guard let lost, lost === connection else { return }
        if !invalidated { lost.invalidate() }
        connection = nil
        appliedRPMs = nil
        updateKeepAlive()
    }

    /// 수동 모드를 유지하라고 알리고, 도우미가 그사이 혼자 자동으로 되돌렸으면(응답 없음 · 잠자기 · 온도 한계) 화면과 설정을 맞춘다
    private func sendKeepAlive() {
        guard appliedRPMs != nil else { return }
        remoteProxy { [weak self] error in self?.connectionFailed(error) }?.keepAlive { [weak self] isManual, overheated in
            Task { @MainActor in self?.helperReported(isManual: isManual, overheated: overheated) }
        }
    }

    private func helperReported(isManual: Bool, overheated: Bool) {
        guard !isManual, appliedRPMs != nil else { return }
        if overheated {
            // 같은 설정을 바로 다시 걸면 또 한계에 닿으니 자동으로 두고 알린다
            fail("CPU가 \(Int(FanHelper.thermalLimit))°C를 넘어서 (멈춤이면 \(Int(FanHelper.stoppedThermalLimit))°C) 팬을 자동으로 되돌렸어요.")
        } else {
            AppLog.write("팬: 도우미가 자동으로 되돌려 둔 것을 확인, 다시 적용함")
            appliedRPMs = nil
            updateKeepAlive()
            reconcile()
        }
    }

    private func updateKeepAlive() {
        guard appliedRPMs != nil else {
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
            return
        }
        guard keepAliveTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendKeepAlive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    // MARK: - 설치 / 제거 (macOS 관리자 암호 창이 뜬다)

    func installHelper() {
        guard let source = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("CheomaFanHelper"),
              FileManager.default.fileExists(atPath: source.path) else {
            report("도우미 파일(CheomaFanHelper)을 찾지 못했어요. 앱과 같이 빌드해야 해요.")
            return
        }
        guard let client = Self.clientRequirement, let helperRequirement = CodeSignature.designatedRequirement(ofFile: source) else {
            report("앱이나 도우미의 코드 서명을 읽지 못했어요. 앱을 다시 내려받아 보세요.")
            return
        }
        let plist: [String: Any] = [
            "Label": FanHelper.label,
            "ProgramArguments": [FanHelper.installedBinaryPath, "--allow-requirement", client,
                                 "--helper-version", String(FanHelper.version)],
            "MachServices": [FanHelper.machServiceName: true],
            "StandardErrorPath": "/var/log/\(FanHelper.label).log",
        ]
        guard let plistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            report("설치 파일을 준비하지 못했어요")
            return
        }

        // 관리자 권한 셸은 ~/Documents 같은 개인정보 보호 폴더를 읽지 못할 수 있어서 도우미를 먼저 사용자 임시 폴더로 옮겨 둔다.
        // 암호 창이 떠 있는 동안 이 파일은 바꿔치기될 수 있으므로, 관리자 셸은 이것을 root만 쓸 수 있는 폴더로 복사한 뒤
        // 지금 잰 서명(ad-hoc이면 cdhash)과 같은지 확인하고 나서 설치한다. 설치 명령은 파일로 두지 않고 바로 넘긴다
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheomaFanHelperInstall-\(UUID().uuidString)", isDirectory: true)
        let stagedBinary = staging.appendingPathComponent("helper")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: stagedBinary)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            report("설치 파일을 준비하지 못했어요: \(error.localizedDescription)")
            return
        }
        let command = Self.installCommand(stagedBinary: stagedBinary.path, helperRequirement: helperRequirement,
                                          plist: plistData)

        // 예전 도우미와 연결돼 있었다면 끊고 새로 연결한다
        connection?.invalidate()
        connection = nil
        appliedRPMs = nil
        updateKeepAlive()
        helperState = .working
        message = nil
        AppLog.write("팬 도우미 설치 시작 (허용할 앱: \(client), 버전 \(FanHelper.version))")
        runAsAdministrator(command, prompt: "Cheoma가 팬 속도를 바꾸는 도우미를 설치하려고 합니다.") { [weak self] error in
            guard let self else { return }
            try? FileManager.default.removeItem(at: staging)
            self.helperState = Self.installedState()
            if let error {
                self.report(error.contains("CSSMERR") || error.contains("does not satisfy")
                            ? "도우미 파일이 설치 도중 바뀌어서 설치를 멈췄어요. 다시 해 보세요." : Self.describe(error),
                            detail: error)
            } else {
                AppLog.write("팬 도우미 설치 완료")
                // 기억해 둔 모드가 있으면 바로 이어서 적용한다
                self.reconcile()
            }
        }
    }

    /// 관리자 셸에서 돌릴 설치 명령. 사용자가 쓸 수 있는 곳의 파일은 root 폴더로 복사한 다음에만 쓰고,
    /// launchd 설정(plist)은 base64로 명령 안에 넣는다
    static func installCommand(stagedBinary: String, helperRequirement: String, plist: Data) -> String {
        [
            "set -e",
            "umask 077",
            "tmp=$(/usr/bin/mktemp -d /private/var/tmp/cheoma-helper.XXXXXX)",
            "trap '/bin/rm -rf \"$tmp\"' EXIT",
            "/bin/cp \(quoted(stagedBinary)) \"$tmp/helper\"",
            "/usr/bin/codesign --verify --strict -R \(quoted("=" + helperRequirement)) \"$tmp/helper\"",
            "printf '%s' \(quoted(plist.base64EncodedString())) | /usr/bin/base64 -D > \"$tmp/plist\"",
            "/bin/launchctl bootout system/\(FanHelper.label) 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \"$tmp/helper\" \(quoted(FanHelper.installedBinaryPath))",
            "/usr/bin/install -o root -g wheel -m 644 \"$tmp/plist\" \(quoted(FanHelper.launchDaemonPlistPath))",
            "/bin/launchctl bootstrap system \(quoted(FanHelper.launchDaemonPlistPath))",
        ].joined(separator: "; ")
    }

    func uninstallHelper() {
        if mode != .automatic { setMode(.automatic) }
        connection?.invalidate()
        connection = nil
        let script = [
            "launchctl bootout system/\(FanHelper.label) 2>/dev/null || true",
            "rm -f \(Self.quoted(FanHelper.launchDaemonPlistPath)) \(Self.quoted(FanHelper.installedBinaryPath))",
        ].joined(separator: "; ")
        helperState = .working
        runAsAdministrator(script, prompt: "Cheoma 팬 도우미를 제거합니다.") { [weak self] error in
            guard let self else { return }
            self.helperState = Self.installedState()
            if let error {
                self.report(Self.describe(error), detail: error)
            } else {
                AppLog.write("팬 도우미 제거 완료")
            }
        }
    }

    /// 도우미가 연결을 허용할 이 앱의 코드 서명 요구사항 (설치할 때 넘긴다). 인증서로 서명한 빌드는 다시 빌드하거나
    /// 옮겨도 같고, ad-hoc 서명 빌드는 업데이트할 때마다 바뀐다
    private static let clientRequirement = CodeSignature.designatedRequirementOfSelf()

    /// 설치된 도우미를 이 앱이 쓸 수 있는지. 앱의 서명이 바뀌었거나(ad-hoc 서명 빌드를 업데이트했을 때 등)
    /// 도우미가 새 버전으로 바뀌었으면 다시 설치해야 한다.
    private static func installedState() -> HelperState {
        guard let data = FileManager.default.contents(atPath: FanHelper.launchDaemonPlistPath) else { return .notInstalled }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let arguments = plist?["ProgramArguments"] as? [String] ?? []
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard value(after: "--helper-version") == String(FanHelper.version) else {
            return .needsReinstall("도우미가 새 버전으로 바뀌어서 다시 설치해야 해요")
        }
        guard let client = clientRequirement, value(after: "--allow-requirement") == client else {
            return .needsReinstall("앱이 바뀌어서(업데이트 등) 도우미를 다시 설치해야 해요")
        }
        return .installed
    }

    /// 팬마다 최소~최대 RPM (읽기는 root 없이 된다)
    private static func readFanLimits(_ smc: SMC?) -> [ClosedRange<Double>] {
        guard let smc else { return [] }
        return (0..<Int(smc.uint8("FNum") ?? 0)).compactMap { index in
            guard let minimum = smc.float("F\(index)Mn"), let maximum = smc.float("F\(index)Mx"),
                  maximum > minimum else { return nil }
            return Double(minimum)...Double(maximum)
        }
    }

    /// 처음 쓸 때의 커브: 50°C까지는 자동, 그 위로는 온도가 오를수록 더 가파르게 빨라진다
    private static func defaultCurve(for limits: [ClosedRange<Double>]) -> [Double] {
        guard let low = limits.map(\.lowerBound).min(), let high = limits.map(\.upperBound).max() else {
            return curveTemperatures.map { _ in 0 }
        }
        let at = { (fraction: Double) in min(max(rounded(low + (high - low) * fraction), low), high) }
        // 30 40 50 60 70 80 90 100°C
        return [0, 0, 0, at(0), at(0.15), at(0.35), at(0.65), high]
    }

    /// 배열을 팬 수에 맞춘다 (모자라면 마지막 값으로 채운다)
    private static func fitted(_ values: [Double], count: Int) -> [Double] {
        guard let last = values.last else { return Array(repeating: 2500, count: count) }
        return (0..<count).map { $0 < values.count ? values[$0] : last }
    }

    /// 100 RPM 단위로
    static func rounded(_ rpm: Double) -> Double { (rpm / 100).rounded() * 100 }

    /// 100 RPM 단위로 맞추고 범위 안으로 자른다 (fan이 nil이면 모든 팬을 합친 범위)
    private func normalized(_ rpm: Double, fan: Int? = nil) -> Double {
        let range = fan.flatMap { fanLimits.indices.contains($0) ? fanLimits[$0] : nil } ?? rpmRange
        guard let range else { return Self.rounded(rpm) }
        return min(max(Self.rounded(rpm), range.lowerBound), range.upperBound)
    }

    #if DEBUG
    /// 미리보기 렌더링용: 도우미가 설치된 것처럼 보이게 한다 (실제로 연결하지는 않는다)
    func preview(mode: Mode, temperature: Double, linked: Bool = true) {
        helperState = .installed
        self.mode = mode
        isLinked = linked
        if !linked { fixedRPMs = fanLimits.indices.map { normalized(2800 + Double($0) * 600, fan: $0) } }
        if savedSpeeds.isEmpty { savedSpeeds = [fixedRPMs.map { _ in 2000 }, fixedRPMs.map { _ in 4500 }] }
        ruleTemperature = temperature
        // 앞 미리보기의 목표가 남아 있으면 식는 중으로 보고 그 속도를 유지하므로 비우고 계산한다
        appliedRPMs = nil
        appliedRPMs = desiredRPMs()
    }
    #endif

    /// 화면에 보여주고 로그 파일에도 남긴다
    private func report(_ text: String, detail: String? = nil) {
        message = text
        AppLog.write("팬: \(text)" + (detail.map { " | \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? ""))
    }

    /// 메인 스레드를 막지 않도록 osascript를 별도 프로세스로 실행한다
    private func runAsAdministrator(_ shell: String, prompt: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.shellScript(shell, administratorPrompt: prompt)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            completion(error.localizedDescription)
            return
        }
        // 끝나기를 기다렸다가 읽으면 출력이 파이프 버퍼(64KB)를 넘을 때 서로 기다리며 멈추므로, 읽으면서 기다린다
        DispatchQueue.global(qos: .userInitiated).async {
            let output = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor in completion(status == 0 ? nil : output) }
        }
    }

    /// osascript에 넘길 AppleScript. prompt가 있으면 관리자 암호를 묻고 root로 실행한다 (테스트는 prompt 없이 그대로 돌려 본다)
    static func shellScript(_ shell: String, administratorPrompt prompt: String?) -> String {
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "do shell script \"\(escape(shell))\""
        guard let prompt else { return script }
        return script + " with prompt \"\(escape(prompt))\" with administrator privileges"
    }

    private static func describe(_ error: String) -> String {
        if error.contains("-128") { return "관리자 암호 입력을 취소했어요" }
        if error.contains("-60005") { return "관리자 암호가 맞지 않았어요" }
        return "관리자 작업에 실패했어요: \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 셸에 넘길 경로를 작은따옴표로 감싼다 (경로 안의 작은따옴표도 안전하게)
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

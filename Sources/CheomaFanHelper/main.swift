import Darwin
import Foundation
import CheomaShared

// Cheoma 팬 도우미: launchd가 root 권한으로 띄우는 작은 데몬.
// 할 수 있는 일은 팬 속도를 각 팬의 최소~최대 범위 안에서 정하거나, 멈추거나, 자동으로 되돌리는 것뿐이다.
// 안전장치: 앱 연결이나 keepAlive가 끊기면, 또는 CPU 온도가 한계(팬을 멈춘 동안은 더 낮은 한계)를 넘으면 자동으로 되돌린다.
// 되돌리기(SMC 쓰기)가 실패하면 수동 상태로 남겨 두고 watchdog이 될 때까지 다시 시도한다 (팬이 멈춘 채로 남지 않게).

final class FanService: NSObject, FanHelperProtocol {
    private struct Fan {
        let modeKey: String     // M5는 F0md, 이전 칩은 F0Md
        let targetKey: String
        let minimum: Float
        let maximum: Float
    }

    private let queue = DispatchQueue(label: "io.github.m-kim77.cheoma.fanhelper.smc")
    private let smc: SMC?
    private let fans: [Fan]
    private let cpuTemperatureKeys: [String]
    /// 팬을 수동으로 잡고 있을 수 있다. 자동으로 되돌리기에 실패하면 true로 남는다
    private var isManual = false
    /// 멈춘 팬이 있으면 더 낮은 온도에서 자동으로 되돌린다
    private var isStopped = false
    /// 마지막으로 자동으로 되돌린 이유가 온도 한계였는지 (앱이 같은 설정을 바로 다시 걸지 않게 알려 준다)
    private var overheated = false
    /// 되돌리기에 실패해서 다시 시도해야 하는 이유
    private var pendingRestore: String?
    /// 마지막 keepAlive 시각. 잠자는 동안 멈추는 시계(uptime)라 깨어난 직전에 시간이 지났다고 착각하지 않는다
    private var lastKeepAlive = DispatchTime.now()
    private var watchdog: DispatchSourceTimer?

    override init() {
        let smc = SMC()
        self.smc = smc
        fans = Self.discoverFans(smc)
        cpuTemperatureKeys = (smc?.allKeys() ?? []).filter { $0.hasPrefix("Tp") }
        super.init()
        // 예전 도우미가 수동으로 둔 채 죽었을 수도 있으니 시작할 때 자동으로 돌려놓는다 (실패하면 watchdog이 다시 시도)
        queue.sync { _ = restoreAutomatic(reason: "도우미 시작") }
        startWatchdog()
    }

    // MARK: FanHelperProtocol

    func setFanSpeeds(_ rpms: [NSNumber]?, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard let smc else { return reply("SMC를 열 수 없어요") }
            guard !fans.isEmpty else { return reply("이 맥에서 팬을 찾지 못했어요") }
            guard let rpms, !rpms.isEmpty else {
                return reply(restoreAutomatic(reason: "앱 요청") ? nil : "팬을 자동으로 되돌리지 못해서 다시 시도하고 있어요")
            }
            var targets: [Float] = []
            for (index, fan) in fans.enumerated() {
                let rpm = rpms[min(index, rpms.count - 1)].floatValue
                guard rpm.isFinite else {
                    restoreAutomatic(reason: "잘못된 값")
                    return reply("팬 속도 값이 잘못됐어요")
                }
                // 0은 멈춤, 그 밖의 값은 이 팬의 최소~최대 안으로
                let target = rpm <= 0 ? 0 : min(max(rpm, fan.minimum), fan.maximum)
                guard smc.write(fan.modeKey, uint8: 1), smc.write(fan.targetKey, float: target) else {
                    restoreAutomatic(reason: "쓰기 실패")
                    return reply("팬 \(index + 1) 설정에 실패했어요 (\(fan.modeKey)/\(fan.targetKey))")
                }
                targets.append(target)
            }
            isManual = true
            isStopped = targets.contains(0)
            overheated = false
            pendingRestore = nil
            lastKeepAlive = DispatchTime.now()
            log("수동 " + targets.map { $0 == 0 ? "멈춤" : "\(Int($0))" }.joined(separator: " / ") + " RPM")
            reply(nil)
        }
    }

    func keepAlive(reply: @escaping (Bool, Bool) -> Void) {
        queue.async { [self] in
            lastKeepAlive = DispatchTime.now()
            // 되돌리는 중(실패해서 다시 시도 중)이면 앱에는 이미 수동이 아닌 것으로 알린다
            reply(isManual && pendingRestore == nil, overheated)
        }
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(FanHelper.version)
    }

    func clientDisconnected() {
        queue.async { [self] in
            if isManual { restoreAutomatic(reason: "앱 연결 끊김") }
        }
    }

    /// 끝나면 다시 시도할 수 없으니 몇 번 더 해 본다
    func shutdown() {
        queue.sync {
            for attempt in 1...3 {
                if restoreAutomatic(reason: "도우미 종료") { return }
                if attempt < 3 { usleep(200_000) }
            }
            log("끝내기 전에 자동으로 되돌리지 못함")
        }
    }

    // MARK: 안전장치

    /// queue에서만 호출. 팬 하나라도 되돌리지 못하면 수동 상태로 남겨 두고 watchdog이 다시 시도한다
    @discardableResult
    private func restoreAutomatic(reason: String, overheated: Bool = false) -> Bool {
        let failed = fans.indices.filter { smc?.write(fans[$0].modeKey, uint8: 0) != true }
        if overheated { self.overheated = true }
        guard failed.isEmpty else {
            if pendingRestore == nil {
                log("자동으로 되돌리지 못함 (팬 \(failed.map { String($0 + 1) }.joined(separator: ", "))): \(reason). 2초마다 다시 시도")
            }
            pendingRestore = reason
            isManual = true
            return false
        }
        if isManual { log("자동으로 되돌림: \(pendingRestore ?? reason)") }
        isManual = false
        isStopped = false
        pendingRestore = nil
        return true
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkSafety() }
        timer.resume()
        watchdog = timer
    }

    private func checkSafety() {
        guard isManual else { return }
        if let pendingRestore {
            restoreAutomatic(reason: pendingRestore)
            return
        }
        let silence = Double(DispatchTime.now().uptimeNanoseconds - lastKeepAlive.uptimeNanoseconds) / 1e9
        if silence > FanHelper.keepAliveTimeout {
            restoreAutomatic(reason: "앱 응답 없음 (\(Int(silence))초)")
            return
        }
        let hottest = cpuTemperatureKeys.compactMap { smc?.float($0) }.filter { $0 > 5 && $0 < 130 }.max() ?? 0
        if Double(hottest) > (isStopped ? FanHelper.stoppedThermalLimit : FanHelper.thermalLimit) {
            restoreAutomatic(reason: "CPU \(Int(hottest))°C", overheated: true)
        }
    }

    private static func discoverFans(_ smc: SMC?) -> [Fan] {
        guard let smc else { return [] }
        let count = Int(smc.uint8("FNum") ?? 0)
        return (0..<max(count, 0)).compactMap { index in
            let modeKey = ["F\(index)md", "F\(index)Md"].first { smc.uint8($0) != nil }
            guard let modeKey, let minimum = smc.float("F\(index)Mn"), let maximum = smc.float("F\(index)Mx"),
                  maximum > minimum else { return nil }
            return Fan(modeKey: modeKey, targetKey: "F\(index)Tg", minimum: minimum, maximum: maximum)
        }
    }
}

/// 설치할 때 정해 둔 코드 서명(지정 요구사항)을 만족하는 Cheoma에서 온 연결만 받는다.
/// 실행 파일 경로만 보면 같은 사용자의 아무 프로세스나 그 경로의 파일을 바꿔치거나 흉내 내서 팬을 멈출 수 있다
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: FanService
    private let allowedRequirement: String?

    init(service: FanService, allowedRequirement: String?) {
        self.service = service
        self.allowedRequirement = allowedRequirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard let allowedRequirement, CodeSignature.process(pid, satisfies: allowedRequirement) else {
            log("연결 거부: \(Self.executablePath(of: pid) ?? "?") (pid \(pid))")
            return false
        }
        // 위 확인은 pid로 해서 그사이 다른 프로세스가 같은 번호를 받을 수 있다. 메시지마다 서명을 확인하게 한다
        connection.setCodeSigningRequirement(allowedRequirement)
        connection.exportedInterface = FanHelper.makeInterface()
        connection.exportedObject = service
        connection.invalidationHandler = { [service] in service.clientDisconnected() }
        connection.interruptionHandler = { [service] in service.clientDisconnected() }
        connection.resume()
        return true
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[CheomaFanHelper] \(message)\n".utf8))
}

// 사용법: CheomaFanHelper --allow-requirement <Cheoma의 지정 요구사항> [--helper-version <n>]
// (--helper-version은 앱이 설치된 도우미 버전을 확인하려고 적어 두는 값이라 도우미는 쓰지 않는다)
let arguments = CommandLine.arguments
let allowedRequirement = arguments.firstIndex(of: "--allow-requirement").flatMap { index in
    index + 1 < arguments.count ? arguments[index + 1] : nil
}

let service = FanService()
let delegate = ListenerDelegate(service: service, allowedRequirement: allowedRequirement)
let listener = NSXPCListener(machServiceName: FanHelper.machServiceName)
listener.delegate = delegate
listener.resume()

// launchctl로 내릴 때도 팬을 자동으로 돌려놓고 끝낸다
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    service.shutdown()
    exit(0)
}
terminationSource.resume()

log("시작 (허용된 앱: \(allowedRequirement ?? "없음"))")
dispatchMain()

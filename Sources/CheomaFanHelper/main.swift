import Darwin
import Foundation
import CheomaShared

// Cheoma 팬 도우미: launchd가 root 권한으로 띄우는 작은 데몬.
// 할 수 있는 일은 팬 속도를 각 팬의 최소~최대 범위 안에서 정하거나, 멈추거나, 자동으로 되돌리는 것뿐이다.
// 안전장치: 앱 연결이나 keepAlive가 끊기면, 또는 CPU 온도가 한계(팬을 멈춘 동안은 더 낮은 한계)를 넘으면 자동으로 되돌린다.

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
    private var isManual = false
    /// 멈춘 팬이 있으면 더 낮은 온도에서 자동으로 되돌린다
    private var isStopped = false
    private var lastKeepAlive = Date()
    private var watchdog: DispatchSourceTimer?

    override init() {
        let smc = SMC()
        self.smc = smc
        fans = Self.discoverFans(smc)
        cpuTemperatureKeys = (smc?.allKeys() ?? []).filter { $0.hasPrefix("Tp") }
        super.init()
        queue.sync { restoreAutomatic(reason: "도우미 시작") }
        startWatchdog()
    }

    // MARK: FanHelperProtocol

    func setFanSpeeds(_ rpms: [NSNumber]?, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard let smc else { return reply("SMC를 열 수 없어요") }
            guard !fans.isEmpty else { return reply("이 맥에서 팬을 찾지 못했어요") }
            guard let rpms, !rpms.isEmpty else {
                restoreAutomatic(reason: "앱 요청")
                return reply(nil)
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
            lastKeepAlive = Date()
            log("수동 " + targets.map { $0 == 0 ? "멈춤" : "\(Int($0))" }.joined(separator: " / ") + " RPM")
            reply(nil)
        }
    }

    func keepAlive() {
        queue.async { [self] in lastKeepAlive = Date() }
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(FanHelper.version)
    }

    func clientDisconnected() {
        queue.async { [self] in
            if isManual { restoreAutomatic(reason: "앱 연결 끊김") }
        }
    }

    func shutdown() {
        queue.sync { restoreAutomatic(reason: "도우미 종료") }
    }

    // MARK: 안전장치

    /// queue에서만 호출
    private func restoreAutomatic(reason: String) {
        for fan in fans { _ = smc?.write(fan.modeKey, uint8: 0) }
        if isManual { log("자동으로 되돌림: \(reason)") }
        isManual = false
        isStopped = false
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkSafety() }
        timer.resume()
        watchdog = timer
    }

    private func checkSafety() {
        guard isManual else { return }
        if Date().timeIntervalSince(lastKeepAlive) > FanHelper.keepAliveTimeout {
            restoreAutomatic(reason: "앱 응답 없음")
            return
        }
        let hottest = cpuTemperatureKeys.compactMap { smc?.float($0) }.filter { $0 > 5 && $0 < 130 }.max() ?? 0
        if Double(hottest) > (isStopped ? FanHelper.stoppedThermalLimit : FanHelper.thermalLimit) {
            restoreAutomatic(reason: "CPU \(Int(hottest))°C")
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

/// 설치할 때 정해 둔 Cheoma 실행 파일에서 온 연결만 받는다
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: FanService
    private let allowedClientPath: String?

    init(service: FanService, allowedClientPath: String?) {
        self.service = service
        self.allowedClientPath = allowedClientPath
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientPath = Self.executablePath(of: connection.processIdentifier)
        guard let allowedClientPath, clientPath == allowedClientPath else {
            log("연결 거부: \(clientPath ?? "?")")
            return false
        }
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

// 사용법: CheomaFanHelper --allow-client <Cheoma 실행 파일 경로> [--helper-version <n>]
// (--helper-version은 앱이 설치된 도우미 버전을 확인하려고 적어 두는 값이라 도우미는 쓰지 않는다)
let arguments = CommandLine.arguments
let allowedClient = arguments.firstIndex(of: "--allow-client").flatMap { index in
    index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]).resolvingSymlinksInPath().path : nil
}

let service = FanService()
let delegate = ListenerDelegate(service: service, allowedClientPath: allowedClient)
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

log("시작 (허용된 앱: \(allowedClient ?? "없음"))")
dispatchMain()

import Foundation

/// 앱 ↔ 관리자 권한 팬 도우미 사이의 XPC 규약.
/// 도우미는 팬 속도를 "각 팬의 최소~최대 범위 안에서" 정하거나, 멈추거나, 자동으로 되돌리는 일만 한다.
@objc public protocol FanHelperProtocol {
    /// 팬마다 목표 RPM을 정한다 (배열 순서 = 팬 번호). 값이 팬 수보다 적으면 마지막 값을 나머지 팬에도 쓴다.
    /// 0이면 그 팬을 멈추려고 하고, 그 밖의 값은 팬마다 자기 최소~최대로 자른다. nil이면 모두 자동(macOS 제어)으로 되돌린다.
    /// 실패하면 이유를 담은 문자열, 성공하면 nil.
    func setFanSpeeds(_ rpms: [NSNumber]?, reply: @escaping (String?) -> Void)

    /// 수동 모드를 유지하라는 신호. 일정 시간 안 오면 도우미가 스스로 자동으로 되돌린다.
    /// 답으로 지금도 수동인지, 아니라면 온도 한계 때문에 되돌렸는지 알려 준다 (앱이 자기 화면을 맞추고 다시 적용할지 정한다).
    func keepAlive(reply: @escaping (_ isManual: Bool, _ overheated: Bool) -> Void)

    /// 도우미 버전
    func version(reply: @escaping (Int) -> Void)
}

public enum FanHelper {
    public static let label = "io.github.m-kim77.cheoma.fanhelper"
    public static let machServiceName = label
    /// XPC 규약이 바뀌면 올린다. 설치할 때 도우미 실행 인자(--helper-version)에도 적어 두고,
    /// 앱이 그 값을 비교해서 다르면 다시 설치하도록 안내한다.
    /// 4: keepAlive가 상태를 돌려주고, 연결을 코드 서명으로 확인한다 (--allow-requirement)
    public static let version = 4
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(label).plist"
    /// 앱이 이 시간 안에 keepAlive를 보내지 않으면 자동으로 되돌린다 (잠자는 동안은 세지 않는다)
    public static let keepAliveTimeout: TimeInterval = 20
    /// 수동 모드 중 CPU 온도가 이 값을 넘으면 자동으로 되돌린다
    public static let thermalLimit: Double = 95
    /// 팬을 멈춰 둔 동안은 더 낮은 온도에서 자동으로 되돌린다
    public static let stoppedThermalLimit: Double = 85

    /// 앱과 도우미가 같은 모양으로 만든다. 배열 인자에 들어갈 수 있는 클래스를 XPC에 알려줘야 한다.
    public static func makeInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FanHelperProtocol.self)
        interface.setClasses(NSSet(objects: NSArray.self, NSNumber.self) as! Set<AnyHashable>,
                             for: #selector(FanHelperProtocol.setFanSpeeds(_:reply:)), argumentIndex: 0, ofReply: false)
        return interface
    }
}

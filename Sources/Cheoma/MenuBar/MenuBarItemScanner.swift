import AppKit
import ApplicationServices

/// 다른 앱의 메뉴바 아이콘 하나.
/// AXUIElement는 스레드 안전한 CF 타입이고 아이콘은 읽기만 하므로 스레드 간 전달해도 안전하다.
struct MenuBarItem: Identifiable, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let appName: String
    let label: String
    let frame: CGRect          // 화면 좌표 (왼쪽 위 원점, AX 기준)
    let icon: NSImage?
    let symbol: String?        // 시스템 항목은 앱 아이콘 대신 SF Symbol
    fileprivate let element: AXUIElement

    /// 화면 밖/노치 뒤에 있어도 손쉬운 사용 API로 직접 누를 수 있다
    func press() {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// 지금 위치. frame은 목록을 읽은 순간의 값이라 그 뒤 구분선이 접히거나 펼쳐지면 달라진다
    var currentFrame: CGRect? { MenuBarItemScanner.frame(of: element) }
}

/// macOS 26부터 메뉴바 아이콘 창은 전부 "제어 센터" 소유라 창 목록으로는 어느 앱 것인지 알 수 없다.
/// 대신 각 앱의 손쉬운 사용 트리(AXExtrasMenuBar)에서 아이콘과 위치를 읽는다.
enum MenuBarItemScanner {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 메뉴바에서 아이콘이 실제로 보이는 가로 구간 (백그라운드 스레드로 넘기기 위해 값으로 계산)
    struct VisibleRegion: Sendable {
        let screen: ClosedRange<CGFloat>
        let notch: ClosedRange<CGFloat>?
        /// 이 x보다 왼쪽 아이콘은 사용자가 숨기기로 한 것
        let separatorX: CGFloat?

        @MainActor
        init(screen: NSScreen, separatorX: CGFloat? = nil) {
            self.separatorX = separatorX
            self.screen = screen.frame.minX...screen.frame.maxX
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               screen.safeAreaInsets.top > 0 {
                notch = (screen.frame.minX + left.width)...(screen.frame.maxX - right.width)
            } else {
                notch = nil
            }
        }
    }

    /// 화면 밖으로 밀려났거나, 노치 뒤에 가려졌거나, 구분선 왼쪽에 있는 아이콘들 (왼쪽 → 오른쪽 순)
    static func hiddenItems(in region: VisibleRegion) -> [MenuBarItem] {
        classifiedItems(in: region).hidden
    }

    static func classifiedItems(in region: VisibleRegion) -> (hidden: [MenuBarItem], visible: [MenuBarItem]) {
        var hidden: [MenuBarItem] = []
        var visible: [MenuBarItem] = []
        for item in allItems() {
            isHidden(item, in: region) ? hidden.append(item) : visible.append(item)
        }
        return (hidden, visible)
    }

    static func isHidden(_ item: MenuBarItem, in region: VisibleRegion) -> Bool {
        let fullyVisible = region.screen.contains(item.frame.minX) && region.screen.contains(item.frame.maxX)
        // 노치가 있는 화면에서는 노치 왼쪽에 메뉴바 아이콘이 그려지지 않는다
        let behindNotch = region.notch.map { item.frame.minX < $0.upperBound } ?? false
        let leftOfSeparator = region.separatorX.map { item.frame.maxX <= $0 + 1 } ?? false
        return !fullyVisible || behindNotch || leftOfSeparator
    }

    static func allItems() -> [MenuBarItem] {
        // 이 앱 자신의 토글/구분선은 제외 (같은 실행 파일로 띄운 다른 인스턴스 포함)
        let ownExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        var items: [MenuBarItem] = []
        for app in NSWorkspace.shared.runningApplications
        where app.executableURL?.resolvingSymlinksInPath() != ownExecutable {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            // 응답 없는 앱 때문에 전체가 멈추지 않도록
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            guard let bar: AXUIElement = attribute(appElement, "AXExtrasMenuBar"),
                  let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { continue }

            for (index, element) in children.enumerated() {
                guard let frame = frame(of: element), frame.width > 0 else { continue }
                let identifier: String? = attribute(element, kAXIdentifierAttribute)
                let description: String? = attribute(element, kAXDescriptionAttribute)
                let title: String? = attribute(element, kAXTitleAttribute)
                let appName = app.localizedName ?? "앱"
                let label = [description, title].compactMap { $0 }.first { !$0.isEmpty } ?? appName
                items.append(MenuBarItem(
                    id: "\(app.processIdentifier)-\(identifier ?? String(index))",
                    pid: app.processIdentifier,
                    appName: appName,
                    label: label,
                    frame: frame,
                    icon: app.icon,
                    symbol: identifier.flatMap(systemSymbol),
                    element: element
                ))
            }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    fileprivate static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// 제어 센터가 그리는 시스템 항목은 앱 아이콘이 다 똑같으므로 기호로 구분
    private static func systemSymbol(for identifier: String) -> String? {
        let map: [String: String] = [
            "com.apple.menuextra.battery": "battery.75percent",
            "com.apple.menuextra.wifi": "wifi",
            "com.apple.menuextra.clock": "clock",
            "com.apple.menuextra.controlcenter": "switch.2",
            "com.apple.menuextra.screen-mirroring": "rectangle.on.rectangle",
            "com.apple.menuextra.now-playing": "play.circle",
            "com.apple.menuextra.bluetooth": "dot.radiowaves.left.and.right",
            "com.apple.menuextra.focusmode": "moon.fill",
            "com.apple.menuextra.sound": "speaker.wave.2.fill",
            "com.apple.menuextra.display": "sun.max",
            "com.apple.menuextra.siri": "waveform",
            "com.apple.menuextra.airdrop": "airplayaudio",
        ]
        return map[identifier]
    }
}

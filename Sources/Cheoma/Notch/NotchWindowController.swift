import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let panel: OverlayPanel
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// 펼쳤을 때 그림자까지 들어가도록 여유를 둔 창 크기
    private static let windowSize = CGSize(width: NotchModel.maxOpenSize.width + 60,
                                           height: NotchModel.maxOpenSize.height + 40)

    init(model: NotchModel, stats: StatsStore, fans: FanController, agents: AgentStore) {
        self.model = model
        panel = OverlayPanel(size: Self.windowSize)
        // 메뉴바보다 위에 그려야 노치 영역을 덮을 수 있음
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.ignoresMouseEvents = true

        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, stats: stats, fans: fans, agents: agents))
        hosting.sizingOptions = []
        panel.contentView = hosting

        // 닫혀 있을 땐 클릭이 뒤의 메뉴바로 통과하도록
        model.$isOpen
            .sink { [weak panel] isOpen in panel?.ignoresMouseEvents = !isOpen }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        // 전체화면 앱으로 들어가거나 나오면 메뉴바가 숨거나 나타난다
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didActivateApplicationNotification))
            // 공간이 바뀌는 애니메이션이 끝난 뒤에 메뉴바 상태가 맞아진다
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateVirtualNotch() }
            .store(in: &cancellables)

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) {
            monitors.append(local)
        }

        layout()
        panel.orderFrontRegardless()
    }

    private func layout() {
        guard let screen = Self.preferredScreen() else { return }
        self.screen = screen
        model.notchSize = Self.notchSize(of: screen)
        let frame = screen.frame
        panel.setFrame(CGRect(x: frame.midX - Self.windowSize.width / 2,
                              y: frame.maxY - Self.windowSize.height,
                              width: Self.windowSize.width,
                              height: Self.windowSize.height),
                       display: true)
        updateVirtualNotch()
    }

    /// 노치 없는 화면에서는 메뉴바 가운데에 검은 가상 노치를 그린다. 메뉴바가 숨으면(전체화면 영상 등)
    /// 그 알약만 화면 위에 떠 보이므로 닫혀 있는 동안은 그리지 않는다 (마우스를 올리면 그대로 펼쳐진다)
    private func updateVirtualNotch() {
        guard let screen else { return }
        let hides = !Self.hasNotch(screen) && !Self.isMenuBarVisible(on: screen)
        if model.hidesVirtualNotch != hides { model.hidesVirtualNotch = hides }
    }

    private func handleMouseMoved() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        let hot = Self.topCenterRect(in: screen, size: model.notchSize).insetBy(dx: -10, dy: -6)
        let open = Self.topCenterRect(in: screen, size: model.openSize).insetBy(dx: -16, dy: -16)
        model.updateMouse(inHotZone: hot.contains(mouse), inOpenZone: open.contains(mouse))
    }

    private static func topCenterRect(in screen: NSScreen, size: CGSize) -> CGRect {
        CGRect(x: screen.frame.midX - size.width / 2,
               y: screen.frame.maxY - size.height,
               width: size.width,
               height: size.height)
    }

    /// 노치가 있는 내장 디스플레이 우선, 없으면 주 화면(메뉴바가 처음 놓이는 화면).
    /// NSScreen.main은 지금 키 윈도우가 있는 화면이라 앱을 오갈 때마다 바뀐다
    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.screens.first
    }

    private static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// 이 화면에 메뉴바 창(Window Server의 "Menubar")이 지금 떠 있는지. 창 이름과 위치는 화면 기록 권한 없이 읽힌다.
    /// 메뉴바 창을 하나도 못 찾으면(macOS가 바뀌었을 때) 보이는 것으로 친다
    private static func isMenuBarVisible(on screen: NSScreen) -> Bool {
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuBars = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowName as String] as? String == "Menubar",
                  window[kCGWindowLayer as String] as? Int == level,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        guard !menuBars.isEmpty else { return true }
        // 창 목록은 주 화면 왼쪽 위가 원점이고 아래로 갈수록 y가 커진다
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let top = primaryTop - screen.frame.maxY
        return menuBars.contains { abs($0.minY - top) < 2 && $0.midX > screen.frame.minX && $0.midX < screen.frame.maxX }
    }

    private static func notchSize(of screen: NSScreen) -> CGSize {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        // 노치 없는 모니터: 메뉴바 높이에 맞춘 가상 노치
        return CGSize(width: 185, height: NSStatusBar.system.thickness)
    }
}

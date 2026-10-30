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

    /// 노치가 있는 내장 디스플레이 우선, 없으면 메인 화면
    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
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

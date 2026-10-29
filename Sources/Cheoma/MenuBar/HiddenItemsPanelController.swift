import AppKit
import Combine
import SwiftUI

/// 토글 버튼 바로 아래에 숨겨진 아이콘 패널을 띄운다
@MainActor
final class HiddenItemsPanelController {
    private let model = HiddenItemsModel()
    private let panel: OverlayPanel
    private var outsideClickMonitor: Any?
    private var hideWork: DispatchWorkItem?
    private var screen: NSScreen?
    private var cancellables = Set<AnyCancellable>()

    private static let panelSize = CGSize(width: HiddenItemsView.width + 24, height: 640)

    var isShown: Bool { model.isPresented }
    /// 패널이 닫힌 뒤 호출된다. 아이콘을 화면 안으로 데려와 누르는 건 구분선을 가진 쪽이 맡는다.
    var onSelect: ((MenuBarItem) -> Void)?
    /// 정리 모드에서는 구분선을 잠깐 보이게 해서 메뉴바에서 직접 ⌘ 드래그로 정리하게 한다
    var onEditingChanged: ((Bool) -> Void)?
    var onFinishEditing: (() -> Void)?
    /// 구분선 왼쪽에 있는 아이콘은 지금 화면에 보이더라도 "숨긴 아이콘"으로 분류한다
    var separatorX: (() -> CGFloat?)?

    init() {
        panel = OverlayPanel(size: Self.panelSize)
        panel.level = .popUpMenu
        let hosting = FirstMouseHostingView(rootView: HiddenItemsView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onSelect = { [weak self] item in
            self?.hide()
            self?.onSelect?(item)
        }
        model.onDismiss = { [weak self] in self?.hide() }
        model.onFinishEditing = { [weak self] in self?.onFinishEditing?() }
        model.$isEditing
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] editing in self?.onEditingChanged?(editing) }
            .store(in: &cancellables)
        model.onRequestPermission = { [weak self] in
            self?.hide()
            MenuBarItemScanner.requestPermission()
        }
    }

    func toggle(below anchor: NSRect?) {
        isShown ? hide() : show(below: anchor)
    }

    func show(below anchor: NSRect?) {
        hideWork?.cancel()
        guard let screen = Self.screen(for: anchor) else { return }
        self.screen = screen
        position(below: anchor, on: screen)
        panel.orderFrontRegardless()
        model.isPresented = true
        reload(on: screen)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleOutsideMouse(event) }
        }
    }

    private func handleOutsideMouse(_ event: NSEvent) {
        if model.isEditing {
            // 정리 중에는 메뉴바에서 직접 ⌘ 드래그할 수 있게 닫지 않고, 끝나면 목록만 새로 읽는다
            if event.type == .leftMouseUp {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
            }
        } else if event.type != .leftMouseUp {
            hide()
        }
    }

    func refresh() {
        guard model.isPresented, let screen else { return }
        reload(on: screen)
    }

    func hide() {
        guard model.isPresented else { return }
        model.isPresented = false
        model.isEditing = false
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        // 사라지는 애니메이션이 끝난 뒤 창을 내린다
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reload(on screen: NSScreen) {
        guard MenuBarItemScanner.hasPermission else {
            model.state = .needsPermission
            return
        }
        if case .loaded = model.state {} else { model.state = .loading }
        let region = MenuBarItemScanner.VisibleRegion(screen: screen, separatorX: separatorX?())
        // 앱마다 손쉬운 사용 요청을 보내므로 메인 스레드를 막지 않게 백그라운드에서
        Task.detached(priority: .userInitiated) { [weak self] in
            let (hidden, visible) = MenuBarItemScanner.classifiedItems(in: region)
            await self?.finishLoading(hidden: hidden, visible: visible)
        }
    }

    private func finishLoading(hidden: [MenuBarItem], visible: [MenuBarItem]) {
        model.state = .loaded(hidden: hidden, visible: visible)
    }

    private func position(below anchor: NSRect?, on screen: NSScreen) {
        // 노치가 있는 화면은 메뉴바가 노치 높이만큼 두껍다
        let menuBarBottom = screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let right = min((anchor?.maxX ?? screen.frame.maxX - 8) + 12, screen.frame.maxX)
        let x = max(right - Self.panelSize.width, screen.frame.minX)
        panel.setFrame(CGRect(x: x, y: menuBarBottom - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height),
                       display: true)
    }

    private static func screen(for anchor: NSRect?) -> NSScreen? {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }) {
            return screen
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

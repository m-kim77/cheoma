import AppKit
import ServiceManagement

/// 왼쪽 클릭: 노치 뒤에 가려진 아이콘(자리가 없어 macOS가 숨긴 것 + 사용자가 숨긴 것)을 아래로 펼쳐 보여준다.
/// 구분선(|): 사용자가 ⌘ 드래그로 그 왼쪽에 둔 아이콘을 숨긴다. 아이콘을 직접 옮기거나 마우스를 흉내 내지는 않는다.
@MainActor
final class StatusBarController: NSObject {
    // 먼저 만든 아이템이 더 오른쪽에 놓이므로: [숨길 아이콘들] | ⌄
    private let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let separatorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// 숨길 때 구분선 길이. 그 왼쪽 아이콘들이 화면 밖으로 밀려난다.
    /// (노치 끝까지만 늘리는 방식은 macOS 26이 메뉴바 순서를 다시 섞어버려서 쓰지 않는다)
    private static let hidingLength: CGFloat = 10_000
    private static let hidingDefaultsKey = "statusBar.isCollapsed"

    private(set) var isHiding = UserDefaults.standard.bool(forKey: hidingDefaultsKey)
    /// 정리 모드이거나 화면 밖 아이콘을 누르는 동안 잠깐 구분선을 풀어둔 상태 (저장하지 않음)
    private var isTemporarilyRevealed = false
    private let menu = NSMenu()
    private var hideMenuItem: NSMenuItem?
    private var warningsMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var themeMenuItems: [NotchTheme: NSMenuItem] = [:]
    private let hiddenPanel = HiddenItemsPanelController()
    private var restoreTimer: Timer?
    private var restoreStarted = Date()
    private var restorePID: pid_t = 0
    private var popupAppeared = false
    var onTestAlert: (() -> Void)?
    /// 노치를 펼쳤을 때 모양 (메뉴의 체크 표시와 선택)
    var currentTheme: (() -> NotchTheme)?
    var onSelectTheme: ((NotchTheme) -> Void)?

    override init() {
        super.init()
        toggleItem.autosaveName = "Cheoma.toggle"
        separatorItem.autosaveName = "Cheoma.separator"

        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        separatorItem.button?.image = Self.symbol("poweron")
        separatorItem.button?.appearsDisabled = true

        hiddenPanel.onSelect = { [weak self] item in self?.open(item) }
        // 숨기기가 꺼져 있으면 | 왼쪽 아이콘도 화면에 보이므로, 그때는 구분선 기준으로 나누지 않는다
        hiddenPanel.separatorX = { [weak self] in
            guard let self, isHiding || isTemporarilyRevealed else { return nil }
            return separatorItem.button?.window?.frame.minX
        }
        hiddenPanel.onEditingChanged = { [weak self] editing in self?.setEditing(editing) }
        hiddenPanel.onFinishEditing = { [weak self] in self?.finishEditing() }
        buildMenu()
        applyState()
    }

    private func buildMenu() {
        let showHidden = NSMenuItem(title: "가려진 아이콘 보기", action: #selector(toggleHiddenPanel), keyEquivalent: "")
        let hide = NSMenuItem(title: "| 왼쪽 아이콘 숨기기", action: #selector(toggleHiding), keyEquivalent: "h")
        hideMenuItem = hide
        let test = NSMenuItem(title: "노치 알림 테스트", action: #selector(testAlert), keyEquivalent: "t")
        let warnings = NSMenuItem(title: "경고 알림 (과열·메모리·배터리)", action: #selector(toggleWarnings), keyEquivalent: "")
        warningsMenuItem = warnings
        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        // 로그인 항목은 .app 번들로 실행할 때만 등록할 수 있다
        login.isHidden = Bundle.main.bundleIdentifier == nil
        loginMenuItem = login
        let themes = NSMenu()
        for theme in NotchTheme.allCases {
            let item = NSMenuItem(title: theme.title, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            themes.addItem(item)
            themeMenuItems[theme] = item
        }
        let themeItem = NSMenuItem(title: "노치 모양", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        let help = NSMenuItem(title: "⌘ 누른 채 아이콘을 | 왼쪽으로 끌면 숨겨져요", action: nil, keyEquivalent: "")
        help.isEnabled = false
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        for item in [showHidden, hide, test, warnings, login, themeItem, .separator(), help, .separator(), quit] {
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // 우클릭: 메뉴 띄우기
            hiddenPanel.hide()
            updateLoginItemState()
            warningsMenuItem?.state = WarningAlerts.isEnabled ? .on : .off
            let theme = currentTheme?() ?? .basic
            for (key, item) in themeMenuItems { item.state = key == theme ? .on : .off }
            toggleItem.menu = menu
            toggleItem.button?.performClick(nil)
            toggleItem.menu = nil
        } else {
            toggleHiddenPanel()
        }
    }

    @objc private func toggleHiddenPanel() {
        hiddenPanel.toggle(below: toggleItem.button?.window?.frame)
    }

    @objc private func toggleHiding() {
        setHiding(!isHiding)
    }

    func setHiding(_ hiding: Bool) {
        // 구분선이 토글 버튼 오른쪽에 있으면 토글 버튼까지 숨어버리므로 막는다
        if hiding, !separatorIsLeftOfToggle {
            NSSound.beep()
            return
        }
        isHiding = hiding
        UserDefaults.standard.set(hiding, forKey: Self.hidingDefaultsKey)
        applyState()
    }

    private var separatorIsLeftOfToggle: Bool {
        guard let sep = separatorItem.button?.window?.frame.minX,
              let toggle = toggleItem.button?.window?.frame.minX else { return false }
        return sep < toggle
    }

    /// 정리 모드: 구분선을 잠깐 보이게 해서 사용자가 메뉴바에서 직접 ⌘ 드래그로 정리하게 한다
    private func setEditing(_ editing: Bool) {
        isTemporarilyRevealed = editing
        applyState()
        // 구분선이 펼쳐지거나 접히면 아이콘 위치가 바뀌므로 다시 읽는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.hiddenPanel.refresh() }
    }

    /// "완료"를 눌렀을 때만: | 왼쪽에 아이콘이 있으면 숨기기를 켠다 (패널을 그냥 닫은 경우는 그대로 둔다)
    private func finishEditing() {
        guard !isHiding, let separator = separatorItem.button?.window?.frame.minX,
              MenuBarItemScanner.allItems().contains(where: { $0.frame.maxX <= separator + 1 }) else { return }
        setHiding(true)
    }

    // MARK: - 숨긴 아이콘 열기

    /// 노치 뒤의 아이콘(자리가 없어 macOS가 숨긴 것)은 화면 좌표 안에 있으므로 그대로 누르면 메뉴가 화면 안에 열린다.
    /// 구분선으로 화면 밖에 밀어둔 아이콘만 잠깐 구분선을 풀었다가 메뉴가 닫히면 되돌린다. 마우스는 움직이지 않는다.
    private func open(_ item: MenuBarItem) {
        let needsReveal = isHiding && !isTemporarilyRevealed && !Self.isOnAnyScreen(item.frame)
        if needsReveal {
            isTemporarilyRevealed = true
            applyState()
        }
        // 패널이 사라진 뒤에 눌러야 열린 메뉴가 바로 닫히지 않는다
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsReveal ? 0.3 : 0.15)) { [weak self] in
            item.press()
            if needsReveal { self?.restoreWhenPopupCloses(pid: item.pid) }
        }
    }

    private static func isOnAnyScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.minX <= frame.minX && frame.maxX <= $0.frame.maxX }
    }

    private func restoreWhenPopupCloses(pid: pid_t) {
        restoreTimer?.invalidate()
        restorePID = pid
        restoreStarted = Date()
        popupAppeared = false
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPopup() }
        }
        RunLoop.main.add(timer, forMode: .common)
        restoreTimer = timer
    }

    private func checkPopup() {
        let isOpen = Self.hasPopup(pid: restorePID)
        popupAppeared = popupAppeared || isOpen
        let elapsed = Date().timeIntervalSince(restoreStarted)
        // 메뉴가 떴다가 닫혔거나, 메뉴 대신 일반 창을 여는 앱이라 끝내 안 떴을 때 다시 숨긴다
        guard (popupAppeared && !isOpen) || (!popupAppeared && elapsed > 2) || elapsed > 600 else { return }
        restoreTimer?.invalidate()
        restoreTimer = nil
        isTemporarilyRevealed = false
        applyState()
    }

    /// 메뉴/팝오버는 일반 창(레이어 0)보다 높은 레이어로 뜬다. 창 목록의 위치·레이어는 화면 기록 권한 없이 읽힌다.
    private static func hasPopup(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
        }
    }

    private func applyState() {
        let hiding = isHiding && !isTemporarilyRevealed
        separatorItem.length = hiding ? Self.hidingLength : NSStatusItem.variableLength
        separatorItem.button?.image = hiding ? nil : Self.symbol("poweron")
        toggleItem.button?.image = Self.symbol("chevron.down")
        hideMenuItem?.state = isHiding ? .on : .off
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            AppLog.write("로그인 항목 설정 실패: \(error.localizedDescription)")
        }
        updateLoginItemState()
    }

    private func updateLoginItemState() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func testAlert() { onTestAlert?() }
    @objc private func toggleWarnings() { WarningAlerts.isEnabled.toggle() }
    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = NotchTheme(rawValue: raw) else { return }
        onSelectTheme?(theme)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

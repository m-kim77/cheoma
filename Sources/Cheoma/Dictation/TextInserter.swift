import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os
import UniformTypeIdentifiers

// 받아쓴 글을 지금 쓰는 앱에 넣는다.
// 클립보드에 글을 쓰고 ⌘V를 보내거나, Chromium · Electron 앱이면 메뉴 막대의 붙여넣기를 손쉬운 사용 API로 누른다.
// Cheoma 노치의 입력란이 키 창이면 클립보드를 거치지 않고 그 칸에 바로 넣는다.
// 보안 입력 중이거나 암호 칸이면 붙여 넣지 않고 클립보드에만 넣는다.

// MARK: - 어떻게 넣을지

/// 붙여 넣을 앱의 종류. Chromium · Electron 앱은 보낸 ⌘V를 가끔 놓친다 (Chromium 155~156)
enum DictationAppKind: Equatable, Sendable {
    case native, chromium, electron
}

/// 넣는 방법을 고른다. 화면 · 시스템 상태는 부르는 쪽이 살펴서 넘긴다
enum DictationInsertionPlanner {
    /// nil이면 붙여 넣지 않고 클립보드에만 넣는다 (암호 칸에는 절대 글을 넣지 않는다)
    static func route(method: DictationPasteMethod, ownPanelIsKey: Bool, isSecureInput: Bool,
                      focusedIsSecureField: Bool, appKind: DictationAppKind,
                      menuPasteAvailable: Bool) -> DictationInsertionRoute? {
        if ownPanelIsKey { return .ownPanel }
        if isSecureInput || focusedIsSecureField { return nil }
        switch method {
        case .clipboardOnly:
            return .clipboardOnly
        case .menu:
            return menuPasteAvailable ? .menuPaste : .commandV
        case .automatic:
            return appKind != .native && menuPasteAvailable ? .menuPaste : .commandV
        }
    }

    /// 메뉴 막대의 붙여넣기를 찾아볼지. 메뉴를 훑는 데 시간이 들어서 쓸 때만 찾는다
    static func needsMenuLookup(method: DictationPasteMethod, appKind: DictationAppKind) -> Bool {
        switch method {
        case .menu: true
        case .automatic: appKind != .native
        case .clipboardOnly: false
        }
    }
}

// MARK: - 앱 종류

extension DictationAppKind {
    /// Chromium을 품은 브라우저의 번들 ID 앞부분. 채널(.canary · .beta)과 설치한 웹 앱(.app.<id>)도 같은 앞부분이다
    static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "ai.perplexity.comet",
    ]

    /// 브라우저가 이름을 바꿔 넣는 Chromium 프레임워크 (Contents/Frameworks 안)
    static let chromiumFrameworkNames: Set<String> = [
        "Google Chrome Framework.framework", "Chromium Framework.framework", "Brave Browser Framework.framework",
        "Microsoft Edge Framework.framework", "Vivaldi Framework.framework", "Opera Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

    /// 이름을 모르는 "… Framework.framework"가 Chromium인지 알아보는 파일 (Resources 안)
    private static let chromiumResourceMarkers = ["icudtl.dat", "chrome_100_percent.pak"]

    private static let cache = OSAllocatedUnfairLock(initialState: [String: DictationAppKind]())

    static func of(_ app: NSRunningApplication) -> DictationAppKind {
        of(bundleURL: app.bundleURL, bundleIdentifier: app.bundleIdentifier)
    }

    /// 앱 묶음 경로마다 한 번만 살핀다
    static func of(bundleURL: URL?, bundleIdentifier: String?) -> DictationAppKind {
        guard let bundleURL else { return detect(bundleURL: nil, bundleIdentifier: bundleIdentifier) }
        let key = bundleURL.standardizedFileURL.path
        if let kind = cache.withLock({ $0[key] }) { return kind }
        let kind = detect(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
        cache.withLock { $0[key] = kind }
        return kind
    }

    /// 앱 묶음 안의 프레임워크로 가른다 (기억해 두지 않는다)
    static func detect(bundleURL: URL?, bundleIdentifier: String?) -> DictationAppKind {
        let fileManager = FileManager.default
        if let bundleURL {
            let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
            if fileManager.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
                return .electron
            }
            let names = (try? fileManager.contentsOfDirectory(atPath: frameworks.path)) ?? []
            let hasChromium = names.contains { name in
                name.hasSuffix(" Framework.framework")
                    && (chromiumFrameworkNames.contains(name) || hasChromiumResources(frameworks.appendingPathComponent(name)))
            }
            if hasChromium {
                // Electron은 프레임워크 이름을 바꿀 수 있다 (ChatGPT의 "Codex Framework"). 그래도 앱 코드는 app.asar에 있다
                let asar = bundleURL.appendingPathComponent("Contents/Resources/app.asar").path
                return fileManager.fileExists(atPath: asar) ? .electron : .chromium
            }
        }
        if let bundleIdentifier, chromiumBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return .chromium
        }
        return .native
    }

    private static func hasChromiumResources(_ framework: URL) -> Bool {
        let folders = ["Resources", "Versions/Current/Resources"].map { framework.appendingPathComponent($0) }
        return folders.contains { folder in
            chromiumResourceMarkers.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }
}

// MARK: - ⌘V 키

/// ⌘V로 보낼 키
enum DictationPasteKey {
    /// kVK_ANSI_V. 자판 정보를 못 읽으면 쓴다
    static let fallback = CGKeyCode(kVK_ANSI_V)
    /// 받아쓰기가 보낸 키 이벤트에 다는 표시 (eventSourceUserData). 단축키 감시가 이것을 보고 자기 ⌘V를 넘긴다
    static let eventMarker: Int64 = 0x4368_656F_6D61

    /// 지금 쓰는 ASCII 자판(2벌식이 켜져 있어도 영문 자판)에서 ⌘와 함께 "v"가 되는 키.
    /// TIS 함수는 메인 스레드가 아닌 곳에서 부르면 죽을 수 있어서 메인 스레드에서만 부른다
    @MainActor
    static func current() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return fallback }
        return resolve(layoutData: layoutData(of: source), keyboardType: UInt32(LMGetKbdType()))
    }

    static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// 자판 정보(uchr)에서 ⌘를 누른 채 "v"가 나오는 키를 찾는다. 9번이 맞으면 9번을 먼저 쓴다
    static func resolve(layoutData: Data?, keyboardType: UInt32) -> CGKeyCode {
        guard let layoutData, !layoutData.isEmpty else { return fallback }
        return layoutData.withUnsafeBytes { raw -> CGKeyCode in
            guard let base = raw.baseAddress else { return fallback }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            func typesV(_ key: CGKeyCode) -> Bool {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDisplay), UInt32(cmdKey >> 8) & 0xFF,
                                            keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, characters.count, &length, &characters)
                return status == noErr && length == 1 && characters[0] == UniChar(UInt8(ascii: "v"))
            }
            if typesV(fallback) { return fallback }
            return (0..<128).map { CGKeyCode($0) }.first(where: typesV) ?? fallback
        }
    }

    /// ⌘V를 누르고 뗀다. ⌘ 키 자체는 보내지 않고 두 이벤트에 플래그만 단다
    static func post(keyCode: CGKeyCode) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        }
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(10))
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - 손쉬운 사용 API

/// 키보드 입력을 받는 곳을 살핀다. 다른 앱이 늦게 답해도 오래 막히지 않게 기다리는 시간을 짧게 둔다
enum DictationFocus {
    static let messagingTimeout: Float = 0.25

    /// 키보드 입력을 받는 앱. 키를 받는 비활성 패널(Spotlight 같은)이 떠 있으면 메뉴 막대를 가진 앱과 다르다
    static func focusedApplicationPID() -> pid_t? {
        guard let app = element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success && pid > 0 ? pid : nil
    }

    /// 글을 받는 칸으로 보는 역할 (선택 범위를 알려 주지 않아도)
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// 지금 글자를 받는 칸: 암호 칸인지(AXSecureTextField), 글 칸인지, 커서 앞 글자, 앱이 제때 답했는지
    static func focusedElement(pid: pid_t) -> DictationFocusedElement {
        var result = DictationFocusedElement()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let (focusError, focusedValue) = copy(app, kAXFocusedUIElementAttribute)
        guard focusError == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            result.isSlow = focusError == .cannotComplete
            return result
        }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        let (subroleError, subrole) = copy(focused, kAXSubroleAttribute)
        if subrole as? String == kAXSecureTextFieldSubrole {
            result.isSecureField = true
            return result
        }
        // 바쁜 앱에는 더 묻지 않는다 (물을 때마다 기다리는 시간이 붙는다)
        let (roleError, role) = subroleError == .cannotComplete ? (subroleError, nil) : copy(focused, kAXRoleAttribute)
        guard roleError != .cannotComplete else {
            result.isSlow = true
            return result
        }
        let (rangeError, rangeValue) = copy(focused, kAXSelectedTextRangeAttribute)
        result.isSlow = rangeError == .cannotComplete
        var selection = CFRange()
        let hasRange = rangeError == .success && rangeValue.map {
            CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue, .cfRange, &selection)
        } == true
        // 역할을 답했는데 글 칸이 아니고 선택 범위도 없으면 붙여 넣어도 아무 일이 없다 (Finder 목록, 입력란 없는 웹 페이지)
        if roleError == .success, let role = role as? String { result.acceptsText = hasRange || textRoles.contains(role) }
        if hasRange { result.caret = caret(of: focused, before: selection.location) }
        return result
    }

    /// 커서(선택 범위의 시작) 바로 앞 글자
    private static func caret(of element: AXUIElement, before location: CFIndex) -> DictationCaret {
        guard location > 0 else { return location == 0 ? .atStart : .unknown }
        var range = CFRange(location: location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return .unknown }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let text = value as? String, let last = text.last else { return .unknown }
        return .after(last)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, AnyObject?) {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    /// 보안 입력(암호 칸, 터미널의 보안 키보드 입력 등)이 켜져 있는지. 시스템 전체 상태라 어느 앱이 켰는지는 secureInputHolderPID로 본다
    static var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// 보안 입력을 켠 프로세스 (모르면 nil)
    static var secureInputHolderPID: pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? NSNumber, pid.int32Value > 0 else { return nil }
        return pid.int32Value
    }

    /// 보안 입력 때문에 붙여 넣지 않을지. 켠 앱이 붙여 넣을 앱이거나 누가 켰는지 모를 때만 막는다.
    /// 뒤에 있는 앱이 켜 두었거나 켠 채로 남긴 것은 상관없다 (앞 앱의 암호 칸은 AXSecureTextField로 따로 막는다)
    static func secureInputBlocks(isEnabled: Bool, holder: pid_t?, target: pid_t?) -> Bool {
        guard isEnabled else { return false }
        guard let holder, let target else { return true }
        return holder == target
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ parent: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
}

/// 메뉴 막대의 붙여넣기. 메뉴 이름은 언어마다 달라서("편집", "수정") ⌘V 단축키가 붙은 항목을 찾는다
enum DictationMenuPaste {
    /// 앱 메뉴 막대에서 켜져 있는 ⌘V 항목을 찾는다. 누르지는 않는다
    static func findItem(pid: pid_t, budget: TimeInterval = 0.3) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(budget)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, DictationFocus.messagingTimeout)
        guard let bar = DictationFocus.element(app, kAXMenuBarAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(bar, DictationFocus.messagingTimeout)
        let barItems = DictationFocus.children(bar)
        for index in searchOrder(count: barItems.count) {
            guard Date() < deadline else { return nil }
            let barItem = barItems[index]
            AXUIElementSetMessagingTimeout(barItem, DictationFocus.messagingTimeout)
            for menu in DictationFocus.children(barItem) {
                AXUIElementSetMessagingTimeout(menu, DictationFocus.messagingTimeout)
                for item in DictationFocus.children(menu) where isEnabledPaste(item) {
                    return item
                }
            }
        }
        return nil
    }

    /// 메뉴 막대를 훑는 차례. 0번은 Apple 메뉴라 건너뛰고, 편집 메뉴가 보통 있는 3번(Apple · 앱 · 파일 · 편집)부터 본다
    static func searchOrder(count: Int) -> [Int] {
        let likely = [3, 2, 4, 1].filter { $0 < count }
        return likely + (1..<max(count, 1)).filter { !likely.contains($0) }
    }

    /// AXPress. .cannotComplete는 앱이 바빠 답이 늦은 것이라 눌린 것으로 본다 (다시 ⌘V를 보내면 두 번 붙을 수 있다)
    static func press(_ item: AXUIElement) -> AXError {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private static func isEnabledPaste(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, DictationFocus.messagingTimeout)
        let names = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [AnyObject], list.count == 3 else { return false }
        // 없는 속성은 오류 값으로 온다. 단축키 글자 "V" · 수식키 0(kAXMenuItemModifierNone, ⌘만) · 켜져 있음
        guard let character = list[0] as? String, character.uppercased() == "V",
              let modifiers = list[1] as? Int, modifiers == 0,
              let enabled = list[2] as? Bool else { return false }
        return enabled
    }
}

/// 손쉬운 사용 요소를 다른 스레드로 넘길 때 쓴다 (AX 함수는 어느 스레드에서 불러도 된다)
private struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

/// 커서 바로 앞
enum DictationCaret: Equatable, Sendable {
    case unknown
    /// 칸의 맨 앞
    case atStart
    case after(Character)
}

/// 키보드 입력을 받는 칸을 살핀 결과
struct DictationFocusedElement: Equatable, Sendable {
    var isSecureField = false
    /// 앱이 바빠 제때 답하지 못했다 (.cannotComplete). 보낸 ⌘V도 늦게 읽을 수 있다
    var isSlow = false
    /// 글을 받는 칸인지. nil이면 모른다 (손쉬운 사용 API가 답하지 않음)
    var acceptsText: Bool?
    var caret = DictationCaret.unknown
}

/// 붙여 넣을 곳을 살핀 결과
struct DictationTarget: @unchecked Sendable {
    var pid: pid_t?
    var appKind: DictationAppKind = .native
    var focus = DictationFocusedElement()
    /// 메뉴 막대의 붙여넣기 항목 (찾아볼 때만)
    var menuPasteItem: AXUIElement?

    var isSecureField: Bool { focus.isSecureField }

    /// 다른 앱에 묻는 일이라 메인 스레드 밖에서 한다.
    /// 메뉴 붙여넣기는 키를 받는 앱이 메뉴 막대도 가진 앱일 때만 쓴다 (아니면 엉뚱한 창에 붙는다)
    static func inspect(method: DictationPasteMethod, frontmostPID: pid_t?, menuBarOwnerPID: pid_t?) async -> DictationTarget {
        await Task.detached(priority: .userInitiated) {
            guard let pid = DictationFocus.focusedApplicationPID() ?? frontmostPID else { return DictationTarget() }
            let app = NSRunningApplication(processIdentifier: pid)
            var target = DictationTarget(pid: pid)
            target.appKind = DictationAppKind.of(bundleURL: app?.bundleURL, bundleIdentifier: app?.bundleIdentifier)
            target.focus = DictationFocus.focusedElement(pid: pid)
            if !target.isSecureField, pid == menuBarOwnerPID,
               DictationInsertionPlanner.needsMenuLookup(method: method, appKind: target.appKind) {
                target.menuPasteItem = DictationMenuPaste.findItem(pid: pid)
            }
            return target
        }.value
    }
}

// MARK: - 클립보드

/// 붙여 넣을 글을 클립보드에 쓰고, 붙여 넣은 뒤 원래 내용을 되돌린다.
/// 클립보드 내용을 읽으면 macOS가 "다른 앱에서 붙여넣기" 알림을 띄울 수 있어서, 읽어도 될 때(alwaysAllow)만 떠 둔다.
/// 그사이 다른 것이 복사됐는지는 내용을 읽지 않고 changeCount로 안다
@MainActor
final class DictationClipboard {
    struct Snapshot: Equatable {
        struct Entry: Equatable {
            let type: NSPasteboard.PasteboardType
            let data: Data
        }

        var items: [[Entry]]
    }

    /// nspasteboard.org 약속: 클립보드 관리 앱이 기록하지 않는다
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// 암호처럼 감출 것. 클립보드 관리 앱이 기록하지 않는다
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// 암호 관리 앱이 복사한 것 (잠시 뒤 스스로 지운다)
    private static let secretTypes: Set<NSPasteboard.PasteboardType> = [
        concealedType, transientType, NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]
    /// 원래 내용을 떠 둘 가장 큰 크기. 넘으면 되돌리지 않고 받아쓴 글을 남긴다
    nonisolated static let maximumSnapshotBytes = 8 << 20

    let pasteboard: NSPasteboard
    /// 붙여 넣고 원래 내용을 되돌리기까지 기다리는 시간 (앱이 클립보드를 다 읽을 때까지)
    var restoreDelay: Duration = .milliseconds(800)
    /// 원래 내용을 읽어도 되는지 정해 둔다 (nil이면 시스템 설정을 따른다). 테스트에서 쓴다
    var readsContentsOverride: Bool?
    /// 클립보드 읽기 허용 상태 (테스트에서 바꾼다)
    var accessProvider: () -> DictationClipboardAccess
    /// 되돌리기를 기다리는 중 (테스트에서 끝나기를 기다린다)
    private(set) var restoreTask: Task<Void, Never>?

    private struct Pending {
        let original: Snapshot
        /// 받아쓴 글을 쓴 직후의 changeCount. 그대로면 아직 우리 글이 들어 있다
        let changeCount: Int
    }

    private var pending: Pending?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        accessProvider = { DictationClipboard.access(of: pasteboard) }
    }

    /// 클립보드 내용을 읽어도 되는지 (내용은 읽지 않는다). macOS 15.4 전에는 알림이 없어서 늘 읽는다.
    /// 한 번도 읽으려 한 적이 없는 앱은 .default라 시스템 설정 목록에도 없다 (macOS 26부터는 읽으려 하면 macOS가 묻고 목록에 올린다)
    static func access(of pasteboard: NSPasteboard) -> DictationClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        if #available(macOS 26.0, *) { return access(behavior: pasteboard.accessBehavior, alertsOnRead: true) }
        return access(behavior: pasteboard.accessBehavior, alertsOnRead: false)
    }

    /// alertsOnRead: 읽으면 macOS가 묻는 창을 띄우는지. macOS 15.4~15에서는 개발자 미리보기로만 띄워서
    /// 묻는 창도 설정 목록도 없고 읽어도 조용하다 (.default가 바뀌지 않는다)
    @available(macOS 15.4, *)
    static func access(behavior: NSPasteboard.AccessBehavior, alertsOnRead: Bool) -> DictationClipboardAccess {
        switch behavior {
        case .alwaysAllow: return .allowed
        case .default: return alertsOnRead ? .notAsked : .allowed
        case .alwaysDeny: return .denied
        default: return .asks
        }
    }

    /// 원래 내용을 읽어도 되는지. 붙여 넣는 중에 macOS가 묻는 창을 띄우지 않게 늘 허용일 때만 읽는다
    var mayReadContents: Bool {
        if let readsContentsOverride { return readsContentsOverride }
        return accessProvider() == .allowed
    }

    /// 떠 두었다가 되돌려도 되는 내용인지 (형식 이름만 보고, 내용은 읽지 않는다).
    /// 암호 관리 앱이 복사한 것은 되돌리면 스스로 지우지 못하니 두지 않는다. 파일 약속은 만드는 데 오래 걸려서 떠 두지 않는다.
    /// 그림 · PDF는 항목마다 snapshotTypes가 가린다
    static func isRestorable(types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.contains { secretTypes.contains($0) || $0.rawValue.lowercased().contains("promise") }
    }

    /// 예전 이름의 그림 · PDF 형식
    private static let legacyVisualTypes: Set<NSPasteboard.PasteboardType> = [
        .init("NeXT TIFF v4.0 pasteboard type"), .init("Apple PDF pasteboard type"), .init("Apple PICT pasteboard type"),
    ]
    /// 내용 없이 붙어 다니는 표시 (nspasteboard.org)
    private static let markerTypes: Set<NSPasteboard.PasteboardType> = [sourceType, autoGeneratedType]

    /// 그림 · PDF 형식 (읽으면 만드는 데 오래 걸리고 큰 것)
    static func isVisual(_ type: NSPasteboard.PasteboardType) -> Bool {
        if legacyVisualTypes.contains(type) { return true }
        guard let uti = UTType(type.rawValue) else { return false }
        return uti.conforms(to: .image) || uti.conforms(to: .pdf)
    }

    /// 항목 하나에서 떠 둘 형식. 그림 · PDF는 가려 뜬다:
    /// 파일을 복사한 것(file-url)이면 그림은 Finder가 붙인 아이콘 · 미리보기라 빼고(파일 붙여넣기는 그대로 된다),
    /// 그림만 있는 것(화면 캡처 · 그림 복사)은 하나만 뜬다 (png → tiff → 처음 것).
    /// 글 · 서식과 그림 · PDF가 섞인 것(Office · iWork 개체)은 만드는 데 오래 걸려서 nil (되돌리지 않는다)
    static func snapshotTypes(of types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType]? {
        let visual = types.filter(isVisual)
        guard !visual.isEmpty else { return types }
        let others = types.filter { !isVisual($0) }
        if types.contains(.fileURL) { return others }
        guard others.allSatisfy(markerTypes.contains) else { return nil }
        let picked = visual.first { $0 == .png } ?? visual.first { $0 == .tiff } ?? visual[0]
        return [picked] + others
    }

    /// 붙여 넣으려고 글을 쓴다. restoring이고 읽어도 되면 원래 내용을 먼저 떠 두고 임시 표시를 단다.
    /// 앞의 받아쓰기 글이 아직 남아 있으면 그 전에 떠 둔 원래 내용을 이어받는다 (우리 글을 원래 내용으로 떠 두지 않게)
    func writeForPaste(_ text: String, restoring: Bool) -> Bool {
        cancelRestoreTask()
        var original: Snapshot?
        if restoring {
            if let pending, pending.changeCount == pasteboard.changeCount {
                original = pending.original
            } else if mayReadContents, Self.isRestorable(types: pasteboard.types ?? []) {
                original = snapshot()
            }
        }
        pending = nil
        guard let changeCount = write(text, transient: original != nil) else { return false }
        if let original { pending = Pending(original: original, changeCount: changeCount) }
        return true
    }

    /// 클립보드에 남길 글을 쓴다 (클립보드에만 넣기 · 붙여 넣지 않은 경우). 되돌리지 않는다.
    /// concealed면 암호일 수 있는 글이라 클립보드 관리 앱이 기록하지 않고 다른 기기와 나누지 않게 쓴다 (⌘V는 된다)
    func writeToKeep(_ text: String, concealed: Bool = false) -> Bool {
        cancelRestoreTask()
        pending = nil
        return write(text, transient: false, concealed: concealed) != nil
    }

    /// 붙여 넣은 뒤 부른다. 정해진 시간 뒤 그사이 다른 것이 복사되지 않았을 때만 원래 내용을 되돌린다
    func scheduleRestore() {
        guard let pending else { return }
        cancelRestoreTask()
        let delay = restoreDelay
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restore(pending)
        }
    }

    /// 되돌리지 않고 받아쓴 글을 클립보드에 남긴다 (붙여 넣지 못했을 때 직접 ⌘V 하도록)
    func keepWrittenText() {
        cancelRestoreTask()
        pending = nil
    }

    /// 되돌리기를 기다리는 원래 내용이 있는지
    var willRestore: Bool { pending != nil }

    /// 원래 내용을 떠 둔다 (그림 · PDF는 snapshotTypes가 고른 것만). maximumBytes를 넘거나 뜰 수 없는 항목이 있으면 nil (되돌리지 않는다)
    func snapshot(maximumBytes: Int = DictationClipboard.maximumSnapshotBytes) -> Snapshot? {
        var total = 0
        var items: [[Snapshot.Entry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let types = Self.snapshotTypes(of: item.types) else { return nil }
            var entries: [Snapshot.Entry] = []
            for type in types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= maximumBytes else { return nil }
                entries.append(Snapshot.Entry(type: type, data: data))
            }
            items.append(entries)
        }
        return Snapshot(items: items)
    }

    private func cancelRestoreTask() {
        restoreTask?.cancel()
        restoreTask = nil
    }

    private func restore(_ pending: Pending) {
        guard self.pending?.changeCount == pending.changeCount else { return }
        self.pending = nil
        restoreTask = nil
        // 그사이 사용자가 다른 것을 복사했으면 그대로 둔다
        guard pasteboard.changeCount == pending.changeCount else { return }
        pasteboard.clearContents()
        let items = pending.original.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !items.isEmpty { _ = pasteboard.writeObjects(items) }
    }

    /// 쓴 직후의 changeCount. 되돌릴 글과 감출 글은 다른 기기와 나누지 않는다 (Universal Clipboard)
    private func write(_ text: String, transient: Bool, concealed: Bool = false) -> Int? {
        if transient || concealed {
            _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return nil }
        if transient {
            item.setData(Data(), forType: Self.transientType)
            item.setData(Data(), forType: Self.autoGeneratedType)
        }
        if concealed { item.setData(Data(), forType: Self.concealedType) }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            item.setString(bundleIdentifier, forType: Self.sourceType)
        }
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }
}

// MARK: - 띄어쓰기

/// 마지막으로 넣은 받아쓰기
struct DictationLastInsertion: Equatable {
    var pid: pid_t
    var date: Date
    var endsWithSpace: Bool
}

/// 이어 받아쓸 때 앞 글과 붙지 않게 빈칸을 넣을지 정한다 ("고쳤어요.테스트도" → "고쳤어요. 테스트도")
enum DictationSpacing {
    /// 같은 앱에 이만큼 안에 다시 받아쓰면 이어 말한 것으로 본다 (커서 앞 글자를 모를 때만)
    static let continuationWindow: TimeInterval = 30

    /// 같은 앱에 방금 넣은 받아쓰기에 이어 말하는지 (커서 앞을 모를 때 빈칸을 넣을지 가린다).
    /// 그 뒤로 사용자가 키를 쳤으면(⏎로 보냄 · 다른 칸으로 옮김 · 고침) 이어 말한 것으로 보지 않는다
    static func continuesRecent(_ last: DictationLastInsertion?, pid: pid_t?, now: Date, lastTyped: Date?) -> Bool {
        guard let last, let pid, last.pid == pid, now.timeIntervalSince(last.date) < continuationWindow else { return false }
        if let lastTyped, lastTyped >= last.date { return false }
        return !last.endsWithSpace
    }

    /// 낱말 사이를 띄어 쓰는 언어인지 (일본어 · 중국어 · 태국어 …가 아니면)
    static func separatesWords(localeIdentifier: String) -> Bool {
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? ""
        return !["ja", "zh", "yue", "th", "lo", "my", "km"].contains(code)
    }

    /// 글 앞에 오면 앞 글자에 붙여 쓰는 것
    static let leadingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "…", "%",
                                                     "、", "。", "」", "』", "”", "’"]
    /// 이 뒤에는 빈칸을 넣는다 (글자 · 숫자 말고)
    static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "…", "%",
                                                      "」", "』", "”", "’"]

    /// 넣을 글 앞에 빈칸을 넣을지. 커서 앞이 글자 · 숫자 · 문장 부호면 넣고, 빈칸 · 줄바꿈 · 여는 괄호 뒤나 칸의 맨 앞이면 넣지 않는다.
    /// 커서 앞을 모르거나 테두리 같은 기호면(터미널) 같은 앱에 방금 넣은 받아쓰기에 이어 말할 때만 넣는다
    static func needsLeadingSpace(_ text: String, caret: DictationCaret, continuesRecent: Bool) -> Bool {
        guard let first = text.first, !first.isWhitespace, !leadingPunctuation.contains(first) else { return false }
        switch caret {
        case .atStart:
            return false
        case .unknown:
            return continuesRecent
        case .after(let previous):
            if previous.isWhitespace || "([{<“‘「『\"'".contains(previous) { return false }
            if previous.isLetter || previous.isNumber || trailingPunctuation.contains(previous) { return true }
            return continuesRecent
        }
    }
}

// MARK: - 넣기

/// 받아쓴 글을 넣는다. 방법을 고르고(DictationInsertionPlanner) 클립보드 · 키 · 메뉴를 다룬다
@MainActor
final class DictationTextInserter {
    let clipboard: DictationClipboard
    /// 클립보드에 쓰고 붙여넣기를 누르기까지 기다리는 시간 (앱이 바뀐 클립보드를 알아차리게)
    var pasteDelay: Duration = .milliseconds(40)

    /// 앞의 넣기가 끝나기를 기다린다 (클립보드를 번갈아 쓰지 않게)
    private var previous: Task<Void, Never>?
    /// 마지막으로 넣은 받아쓰기 (같은 앱에 이어 말하면 띄어 쓴다)
    private var lastInsertion: DictationLastInsertion?
    /// 사용자가 마지막으로 키를 친 때 (받아쓰기가 보낸 ⌘V는 빼고)
    private var lastTyped: Date?

    init(pasteboard: NSPasteboard = .general) {
        clipboard = DictationClipboard(pasteboard: pasteboard)
    }

    /// ownPanelIsKey: Cheoma 노치 입력란이 키 창이다. Cheoma 설정 창처럼 Cheoma가 앞에 있고 키 창이 있을 때도 그 칸에 바로 넣는다.
    /// 여러 번 부르면 차례대로 넣는다
    func insert(_ text: String, settings: DictationSettings, ownPanelIsKey: Bool) async -> DictationInsertionResult {
        let waitFor = previous
        let task = Task { @MainActor in
            await waitFor?.value
            return await self.insertNow(text, settings: settings, ownPanelIsKey: ownPanelIsKey)
        }
        previous = Task { _ = await task.value }
        return await task.value
    }

    private func insertNow(_ text: String, settings: DictationSettings, ownPanelIsKey: Bool) async -> DictationInsertionResult {
        guard !text.isEmpty else { return .failed("입력할 텍스트 없음") }
        let app = NSApp as NSApplication?
        let ownWindowIsKey = ownPanelIsKey || (app?.isActive == true && app?.keyWindow != nil)
        // 클립보드에만 넣을 때와 노치 입력란일 때는 다른 앱을 살피지 않는다
        var target = DictationTarget(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        if !ownWindowIsKey, settings.pasteMethod != .clipboardOnly {
            target = await DictationTarget.inspect(
                method: settings.pasteMethod,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                menuBarOwnerPID: NSWorkspace.shared.menuBarOwningApplication?.processIdentifier)
        }
        let secureInputEnabled = DictationFocus.isSecureInputEnabled
        let holder = secureInputEnabled ? DictationFocus.secureInputHolderPID : nil
        let route = DictationInsertionPlanner.route(
            method: settings.pasteMethod, ownPanelIsKey: ownWindowIsKey,
            isSecureInput: DictationFocus.secureInputBlocks(isEnabled: secureInputEnabled, holder: holder, target: target.pid),
            focusedIsSecureField: target.isSecureField, appKind: target.appKind,
            menuPasteAvailable: target.menuPasteItem != nil)
        let spaces = DictationSpacing.separatesWords(localeIdentifier: settings.localeIdentifier)

        switch route {
        case nil:
            // 암호일 수 있으니 클립보드 관리 앱이 기록하지 않고 다른 기기와 나누지 않게 넣는다
            return copyOnly(text, reason: Self.secureReason(isSecureField: target.isSecureField, holder: holder),
                            concealed: true)
        case .ownPanel:
            let pid = ProcessInfo.processInfo.processIdentifier
            let inserted = insertIntoKeyWindow { caret in
                spaces ? self.spaced(text, caret: caret, pid: pid) : text
            }
            guard let inserted else { return copyOnly(text, reason: "텍스트 입력란이 아니어서 클립보드에만 복사했습니다") }
            remember(inserted, pid: pid)
            return .inserted(.ownPanel)
        case .clipboardOnly:
            return clipboard.writeToKeep(text) ? .inserted(.clipboardOnly) : .failed("클립보드에 쓸 수 없음")
        case .commandV, .menuPaste:
            // 권한이 없으면 보낸 키가 소리 없이 버려진다
            guard AXIsProcessTrusted() else { return copyOnly(text, reason: "손쉬운 사용 권한이 없어 클립보드에만 복사했습니다") }
            let pasted = spaces ? spaced(text, caret: target.focus.caret, pid: target.pid) : text
            let restoring = Self.restoresClipboard(settings: settings, focus: target.focus)
            guard clipboard.writeForPaste(pasted, restoring: restoring) else { return .failed("클립보드에 쓸 수 없음") }
            if restoring, !clipboard.willRestore, clipboard.mayReadContents {
                AppLog.write("받아쓰기: 원래 클립보드를 되돌리지 않음 (떠 둘 수 없는 형식 · 크기)")
            }
            try? await Task.sleep(for: pasteDelay)
            var used = DictationInsertionRoute.commandV
            if route == .menuPaste, let item = target.menuPasteItem {
                let box = AXElementBox(element: item)
                let error = await Task.detached(priority: .userInitiated) { DictationMenuPaste.press(box.element) }.value
                if error == .cannotComplete {
                    // 앱이 바빠 아직 붙여 넣지 않았을 수 있다. 원래 내용을 되돌리면 그것이 붙으므로 받아쓴 글을 남긴다
                    clipboard.keepWrittenText()
                    remember(pasted, pid: target.pid)
                    return .inserted(.menuPaste)
                }
                // 누르지 못했으면 ⌘V로 한다
                if error == .success { used = .menuPaste }
            }
            if used == .commandV {
                guard await DictationPasteKey.post(keyCode: DictationPasteKey.current()) else {
                    clipboard.keepWrittenText()
                    return .failed("⌘V를 보낼 수 없음")
                }
            }
            // 앱이 바빠 보낸 ⌘V를 늦게 읽을 수 있거나 글 칸이 아니라 붙지 않았을 수 있으면, 되돌리지 않고 받아쓴 글을 남긴다
            // (되돌린 뒤에 읽으면 원래 내용이 붙고, 붙지 않았으면 받아쓴 글을 직접 ⌘V 할 수 있게)
            if restoring { clipboard.scheduleRestore() } else { clipboard.keepWrittenText() }
            remember(pasted, pid: target.pid)
            return .inserted(used)
        }
    }

    /// 붙여 넣은 뒤 원래 클립보드로 되돌릴지. 앱이 바빠 보낸 ⌘V를 늦게 읽을 수 있거나 글 칸이 아니면 되돌리지 않고,
    /// 받아쓴 글을 처음부터 보통 항목으로 쓴다 (임시 표시를 달면 클립보드 관리 앱이 기록하지 않아 직접 ⌘V 하기 전에 다른 것을 복사하면 잃는다)
    nonisolated static func restoresClipboard(settings: DictationSettings, focus: DictationFocusedElement) -> Bool {
        settings.restoresClipboard && !focus.isSlow && focus.acceptsText != false
    }

    /// 보안 입력 · 암호 칸이라 붙여 넣지 않은 까닭. 보안 입력을 켠 앱을 알면 이름을 댄다
    nonisolated static func secureReason(isSecureField: Bool, holder: pid_t?) -> String {
        if isSecureField { return "암호 필드여서 클립보드에만 복사했습니다" }
        if let holder, holder != ProcessInfo.processInfo.processIdentifier,
           let name = NSRunningApplication(processIdentifier: holder)?.localizedName, !name.isEmpty {
            return "\(name)의 보안 입력이 켜져 있어 클립보드에만 복사했습니다"
        }
        return "보안 입력이 켜져 있어 클립보드에만 복사했습니다"
    }

    private func copyOnly(_ text: String, reason: String, concealed: Bool = false) -> DictationInsertionResult {
        clipboard.writeToKeep(text, concealed: concealed) ? .copiedOnly(reason: reason) : .failed("클립보드에 쓸 수 없음")
    }

    /// 사용자가 키를 쳤다 (단축키 감시가 알린다)
    func userTyped(at date: Date = Date()) {
        lastTyped = date
    }

    /// 커서 앞에 글자가 붙어 있으면 빈칸을 앞에 넣는다
    private func spaced(_ text: String, caret: DictationCaret, pid: pid_t?) -> String {
        let continuesRecent = DictationSpacing.continuesRecent(lastInsertion, pid: pid, now: Date(), lastTyped: lastTyped)
        return DictationSpacing.needsLeadingSpace(text, caret: caret, continuesRecent: continuesRecent) ? " " + text : text
    }

    private func remember(_ text: String, pid: pid_t?) {
        guard let pid else { return }
        lastInsertion = DictationLastInsertion(pid: pid, date: Date(), endsWithSpace: text.last?.isWhitespace ?? false)
    }

    /// 키 창의 글 칸(NSTextView · 필드 편집기)에 바로 넣는다. 조합 중인 한글은 확정하고 그 뒤에 넣는다.
    /// textFor는 커서 앞을 보고 넣을 글을 정한다. 넣은 글을 돌려준다 (글 칸이 아니면 nil)
    private func insertIntoKeyWindow(_ textFor: (DictationCaret) -> String) -> String? {
        guard let window = (NSApp as NSApplication?)?.keyWindow, let responder = window.firstResponder else { return nil }
        if let textView = responder as? NSTextView {
            guard textView.isEditable else { return nil }
            if textView.hasMarkedText() {
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
            }
            let text = textFor(Self.caret(in: textView))
            textView.insertText(text, replacementRange: textView.selectedRange())
            return text
        }
        if let client = responder as? NSTextInputClient {
            let text = textFor(.unknown)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return text
        }
        return nil
    }

    private static func caret(in textView: NSTextView) -> DictationCaret {
        let location = textView.selectedRange().location
        let string = textView.string as NSString
        guard location != NSNotFound, location <= string.length else { return .unknown }
        guard location > 0 else { return .atStart }
        let range = string.rangeOfComposedCharacterSequence(at: location - 1)
        return string.substring(with: range).last.map(DictationCaret.after) ?? .unknown
    }
}

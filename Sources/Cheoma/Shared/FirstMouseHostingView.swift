import AppKit
import SwiftUI

/// 키 윈도우가 되지 않는 패널에서는 모든 클릭이 "첫 클릭"이다. 첫 클릭도 바로 버튼에 전달되게 한다.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        HostingLayoutCounter.count += 1
        super.layout()
    }
}

/// SwiftUI가 창을 다시 배치한 횟수. `--bench`가 초당 몇 번인지 보고 배치가 끝없이 반복되는지 찾는다
/// (제네릭 클래스에는 static 저장 프로퍼티를 둘 수 없어서 따로 둔다)
enum HostingLayoutCounter {
    @MainActor static var count = 0
}

/// 키 포커스를 뺏지 않는 투명 패널.
/// `acceptsKeyFocus`를 켜 둔 동안만 키 창이 될 수 있다 (노치의 에이전트 탭에서 답을 입력할 때).
/// `.nonactivatingPanel`이라 키 창이 되어도 Cheoma가 앞으로 나오지 않고, 쓰던 앱은 그대로 활성 상태로 남는다 (Spotlight처럼)
final class OverlayPanel: NSPanel {
    /// 글자 입력을 받아야 할 때만 켠다. 꺼져 있으면 예전처럼 절대 키 창이 되지 않는다
    var acceptsKeyFocus = false

    override var canBecomeKey: Bool { acceptsKeyFocus }
    override var canBecomeMain: Bool { false }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 버튼을 누르는 것만으로는 키 창이 되지 않게 한다 (키 창이 되는 건 글자 칸에 들어갈 때뿐)
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// 키 창이 되어 글자를 받는다. 쓰던 앱은 활성 상태 그대로다
    func takeKeyFocus() {
        guard acceptsKeyFocus, !isKeyWindow else { return }
        makeKey()
    }

    /// 키 창 자리를 내놓아 키보드 입력이 원래 쓰던 앱으로 돌아가게 한다.
    /// 키 창을 그만두는 공개 API가 없어서, 잠깐 내렸다가 키는 받지 않고 다시 올린다 (같은 차례 안이라 깜빡이지 않는다)
    func giveUpKeyFocus() {
        guard isKeyWindow else { return }
        makeFirstResponder(nil)
        let wasVisible = isVisible
        let savedAnimation = animationBehavior
        animationBehavior = .none
        orderOut(nil)
        if wasVisible { orderFrontRegardless() }
        animationBehavior = savedAnimation
    }

    // 메뉴바 앱이라 편집 메뉴가 없어서 ⌘C · ⌘V 같은 단축키가 글자 칸에 닿지 않는다. 직접 보내 준다
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isKeyWindow, flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = switch (key, flags == .command) {
            case ("x", true): #selector(NSText.cut(_:))
            case ("c", true): #selector(NSText.copy(_:))
            case ("v", true): #selector(NSText.paste(_:))
            case ("a", true): #selector(NSText.selectAll(_:))
            case ("z", true): Selector(("undo:"))
            case ("z", false): Selector(("redo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 노치 화면에서 키 포커스를 달라고 · 돌려주겠다고 알리는 방법

    static let requestKeyFocusNotification = Notification.Name("OverlayPanel.requestKeyFocus")
    static let releaseKeyFocusNotification = Notification.Name("OverlayPanel.releaseKeyFocus")

    /// SwiftUI 쪽에서 부른다. 노치 창 컨트롤러가 받아서 키 창으로 만든다
    static func requestKeyFocus() {
        NotificationCenter.default.post(name: requestKeyFocusNotification, object: nil)
    }

    static func releaseKeyFocus() {
        NotificationCenter.default.post(name: releaseKeyFocusNotification, object: nil)
    }
}

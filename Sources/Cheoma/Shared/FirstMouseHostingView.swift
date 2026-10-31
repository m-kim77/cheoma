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

/// 키 포커스를 뺏지 않는 투명 패널
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

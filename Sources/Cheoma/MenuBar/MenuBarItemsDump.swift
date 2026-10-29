import AppKit

/// `Cheoma --menubar-items`: 메뉴바 아이콘 목록과 가려짐 여부 출력 (검증용)
@MainActor
enum MenuBarItemsDump {
    static func run() {
        guard MenuBarItemScanner.hasPermission else {
            print("손쉬운 사용 권한 없음")
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let region = MenuBarItemScanner.VisibleRegion(screen: screen)
        print("screen x \(region.screen)  notch \(region.notch.map { "\($0)" } ?? "없음")")
        let hidden = Set(MenuBarItemScanner.hiddenItems(in: region).map(\.id))
        for item in MenuBarItemScanner.allItems() {
            let mark = hidden.contains(item.id) ? "가려짐" : "보임  "
            print("\(mark)  x \(Int(item.frame.minX))…\(Int(item.frame.maxX))  \(item.appName) — \(item.label)")
        }
    }
}

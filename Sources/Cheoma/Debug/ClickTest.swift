#if DEBUG
import AppKit
import SwiftUI

/// `Cheoma --click-test`: 노치와 같은 패널을 화면 밖에 띄우고, 버튼 위치를 손쉬운 사용 정보로 찾아 클릭 이벤트를 창에 바로 넣어 본다 (개발용).
/// 마우스 커서는 움직이지 않는다. 버튼 위치는 `--render` 그림에서 잰 값이다. 에이전트 탭의 버튼이 눌리는지 확인하려고 만들었다
@MainActor
enum ClickTest {
    static func run() {
        // `--render` 그림(같은 창 크기, 노치 220×38)에서 잰 버튼 가운데 (창 왼쪽 위 기준 pt). 버튼마다 새 창에서 누른다
        let targets: [(String, CGPoint)] = [
            ("톱니", CGPoint(x: 846, y: 107)),
            ("새 에이전트 (+)", CGPoint(x: 814, y: 107)),
            ("계정", CGPoint(x: 782, y: 107)),
            ("사용량 카드", CGPoint(x: 560, y: 107)),
            ("왼쪽 목록 첫 줄", CGPoint(x: 260, y: 160)),
            ("최근 기록 첫 줄", CGPoint(x: 242, y: 306)),
            ("탭: 개요", CGPoint(x: 450, y: 63)),
        ]
        if CommandLine.arguments.contains("--hit") {
            hitMap()
            return
        }
        // `--at x,y x,y …`: 그 자리들을 눌러 본다
        if let index = CommandLine.arguments.firstIndex(of: "--at") {
            for text in CommandLine.arguments.dropFirst(index + 1) {
                let numbers = text.split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 2 else { break }
                test(text, at: CGPoint(x: numbers[0], y: numbers[1]))
            }
            return
        }
        if CommandLine.arguments.contains("--grid") {
            // 새 에이전트 버튼 둘레를 촘촘히 눌러 본다
            for y in stride(from: 92.0, through: 118.0, by: 6.0) {
                for x in stride(from: 728.0, through: 824.0, by: 12.0) { test("(\(Int(x)),\(Int(y)))", at: CGPoint(x: x, y: y)) }
            }
            return
        }
        for (name, point) in targets { test(name, at: point) }
    }

    /// 창 곳곳에서 클릭을 받을 AppKit 뷰가 무엇인지 찍는다 (호스팅 뷰가 아니면 그 뷰가 클릭을 가로챈다)
    private static func hitMap() {
        let model = NotchModel()
        let stats = StatsStore(savesHistory: false)
        let agents = AgentStore.preview()
        model.notchSize = CGSize(width: 220, height: 38)
        model.previewOpen(.agents)
        let size = CGSize(width: NotchModel.maxOpenSize.width + 60, height: NotchModel.maxOpenSize.height + 40)
        let panel = OverlayPanel(size: size)
        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, stats: stats, fans: FanController(), agents: agents))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        panel.orderFrontRegardless()
        settle()
        var names: [String: Character] = [:]
        for y in stride(from: 40.0, through: 440.0, by: 10.0) {
            var row = ""
            for x in stride(from: 120.0, through: 890.0, by: 10.0) {
                let hit = hosting.hitTest(CGPoint(x: x, y: size.height - y))
                let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
                if hit === hosting { row.append("."); continue }
                if names[name] == nil { names[name] = Character(String(names.count)) }
                row.append(names[name]!)
            }
            print(String(format: "%3.0f ", y) + row)
        }
        for (name, mark) in names.sorted(by: { $0.value < $1.value }) { print("\(mark) = \(name)") }
        for view in hosting.subviews { print("subview \(type(of: view)) frame \(view.frame)") }
        panel.orderOut(nil)
    }

    private static func test(_ name: String, at point: CGPoint) {
        let model = NotchModel()
        let stats = StatsStore(savesHistory: false)
        let fans = FanController()
        let agents = AgentStore.preview()
        model.notchSize = CGSize(width: 220, height: 38)
        model.theme = .basic
        model.previewOpen(.agents)
        AgentsTab.debugPane = nil

        let size = CGSize(width: NotchModel.maxOpenSize.width + 60, height: NotchModel.maxOpenSize.height + 40)
        let panel = OverlayPanel(size: size)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        let hosting = FirstMouseHostingView(rootView: NotchView(model: model, stats: stats, fans: fans, agents: agents))
        hosting.sizingOptions = []
        panel.contentView = hosting
        // 화면 밖 (보이지 않게)
        panel.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        panel.ignoresMouseEvents = false
        panel.acceptsKeyFocus = CommandLine.arguments.contains("--key")
        panel.orderFrontRegardless()
        settle()
        let selected = agents.selectedID
        click(at: CGPoint(x: point.x, y: size.height - point.y), panel: panel)
        settle()
        print("\(name): 오른쪽 \(AgentsTab.debugPane.map { "\($0)" } ?? "그대로") · 탭 \(model.tab)"
              + " · 세션 \(agents.selectedID == selected ? "그대로" : agents.selectedID ?? "-") · 알림 \(agents.message ?? "-") · 키 창 \(panel.isKeyWindow)")
        panel.orderOut(nil)
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private static func click(at point: CGPoint, panel: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
            panel.sendEvent(event)
        }
    }
}
#endif

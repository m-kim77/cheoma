import Combine
import SwiftUI
import XCTest
@testable import Cheoma

@MainActor
final class NotchAlertQueueTests: XCTestCase {
    private let info = NotchAlert(symbol: "lock.open.fill", tint: .cyan, text: "잠금 해제")
    private let charger = NotchAlert(symbol: "bolt.fill", tint: .green, text: "충전 중")
    private let heat = WarningAlerts.thermal(.critical)!
    private let battery = WarningAlerts.battery(level: 10)

    func testWarningReplacesInformation() {
        let model = NotchModel()
        model.show(info)
        model.show(heat)
        XCTAssertEqual(model.alert, heat)
        model.alertFinished()
        // 밀려난 정보성 알림은 다시 띄우지 않는다
        XCTAssertNil(model.alert)
    }

    /// 예전에는 배터리 경고 직후 잠금 해제 알림이 오면 경고가 덮였고, 쿨다운 때문에 다시 뜨지도 않았다
    func testInformationWaitsForWarning() {
        let model = NotchModel()
        model.show(battery)
        model.show(info)
        XCTAssertEqual(model.alert, battery)
        model.alertFinished()
        XCTAssertEqual(model.alert, info)
        model.alertFinished()
        XCTAssertNil(model.alert)
    }

    func testWarningsTakeTurnsBeforeInformation() {
        let model = NotchModel()
        model.show(battery)
        model.show(info)
        model.show(heat)
        model.alertFinished()
        XCTAssertEqual(model.alert, heat)
        model.alertFinished()
        XCTAssertEqual(model.alert, info)
    }

    func testNewestInformationWins() {
        let model = NotchModel()
        model.show(info)
        model.show(charger)
        XCTAssertEqual(model.alert, charger)
        model.alertFinished()
        XCTAssertNil(model.alert)
    }

    func testOpensOnceAfterDelayWhileMouseKeepsMoving() {
        let model = NotchModel()
        let opened = expectation(description: "열림")
        let observation = model.$isOpen.dropFirst().sink { if $0 { opened.fulfill() } }
        // 0.6초 동안 마우스를 계속 움직여도 들어온 순간부터 재서 0.18초 뒤에 열린다
        // (예전에는 움직일 때마다 다시 재서 멈춘 뒤에야 열렸다)
        for step in 0..<12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.05) {
                model.updateMouse(inHotZone: true, inOpenZone: true)
            }
        }
        wait(for: [opened], timeout: 0.45)
        observation.cancel()
    }
}

/// 에이전트 탭 글자 크기와 탭 크기
@MainActor
final class NotchModelAgentsSizeTests: XCTestCase {
    private func withSizeDefaults(_ test: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["agents.baseSize", "agents.size", AgentsTextScale.defaultsKey, "dashboardTab", "notchTheme"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        try test()
    }

    func testLegacySizeIsConvertedOnlyOnce() {
        withSizeDefaults {
            let defaults = UserDefaults.standard
            defaults.set("{1170, 650}", forKey: "agents.size")
            defaults.set(1.3, forKey: AgentsTextScale.defaultsKey)
            let model = NotchModel()
            model.agentsTextScale = .normal
            XCTAssertEqual(model.agentsSize, CGSize(width: 900, height: 500))
            XCTAssertEqual(NotchModel().agentsSize, model.agentsSize)
        }
    }

    func testDragResizeHandleInPanel() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "WindowServer가 있어야 노치 패널의 마우스 입력을 확인할 수 있다")
        try withSizeDefaults {
            for theme in NotchTheme.allCases {
                let model = NotchModel()
                model.theme = theme
                model.resetAgentsSize()
                model.previewOpen(.agents)
                let panel = OverlayPanel(size: CGSize(width: 1400, height: 950))
                let root = NotchView(model: model, stats: StatsStore(savesHistory: false), fans: FanController(), agents: .preview())
                let hosting = FirstMouseHostingView(rootView: root)
                hosting.sizingOptions = []
                panel.contentView = hosting
                panel.setFrameOrigin(CGPoint(x: -6000, y: -6000))
                panel.orderFrontRegardless()
                defer { panel.orderOut(nil) }
                @MainActor func gripCenter() -> CGPoint {
                    let top = theme == .basic ? 0 : Gwanghwamun.contentTop(content: model.dashboardSize)
                    return CGPoint(x: hosting.bounds.midX + model.dashboardSize.width / 2 - NotchShape.openEave - 12 - 44,
                                   y: hosting.bounds.maxY - top - model.dashboardSize.height + 4 + 14)
                }
                @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
                    panel.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let start = gripCenter()
                try send(.leftMouseDown, start)
                XCTAssertTrue(model.isResizing)
                model.updateMouse(inHotZone: false, inOpenZone: false)
                XCTAssertTrue(model.isOpen)
                let out = CGPoint(x: start.x + 36, y: start.y - 38)
                try send(.leftMouseDragged, out)
                XCTAssertEqual(model.agentsSize.width, 832)
                XCTAssertEqual(gripCenter().y, out.y, accuracy: 1)
                let small = CGPoint(x: start.x - 80, y: start.y + 140)
                try send(.leftMouseDragged, small)
                try send(.leftMouseUp, small)
                XCTAssertFalse(model.isResizing)
                XCTAssertEqual(model.agentsSize, NotchModel.compactAgentsSize)
                XCTAssertFalse(model.isAgentsSizeDefault)
                XCTAssertEqual(NotchModel().agentsSize, model.agentsSize)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let compactGrip = gripCenter()
                try send(.leftMouseDown, compactGrip, clicks: 2)
                try send(.leftMouseUp, compactGrip, clicks: 2)
                XCTAssertEqual(model.agentsSize, DashboardTab.agents.openSize)
                XCTAssertTrue(model.isAgentsSizeDefault)
                XCTAssertFalse(model.isResizing)
            }
        }
    }

    /// 연결 설정에서 글자를 키웠다 줄이기를 되풀이해도 탭이 계속 커지지 않는다
    func testTextScaleRoundTripKeepsSize() {
        let model = NotchModel()
        let savedTheme = model.theme, savedScale = model.agentsTextScale, savedSize = model.agentsSize
        defer {
            model.theme = savedTheme
            model.agentsTextScale = savedScale
            model.resizeAgents(to: savedSize)
        }
        model.theme = .basic
        model.agentsTextScale = .normal
        model.resizeAgents(to: CGSize(width: 900, height: 500))
        for _ in 0..<3 {
            model.agentsTextScale = .largest
            XCTAssertEqual(model.agentsSize, CGSize(width: 1350, height: 750))
            model.agentsTextScale = .normal
            XCTAssertEqual(model.agentsSize, CGSize(width: 900, height: 500))
        }
        // 키운 상태에서 끌어 바꾼 크기도 줄이면 같은 비율로 줄어든다
        model.agentsTextScale = .larger
        model.resizeAgents(to: CGSize(width: 1300, height: 650))
        model.agentsTextScale = .normal
        XCTAssertEqual(model.agentsSize, CGSize(width: 1000, height: 500))
    }
}

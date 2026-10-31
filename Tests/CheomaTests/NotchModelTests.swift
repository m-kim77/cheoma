import Combine
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

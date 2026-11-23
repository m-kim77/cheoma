import AppKit
import Combine
import XCTest
@testable import Cheoma

/// 바뀐 게 없는 동안에는 뷰를 다시 그릴 일을 만들지 않는다 (대기 중 CPU · 메모리)
@MainActor
final class IdleCostTests: XCTestCase {
    /// 입력을 기다리는 Claude 세션 하나. 화면은 몇 초마다 새로 읽으므로 같은 글자가 매번 다시 들어온다
    private func result(at date: Date, screen text: String = "❯ ") -> AgentStore.PollResult {
        let item = AgentStore.PollItem(
            id: "tmux:%1", kind: .claude, location: .tmux(paneID: "%1", tty: "/dev/ttys001"), cwd: nil,
            startedAt: nil, isLaunchedByCheoma: false, hasAgentProcess: true, isActive: false, agentStatus: "idle",
            screen: TerminalScreen(text: text),
            analysis: ScreenAnalysis(state: .needsInput, question: nil, choices: [], summary: nil))
        return AgentStore.PollResult(date: date, items: [item], usage: nil, permission: nil, error: nil)
    }

    func testUnchangedPollDoesNotPublish() {
        let store = AgentStore()
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        let start = Date()
        store.apply(result(at: start))
        XCTAssertEqual(store.sessions.map(\.id), ["tmux:%1"])
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
        XCTAssertGreaterThan(published, 0)

        published = 0
        store.apply(result(at: start.addingTimeInterval(3)))
        store.apply(result(at: start.addingTimeInterval(6)))
        XCTAssertEqual(published, 0)
    }

    func testChangedScreenStillPublishes() {
        let store = AgentStore()
        let start = Date()
        store.apply(result(at: start))
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        store.apply(result(at: start.addingTimeInterval(3), screen: "❯ git status"))
        XCTAssertGreaterThan(published, 0)
        XCTAssertEqual(store.sessions.first?.screen?.text, "❯ git status")
    }

    /// 닫은 설정 창을 들고 있으면 보이지 않는데도 AgentStore가 바뀔 때마다 탭 네 개를 다시 계산한다
    func testClosedSettingsWindowIsReleased() {
        _ = NSApplication.shared
        let model = NotchModel()
        let controller = SettingsWindowController(model: model, agents: AgentStore(), updates: UpdateChecker(current: nil),
                                                  dictation: .forTests(notch: model))
        weak var window: NSWindow?
        weak var content: NSViewController?
        autoreleasepool {
            let loaded = controller.loadWindow()
            window = loaded
            content = loaded.contentViewController
            XCTAssertNotNil(content)
            loaded.close()
        }
        // 내용은 닫힌 다음 차례에 뗀다
        for _ in 0..<5 {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        XCTAssertNil(content)
        XCTAssertNil(window)

        // 다시 열면 새로 만든다
        autoreleasepool { XCTAssertNotNil(controller.loadWindow().contentViewController) }
    }
}

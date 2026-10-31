import Foundation

/// `Cheoma --agents`: 찾은 에이전트 프로세스와 터미널 위치·상태를 출력한다 (개발용).
/// `--capture`를 붙이면 에이전트가 도는 tmux 패널의 마지막 줄과 화면 분석 결과도 보여준다. `--selftest`는 연동 모듈 자체 확인.
/// Terminal에는 Apple Event를 보내지 않는다 (켜져 있는지만 본다): 아무도 보지 않는 권한 창이 뜨지 않게
enum AgentsDump {
    static func run() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            exit(AgentsSelfTest.run() ? 0 : 1)
        }
        if arguments.contains("--store") {
            MainActor.assumeIsolated { dumpStore() }
            return
        }
        let showCapture = arguments.contains("--capture")

        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let agents = AgentScanner.scan()
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        print("에이전트 \(agents.count)개 (찾는 데 \(String(format: "%.1f", elapsed))ms)")
        for agent in agents {
            let age = agent.startedAt.map { duration(Date().timeIntervalSince($0)) } ?? "?"
            print("  pid \(agent.pid)  \(agent.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
                  + "  tty \(agent.tty ?? "-")  host \(agent.hostApp ?? "-")  \(age) 전 시작")
            print("      cwd \(agent.cwd ?? "-")")
        }

        let tmux = TmuxBridge.shared
        print("\ntmux: \(tmux.executable ?? "없음")")
        var panes: [TmuxPane] = []
        do {
            panes = try tmux.panes()
            if panes.isEmpty { print("  패널 없음 (서버가 꺼져 있거나 세션이 없어요)") }
            for pane in panes {
                print("  \(pane.paneID)  \(pane.target)  \(pane.tty)  pid \(pane.pid)  \(pane.currentCommand)  \(pane.currentPath)"
                      + (pane.clientTTYs.isEmpty ? "" : "  클라이언트 \(pane.clientTTYs.joined(separator: ", "))"))
            }
        } catch {
            print("  오류: \(error.localizedDescription)")
        }

        print("\nTerminal.app: \(TerminalAppBridge.shared.isRunning ? "켜져 있음" : "꺼져 있음") (탭은 읽지 않음)")

        let ttys = Set(agents.compactMap(\.tty) + panes.map(\.tty)).sorted()
        if !ttys.isEmpty {
            print("\n마지막 출력")
            for tty in ttys {
                let age = AgentScanner.lastOutput(tty: tty).map { duration(Date().timeIntervalSince($0)) + " 전" } ?? "?"
                print("  \(tty)  \(age)")
            }
        }

        guard showCapture else { return }
        let agentTTYs = Set(agents.compactMap(\.tty))
        for pane in panes where agentTTYs.contains(pane.tty) {
            print("\n── \(pane.paneID) \(pane.target) ──")
            do {
                let screen = try tmux.capture(.tmux(paneID: pane.paneID, tty: pane.tty))
                print(ANSIText.plain(screen.text).split(separator: "\n", omittingEmptySubsequences: false).suffix(15).joined(separator: "\n"))
                let kind = agents.first { $0.tty == pane.tty }?.kind ?? .claude
                let analysis = AgentScreenParser.analyze(screen, kind: kind)
                print("→ \(analysis.state.title)" + (analysis.question.map { " · \($0)" } ?? ""))
                for choice in analysis.choices {
                    print("   \(choice.isHighlighted ? "▶" : " ") \(choice.key.isEmpty ? "↕" : choice.key)  \(choice.label)")
                }
                if let summary = analysis.summary { print("   요약 \(summary)") }
            } catch {
                print("  오류: \(error.localizedDescription)")
            }
        }
    }

    /// `--agents --store`: 앱과 같은 AgentStore를 몇 초 돌려서 에이전트 탭 왼쪽 목록에 나올 내용을 찍는다
    @MainActor
    private static func dumpStore() {
        let store = AgentStore()
        store.isVisible = true
        store.start()
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        print("세션 \(store.sessions.count)개 (목록 순서대로)")
        for session in store.sessions {
            print("  \(session.id)  \(session.kind.rawValue)  \(session.account ?? "")  \(session.state.title)  \(session.projectName)"
                  + "  · \(session.title ?? session.analysis?.summary ?? "-")")
        }
        print("최근 기록 \(store.recordedSessions.count)개")
        for record in store.recordedSessions {
            print("  \(record.kind.rawValue)  \(record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")  · \(record.title ?? "-")  \(record.id.prefix(8))")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(max(seconds, 0))
        if value < 60 { return "\(value)초" }
        if value < 3_600 { return "\(value / 60)분" }
        if value < 86_400 { return "\(value / 3_600)시간 \(value % 3_600 / 60)분" }
        return "\(value / 86_400)일"
    }
}

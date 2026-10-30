import Foundation

/// 터미널 화면을 보고 에이전트가 무엇을 기다리는지 읽는다 (순수 함수). 구현 예정:
/// 에이전트마다 작업 중 표시, 허락 · 선택지 목록, 빈 입력창을 알아보고, 모르는 화면은 일반 규칙으로 판단한다.
enum AgentScreenParser {
    /// 화면 한 장을 분석한다. 몇 초마다 부르므로 1ms 안에 끝나야 한다
    static func analyze(_ screen: TerminalScreen, kind: AgentKind) -> ScreenAnalysis {
        let lines = ANSIText.plain(screen.text)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ScreenAnalysis(state: .unknown, question: nil, choices: [], summary: lines.last)
    }
}

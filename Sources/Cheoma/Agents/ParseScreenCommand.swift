import Foundation

/// `Cheoma --parse-screen <파일> [claude|codex|opencode|pi]`: 저장해 둔 화면을 분석한 결과를 출력한다 (개발용). 구현 예정
enum ParseScreenCommand {
    static func run(arguments: [String]) {
        guard let path = arguments.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("사용법: Cheoma --parse-screen <화면 파일> [claude|codex|opencode|pi]")
            return
        }
        let kind = arguments.dropFirst().first.flatMap(AgentKind.init) ?? .claude
        let analysis = AgentScreenParser.analyze(TerminalScreen(text: text, capturedAt: Date()), kind: kind)
        print(analysis)
    }
}

import Foundation

/// `Cheoma --parse-screen <파일 또는 폴더> [claude|codex|opencode|pi]`: 저장해 둔 화면을 분석한 결과를 출력한다 (개발용).
/// 에이전트를 안 적으면 파일 이름 앞부분("codex-idle.txt" → codex)으로 정한다. 폴더를 주면 안의 .txt를 모두 본다
enum ParseScreenCommand {
    static func run(arguments: [String]) {
        guard let path = arguments.first else {
            print("사용법: Cheoma --parse-screen <화면 파일 또는 폴더> [claude|codex|opencode|pi]")
            return
        }
        let forcedKind = arguments.dropFirst().first.flatMap(AgentKind.init)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            print("파일이 없어요: \(path)")
            return
        }
        let files: [String]
        if isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            files = names.filter { $0.hasSuffix(".txt") }.sorted().map { "\(path)/\($0)" }
        } else {
            files = [path]
        }
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let name = URL(fileURLWithPath: file).lastPathComponent
            let kind = forcedKind ?? AgentKind.allCases.first { name.hasPrefix("\($0.rawValue)-") } ?? .claude
            let screen = TerminalScreen(text: text, capturedAt: Date())
            var analysis = AgentScreenParser.analyze(screen, kind: kind)
            // 시간은 20번 돌린 평균 (처음 한 번은 준비 비용이 섞인다)
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<20 { analysis = AgentScreenParser.analyze(screen, kind: kind) }
            let micros = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 20_000
            print("\(name)  [\(kind.rawValue)]  \(analysis.state.rawValue)  (\(String(format: "%.0f", micros))µs)")
            if let question = analysis.question { print("  질문  \(question)") }
            for choice in analysis.choices {
                let key = choice.key.isEmpty ? "↕" : choice.key
                print("  \(choice.isHighlighted ? "▶" : " ") \(key)\(choice.needsEnter ? "+⏎" : "")  \(choice.label)")
            }
            if let summary = analysis.summary { print("  요약  \(summary)") }
        }
    }
}

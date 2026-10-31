import Foundation

/// 터미널 화면을 보고 에이전트가 무엇을 기다리는지 읽는다 (순수 함수).
/// 화면 맨 아래(입력창 · 선택지 · 작업 중 표시가 있는 곳)만 본다. 위쪽 대화 기록의 번호 목록이나 지난 질문은 무시한다.
/// 실제 화면 모음은 `scripts/agent-screens/`에 있고, `Cheoma --parse-screen <파일>`로 결과를 볼 수 있다
enum AgentScreenParser {
    /// 화면 한 장을 분석한다. 몇 초마다 부르므로 1ms 안에 끝나야 한다
    static func analyze(_ screen: TerminalScreen, kind: AgentKind) -> ScreenAnalysis {
        var lines = ANSIText.plain(screen.text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var end = line.endIndex
                while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
                return String(line[..<end])
            }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return ScreenAnalysis(state: .unknown, question: nil, choices: [], summary: nil) }

        if let menu = numberedMenu(lines, kind: kind) ?? cursorMenu(lines) ?? yesNoQuestion(lines) {
            return ScreenAnalysis(state: .needsChoice, question: menu.question, choices: menu.choices,
                                  summary: menu.question ?? menu.choices.first?.label)
        }
        if let working = workingLine(lines) {
            return ScreenAnalysis(state: .working, question: nil, choices: [], summary: working)
        }
        let state: AgentState = hasInputBox(lines, kind: kind) ? .needsInput : .unknown
        return ScreenAnalysis(state: state, question: nil, choices: [], summary: lastMessage(lines, kind: kind))
    }

    // MARK: - 선택지

    private struct Menu {
        var question: String?
        var choices: [AgentChoice]
    }

    /// 선택지가 있을 수 있는 맨 아래 줄 수 (Claude 권한 창이 20줄 남짓)
    private static let bottomRows = 26
    /// 고르는 줄을 가리키는 커서
    private static let cursors: Set<Character> = ["❯", "›", "→", ">", "▶", "●"]

    /// "1. Yes", "› 2. No (esc)" 같은 번호 목록. 커서가 하나 있거나 바로 아래에 "Enter to …" 안내가 있어야 진짜 메뉴로 본다
    private static func numberedMenu(_ lines: [String], kind: AgentKind) -> Menu? {
        let top = max(0, lines.count - bottomRows)
        var options: [(row: Int, number: Int, label: String, cursor: Bool)] = []
        var gap = 0
        var row = lines.count - 1
        while row >= top {
            if let option = numberedOption(lines[row]) {
                // 아래에서 위로 올라가므로 번호가 하나씩 줄어야 한다
                if let next = options.last, option.number != next.number - 1 { break }
                options.append((row, option.number, option.label, option.cursor))
                gap = 0
                if option.number == 1 { break }
            } else if !options.isEmpty {
                // 설명 줄, 줄바꿈된 이름, 구분선은 3줄까지 건너뛴다 (Claude 질문의 "Chat about this" 앞 구분선 등)
                gap += 1
                if gap > 3 { break }
            }
            row -= 1
        }
        guard options.count >= 2, options.last?.number == 1 else { return nil }
        options.reverse()
        let lastRow = options.last!.row
        let hasCursor = options.contains { $0.cursor }
        let hasHint = lines[(lastRow + 1)..<min(lines.count, lastRow + 5)].contains(where: isMenuHint)
        guard hasCursor || hasHint else { return nil }
        // 메뉴 아래에 입력창이 있으면 대화 기록 속 목록이다
        if lines[(lastRow + 1)...].contains(where: isPromptLine) && !hasHint { return nil }

        let choices = options.map { option -> AgentChoice in
            AgentChoice(key: String(option.number), label: option.label, isHighlighted: option.cursor)
        }
        return Menu(question: question(above: options[0].row, in: lines), choices: choices)
    }

    private static func numberedOption(_ line: String) -> (number: Int, label: String, cursor: Bool)? {
        var rest = Substring(line).drop { $0 == " " }
        var cursor = false
        if let first = rest.first, cursors.contains(first) {
            cursor = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = cleanLabel(String(rest.drop { $0 == " " }))
        guard !label.isEmpty else { return nil }
        return (number, label, cursor)
    }

    /// 번호 없이 커서로 고르는 목록 (Claude 폴더 신뢰, pi 모델 고르기). 키 대신 화살표로 옮겨 고른다 (key가 빈 문자열)
    private static func cursorMenu(_ lines: [String]) -> Menu? {
        let top = max(0, lines.count - 6)
        guard let hintRow = (top..<lines.count).last(where: { isMenuHint(lines[$0]) }) else { return nil }
        let searchTop = max(0, hintRow - 16)
        guard let cursorRow = (searchTop..<hintRow).last(where: { row in
            guard let (column, label, cursor) = cursorItem(lines[row]) else { return false }
            return cursor && column > 0 && !label.isEmpty
        }), let (column, _, _) = cursorItem(lines[cursorRow]) else { return nil }

        func sibling(_ row: Int) -> (label: String, cursor: Bool)? {
            guard let (itemColumn, label, cursor) = cursorItem(lines[row]), itemColumn == column, !label.isEmpty,
                  !isSeparator(lines[row]), !isMenuHint(lines[row]) else { return nil }
            return (label, cursor)
        }
        var first = cursorRow
        while first - 1 >= searchTop, sibling(first - 1) != nil { first -= 1 }
        var last = cursorRow
        while last + 1 < hintRow, sibling(last + 1) != nil { last += 1 }
        let items = (first...last).compactMap(sibling)
        guard items.count >= 2, items.count <= 20 else { return nil }
        let choices = items.map { AgentChoice(key: "", label: cleanLabel($0.label), isHighlighted: $0.cursor) }
        return Menu(question: question(above: first, in: lines), choices: choices)
    }

    /// 줄의 글자가 시작하는 칸, 글자, 커서가 있는지. "→ ✓ gpt-5" 처럼 커서 뒤 표시(✓)도 커서 쪽으로 친다
    private static func cursorItem(_ line: String) -> (column: Int, label: String, cursor: Bool)? {
        var column = 0
        var cursor = false
        var rest = Substring(line)
        while let first = rest.first {
            if first == " " {
                column += 1
            } else if cursors.contains(first) && !cursor {
                cursor = true
                column += 1
            } else if first == "✓" || first == "✔" {
                column += 1
            } else {
                break
            }
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return cursor ? (column, "", true) : nil }
        return (column, String(rest), cursor)
    }

    /// "Continue? [y/N]" 같은 질문 (Aider, 셸 스크립트). 마지막 줄에 있을 때만
    private static func yesNoQuestion(_ lines: [String]) -> Menu? {
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let lower = last.lowercased()
        for pattern in ["[y/n]", "(y/n)", "[yes/no]", "(yes/no)"] {
            guard let range = lower.range(of: pattern) else { continue }
            let tail = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail == ":" || tail == "?" else { continue }
            let question = String(last[..<last.index(last.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))])
                .trimmingCharacters(in: .whitespaces)
            let defaultYes = last.contains("[Y/n]") || last.contains("(Y/n)")
            let defaultNo = last.contains("[y/N]") || last.contains("(y/N)")
            return Menu(question: question.isEmpty ? last : question, choices: [
                AgentChoice(key: "y", label: "Yes", isHighlighted: defaultYes, needsEnter: true),
                AgentChoice(key: "n", label: "No", isHighlighted: defaultNo, needsEnter: true),
            ])
        }
        return nil
    }

    /// 선택지 위의 질문: 물음표가 있는 줄을 먼저 찾고, 없으면 바로 위의 의미 있는 줄
    private static func question(above row: Int, in lines: [String]) -> String? {
        let top = max(0, row - 10)
        var nearest: String?
        var index = row - 1
        while index >= top {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index -= 1
            if line.isEmpty || isSeparator(line) || line.contains("://") { continue }
            if let first = line.first, cursors.contains(first), line.count <= 2 { continue }
            if let mark = line.firstIndex(of: "?") {
                return trimDecoration(String(line[...mark]))
            }
            if nearest == nil { nearest = line }
        }
        return nearest.map(trimDecoration)
    }

    private static func isMenuHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("enter to") || lower.contains("press enter") || lower.contains("esc to cancel")
            || lower.contains("to navigate") || lower.contains("esc to go back")
    }

    /// 이름 끝의 단축키 표시 "(y)", "(esc)", "(shift+tab)"를 뗀다
    private static func cleanLabel(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if !inside.isEmpty, inside.count <= 10, inside.allSatisfy({ $0.isLetter || $0 == "+" }) {
                text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    // MARK: - 작업 중

    /// 작업 중 표시가 있는 줄 (아래 8줄에서): "esc to interrupt"(Claude · Codex · Gemini), pi의 "⠇ Working", OpenCode의 "esc interrupt"
    private static func workingLine(_ lines: [String]) -> String? {
        let top = max(0, lines.count - 8)
        var found = false
        for line in lines[top...] {
            let lower = line.lowercased()
            if lower.contains("esc to interrupt") || lower.contains("esc interrupt") || lower.contains("ctrl+c to interrupt")
                || lower.contains("esc to cancel)") || hasSpinner(line) {
                found = true
                break
            }
        }
        guard found else { return nil }
        // 요약은 스피너 줄 ("Wandering… (1s · thinking)", "Working (42s • esc to interrupt)")
        for line in lines[top...].reversed() {
            let text = trimDecoration(line)
            let lead = line.drop { $0 == " " }.first
            let claudeSpinner = lead.map { "·✢✳✶✻✽*".contains($0) } ?? false
            if hasSpinner(line) || text.hasPrefix("Working") || (text.contains("…") && (text.contains("(") || claudeSpinner)) {
                return text
            }
        }
        return "작업 중"
    }

    /// 점자 스피너(⠋⠙⠹ …) 다음에 글자가 오는 줄
    private static func hasSpinner(_ line: String) -> Bool {
        var previousSpinner = false
        for scalar in line.unicodeScalars {
            if (0x2801...0x28FF).contains(scalar.value) {
                previousSpinner = true
            } else if previousSpinner {
                if scalar == " " { continue }
                return CharacterSet.letters.contains(scalar)
            }
        }
        return false
    }

    // MARK: - 입력 기다림

    /// 맨 아래에 입력창이 보이는지
    private static func hasInputBox(_ lines: [String], kind: AgentKind) -> Bool {
        let bottom = lines[max(0, lines.count - 8)...]
        if bottom.contains(where: { $0.contains("Press Ctrl-C again to exit") }) { return true }
        switch kind {
        case .claude:
            // 구분선 사이의 "❯ " 줄
            return bottom.indices.contains { row in
                isPromptLine(lines[row]) && row > 0 && isSeparator(lines[row - 1])
            }
        case .codex:
            return bottom.contains(where: isPromptLine)
        case .pi:
            // 입력창 위아래 구분선과 맨 아래 상태 줄 ("$0.005 (sub) 0.5%/272k")
            return bottom.contains(where: isSeparator) && bottom.contains { $0.contains("%/") || $0.contains("$0.") }
        case .opencode:
            // 화면 전체를 쓰는 앱이라 입력창이 가운데에 있다
            return lines.contains { $0.contains("┃") } && lines.contains { $0.contains("ctrl+p") }
        case .gemini, .aider:
            return bottom.contains(where: isPromptLine) || bottom.contains(where: isSeparator)
        }
    }

    /// "❯ …", "› …", "> …" 입력 줄
    private static func isPromptLine(_ line: String) -> Bool {
        let text = line.drop { $0 == " " }
        guard let first = text.first, first == "❯" || first == "›" || first == ">" else { return false }
        let rest = text.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    // MARK: - 요약

    /// 에이전트가 마지막으로 한 말 (Claude "⏺", Codex "•"). 다른 에이전트는 화면 아래 장식을 건너뛴 마지막 줄
    private static func lastMessage(_ lines: [String], kind: AgentKind) -> String? {
        let bullets: [String] = switch kind {
        case .claude: ["⏺ "]
        case .codex: ["• ", "■ ", "⚠ "]
        default: []
        }
        if !bullets.isEmpty {
            for line in lines.reversed() {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard let bullet = bullets.first(where: { text.hasPrefix($0) }) else { continue }
                let message = String(text.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                if message.hasPrefix("Working") || message.isEmpty { continue }
                return shorten(message)
            }
            // 아직 한 말이 없다 (나머지는 로고 · 상태 줄뿐)
            return nil
        }
        for line in lines.reversed() {
            let text = trimDecoration(line)
            guard text.count >= 2, !isChrome(text) else { continue }
            return shorten(text)
        }
        return nil
    }

    /// 화면 아래쪽 장식: 상태 줄, 경로, 단축키 안내, 경고
    private static func isChrome(_ text: String) -> Bool {
        if isSeparator(text) || isPromptLine(text) { return true }
        if text.hasPrefix("/") || text.hasPrefix("~") { return true }
        if text.allSatisfy({ !$0.isLetter }) { return true }
        // 목록 · 괄호로 시작하는 줄은 대개 변경 기록이나 줄바꿈된 꼬리다 (pi 시작 화면)
        if text.hasPrefix("- ") || text.hasPrefix("(") { return true }
        let lower = text.lowercased()
        let markers = ["%/", "$0.", "shortcuts", "ctrl+", "esc to", "mode on", "/effort", "tmux", "warning:", "tip:",
                       "(no output)", "took ", "/bug", "/plugins", "/update", "/model", "? for", "http"]
        return markers.contains { lower.contains($0) }
    }

    /// 앞뒤의 테두리·불릿 글자를 뗀다
    private static func trimDecoration(_ line: String) -> String {
        line.trimmingCharacters(in: decoration)
    }

    /// 테두리 · 불릿 · 스피너 · 빈칸 (U+200A 같은 좁은 빈칸 포함)
    private static let decoration = CharacterSet(charactersIn: "│┃╹─━╌⏺•·✻✶✳✢*✨\u{FE0F}⠀⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏⠐⠑⠒⠓⠔⠕⠖⠗⠘⠙⠚⠛⠜⠝⠞⠟⠠⠡⠢⠣⠤⠥⠦⠧⠨⠩⠪⠫⠬⠭⠮⠯⠰⠱⠲⠳⠴⠵⠶⠷⠸⠹⠺⠻⠼⠽⠾⠿").union(.whitespaces)

    private static func shorten(_ text: String) -> String {
        text.count > 160 ? String(text.prefix(159)) + "…" : text
    }

    /// ─── 같은 구분선 (글자 대부분이 선)
    private static func isSeparator(_ line: String) -> Bool {
        var lineCount = 0
        var other = 0
        for scalar in line.unicodeScalars where scalar != " " {
            if (0x2500...0x257F).contains(scalar.value) || (0x2580...0x259F).contains(scalar.value) {
                lineCount += 1
            } else {
                other += 1
            }
        }
        return lineCount >= 8 && other <= lineCount / 4
    }
}

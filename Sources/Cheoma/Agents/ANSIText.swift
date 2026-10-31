import SwiftUI

/// 터미널 글자의 ANSI 코드 다루기: 전경·배경색(16색 · 256색 · 24비트), 굵게, 흐리게, 기울임, 밑줄, 반전.
/// tmux `capture-pane -e`가 주는 SGR(`ESC [ … m`)만 해석하고, 나머지 CSI와 OSC(링크 `ESC ] 8 ; …`)는 지운다
enum ANSIText {
    /// 미리보기에 그릴 색 입힌 글자. 기본 색은 그리는 쪽(`foregroundStyle`)에 맡긴다
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            style.apply(to: &piece)
            result.append(piece)
            run = ""
        }
        scan(text, onText: { run.unicodeScalars.append($0) }, onSGR: { codes in
            flush()
            style.update(codes)
        })
        flush()
        return result
    }

    /// 코드를 모두 지운 글자. 줄 사이 nbsp(Claude Code 입력창)는 보통 빈칸으로 바꾼다
    static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scan(text, onText: { scalars.append($0 == "\u{A0}" ? " " : $0) }, onSGR: { _ in })
        return String(scalars)
    }

    // MARK: - 읽기

    /// 글자와 SGR 코드를 차례로 넘긴다. 몇 초마다 화면 전체를 읽으므로 정규식 없이 한 번에 훑는다
    private static func scan(_ text: String, onText: (Unicode.Scalar) -> Void, onSGR: ([Int]) -> Void) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}", index + 1 < scalars.count else {
                if scalar != "\u{1B}" && scalar != "\r" { onText(scalar) }
                index += 1
                continue
            }
            let kind = scalars[index + 1]
            index += 2
            switch kind {
            case "[":
                // CSI: 숫자·구분자 다음 끝 글자 하나 (@ … ~)
                let start = index
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                guard index < scalars.count else { return }
                if scalars[index] == "m" {
                    let body = String(String.UnicodeScalarView(scalars[start..<index]))
                    onSGR(body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 })
                }
                index += 1
            case "]", "P", "_", "^":
                // OSC · DCS 등: BEL이나 ESC \ 까지
                while index < scalars.count {
                    if scalars[index] == "\u{07}" { index += 1; break }
                    if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" { index += 2; break }
                    index += 1
                }
            default:
                // ESC 하나짜리 명령 (ESC = , ESC ( B …): 다음 글자까지 버린다
                if kind == "(" || kind == ")" { index += 1 }
            }
        }
    }

    // MARK: - 스타일

    private enum TermColor: Equatable {
        case palette(Int)
        case rgb(Double, Double, Double)

        var color: Color {
            switch self {
            case .rgb(let r, let g, let b):
                return Color(red: r, green: g, blue: b)
            case .palette(let index):
                if index < 16 {
                    let (r, g, b) = ANSIText.basic[index]
                    return Color(red: r, green: g, blue: b)
                }
                if index < 232 {
                    let value = index - 16
                    func level(_ step: Int) -> Double { step == 0 ? 0 : Double(55 + step * 40) / 255 }
                    return Color(red: level(value / 36), green: level(value / 6 % 6), blue: level(value % 6))
                }
                let gray = Double(8 + (index - 232) * 10) / 255
                return Color(red: gray, green: gray, blue: gray)
            }
        }
    }

    /// 어두운 배경에서 읽기 좋은 16색 (macOS Terminal 기본에 가깝게)
    private static let basic: [(Double, Double, Double)] = [
        (0.0, 0.0, 0.0), (0.87, 0.30, 0.27), (0.38, 0.78, 0.35), (0.85, 0.75, 0.30),
        (0.35, 0.55, 0.95), (0.78, 0.45, 0.85), (0.35, 0.75, 0.80), (0.80, 0.80, 0.80),
        (0.45, 0.45, 0.45), (1.0, 0.45, 0.42), (0.50, 0.92, 0.45), (1.0, 0.90, 0.45),
        (0.50, 0.68, 1.0), (0.92, 0.58, 1.0), (0.50, 0.90, 0.95), (1.0, 1.0, 1.0),
    ]

    private struct Style {
        var foreground: TermColor?
        var background: TermColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false

        mutating func update(_ codes: [Int]) {
            var index = 0
            while index < codes.count {
                let code = codes[index]
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 7: inverse = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 27: inverse = false
                case 30...37: foreground = .palette(code - 30)
                case 39: foreground = nil
                case 40...47: background = .palette(code - 40)
                case 49: background = nil
                case 90...97: foreground = .palette(code - 90 + 8)
                case 100...107: background = .palette(code - 100 + 8)
                case 38, 48:
                    var color: TermColor?
                    if index + 2 < codes.count, codes[index + 1] == 5 {
                        color = .palette(min(max(codes[index + 2], 0), 255))
                        index += 2
                    } else if index + 4 < codes.count, codes[index + 1] == 2 {
                        color = .rgb(Double(codes[index + 2]) / 255, Double(codes[index + 3]) / 255, Double(codes[index + 4]) / 255)
                        index += 4
                    }
                    if code == 38 { foreground = color } else { background = color }
                default: break
                }
                index += 1
            }
        }

        func apply(to piece: inout AttributedString) {
            var fg = foreground?.color
            var bg = background?.color
            if inverse {
                // 기본색을 모르니 반전은 검정 바탕 흰 글자 기준으로 바꾼다
                (fg, bg) = (bg ?? .black, fg ?? Color(white: 0.85))
            }
            if dim { fg = (fg ?? .white).opacity(0.5) }
            if let fg { piece.foregroundColor = fg }
            if let bg { piece.backgroundColor = bg }
            var intent: InlinePresentationIntent = []
            if bold { intent.insert(.stronglyEmphasized) }
            if italic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if underline { piece.underlineStyle = .single }
        }
    }
}

import SwiftUI

/// 에이전트 탭이 같이 쓰는 모양: 에이전트 표시, 상태 색, 시간 · 금액 글자
enum AgentsStyle {
    static func symbol(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .pi: "pi"
        case .gemini: "sparkles"
        case .aider: "wrench.and.screwdriver"
        }
    }

    static func color(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: Color(red: 0.88, green: 0.52, blue: 0.38)
        case .codex: Color(red: 0.55, green: 0.82, blue: 0.78)
        case .opencode: Color(red: 0.70, green: 0.62, blue: 0.95)
        case .pi: Color(red: 0.95, green: 0.82, blue: 0.45)
        case .gemini: Color(red: 0.50, green: 0.68, blue: 1.0)
        case .aider: Color(red: 0.55, green: 0.85, blue: 0.50)
        }
    }

    static func color(_ state: AgentState) -> Color {
        switch state {
        case .working: .blue
        case .needsChoice: .orange
        case .needsInput: .green
        case .exited, .unknown: .gray
        }
    }

    /// "방금", "3분", "2시간", "1일"
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "방금"
        case ..<3_600: return "\(Int(seconds / 60))분"
        case ..<86_400: return "\(Int(seconds / 3_600))시간"
        default: return "\(Int(seconds / 86_400))일"
        }
    }

    /// "방금", "5분 전"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let text = elapsed(since: date, now: now)
        return text == "방금" ? text : text + " 전"
    }

    /// "40분 뒤", "3시간 뒤", "5일 뒤"
    static func until(_ date: Date, now: Date = Date()) -> String {
        // 가까운 단위로 반올림한다 (2시간 59분 → "3시간 뒤")
        let seconds = max(date.timeIntervalSince(now), 0)
        switch seconds {
        case ..<3_570: return "\(max(Int((seconds / 60).rounded()), 1))분 뒤"
        case ..<84_600: return "\(Int((seconds / 3_600).rounded()))시간 뒤"
        default: return "\(Int((seconds / 86_400).rounded()))일 뒤"
        }
    }

    static func cost(_ usd: Double) -> String {
        usd >= 100 ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    /// 사용 한도 구간 이름: 300분 → "5시간", 1주 → "주간"
    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 10_080: "주간"
        case 1_440: "하루"
        case let m where m % 1_440 == 0: "\(m / 1_440)일"
        case let m where m % 60 == 0: "\(m / 60)시간"
        default: "\(minutes)분"
        }
    }

    static func usageColor(_ percent: Double) -> Color {
        switch percent {
        case 90...: .red
        case 70...: .orange
        case 50...: .yellow
        default: .green
        }
    }

    /// 설정 폴더 이름을 짧게: ".claude" → "기본", ".claude-account2" → "account2"
    static func accountName(_ folder: String) -> String {
        if folder == ".claude" { return "기본" }
        if folder.hasPrefix(".claude-") { return String(folder.dropFirst(".claude-".count)) }
        return folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
    }

    /// 홈 폴더를 ~로 줄인다
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 다른 탭과 같은 카드 바탕
    static let cardFill = Color.white.opacity(0.07)
}

/// 에이전트 종류 표시 (작은 둥근 네모 안의 기호)
struct AgentMark: View {
    let kind: AgentKind
    var size: CGFloat = 22
    @Environment(\.agentsScale) private var scale

    var body: some View {
        let size = size * scale
        Image(systemName: AgentsStyle.symbol(kind))
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(AgentsStyle.color(kind))
            .frame(width: size, height: size)
            .background(AgentsStyle.color(kind).opacity(0.17),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(kind.displayName)
    }
}

/// 상태 이름표. 작업 중이면 작은 점이 숨 쉬듯 깜빡인다 (기호 효과라 가볍다)
struct AgentStateChip: View {
    let state: AgentState

    var body: some View {
        let color = AgentsStyle.color(state)
        HStack(spacing: 3) {
            if state == .working {
                Image(systemName: "circle.fill")
                    .agentsFont(size: 5)
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(state.title)
                .lineLimit(1)
                .fixedSize()
        }
        .agentsFont(size: 9.5, weight: .semibold)
        .foregroundStyle(state == .exited || state == .unknown ? Color.white.opacity(0.6) : color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(state == .exited || state == .unknown ? 0.18 : 0.22), in: Capsule())
    }
}

/// 작은 캡슐 버튼 (헤더 · 설정 줄)
struct AgentsCapsuleButton: View {
    let title: String
    var symbol: String?
    var tint: Color = .white
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .agentsFont(size: 9, weight: .bold)
                }
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .agentsFont(size: 10.5, weight: .semibold)
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(prominent ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(tint.opacity(0.13)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 글자 크기

/// 에이전트 탭 글자 크기 배율 (설정 창에서 고른다). 글자와 함께 아이콘 · 줄 높이 · 목록 폭도 같이 커진다
enum AgentsTextScale: Double, CaseIterable {
    case normal = 1
    case large = 1.15
    case larger = 1.3
    case largest = 1.5

    static let defaultsKey = "agents.textScale"

    var title: String {
        switch self {
        case .normal: "보통"
        case .large: "크게"
        case .larger: "더 크게"
        case .largest: "가장 크게"
        }
    }

    var percent: String { "\(Int((rawValue * 100).rounded()))%" }
}

private struct AgentsScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 에이전트 탭 안의 글자 · 고정 크기에 곱하는 배율
    var agentsScale: CGFloat {
        get { self[AgentsScaleKey.self] }
        set { self[AgentsScaleKey.self] = newValue }
    }
}

/// 배율을 곱한 시스템 글꼴
private struct AgentsFont: ViewModifier {
    @Environment(\.agentsScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

/// 배율을 곱한 고정 크기
private struct AgentsFrame: ViewModifier {
    @Environment(\.agentsScale) private var scale
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
    }
}

extension View {
    /// 에이전트 탭 글꼴: 크기에 글자 크기 배율을 곱한다
    func agentsFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AgentsFont(size: size, weight: weight, design: design))
    }

    /// 에이전트 탭 고정 크기: 글자 크기 배율을 곱한다
    func agentsFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(AgentsFrame(width: width, height: height, alignment: alignment))
    }
}

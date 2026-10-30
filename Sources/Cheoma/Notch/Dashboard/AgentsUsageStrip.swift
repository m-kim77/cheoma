import SwiftUI

/// 에이전트 탭 맨 위: Codex 사용 한도 · Claude 계정별 비용, 새 에이전트 · 연결 설정 버튼
struct AgentsUsageStrip: View {
    let usage: AgentUsage
    @Binding var pane: AgentsPane
    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            if let codex = usage.codex, codex.primary != nil || codex.secondary != nil {
                CodexUsageCard(usage: codex)
            }
            if !usage.claude.isEmpty {
                // 계정이 많아 자리가 모자라면 토큰 수를 빼고, 그래도 모자라면 앞의 계정만 보여준다
                ViewThatFits(in: .horizontal) {
                    ClaudeUsageCard(accounts: usage.claude, compact: false)
                    ClaudeUsageCard(accounts: usage.claude, compact: true)
                    ClaudeUsageCard(accounts: Array(usage.claude.prefix(2)), compact: true)
                    ClaudeUsageCard(accounts: Array(usage.claude.prefix(1)), compact: true)
                }
            }
            Spacer(minLength: 0)
            buttons
        }
        .frame(height: Self.height)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button { pane = pane == .launcher ? .session : .launcher } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("새 에이전트")
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(pane == .launcher ? 0.2 : 0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { pane = pane == .setup ? .session : .setup } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(pane == .setup ? 0.2 : 0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("연결 설정 (Terminal 권한 · 훅)")
            .accessibilityLabel("연결 설정")
        }
    }
}

/// Codex 5시간 · 주간 한도: 쓴 비율 막대와 초기화까지 남은 시간
private struct CodexUsageCard: View {
    let usage: CodexUsage

    var body: some View {
        HStack(spacing: 10) {
            UsageCardTitle(kind: .codex, title: "Codex", detail: usage.plan)
            if let primary = usage.primary { WindowGauge(window: primary) }
            if let secondary = usage.secondary { WindowGauge(window: secondary) }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("Codex 사용 한도 · \(AgentsStyle.ago(usage.updatedAt)) 기록")
    }
}

private struct WindowGauge: View {
    let window: UsageWindow

    var body: some View {
        let now = Date()
        // 초기화 시각이 지났으면 기록된 비율은 지난 구간 것이다
        let isReset = window.resetsAt.map { $0 <= now } ?? false
        let percent = isReset ? 0 : window.usedPercent
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(AgentsStyle.windowName(minutes: window.windowMinutes))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Spacer(minLength: 6)
                if let resetsAt = window.resetsAt {
                    Text(isReset ? "초기화됨" : "\(AgentsStyle.until(resetsAt, now: now)) 초기화")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(AgentsStyle.usageColor(percent))
                        .frame(width: max(geo.size.width * min(percent / 100, 1), 3))
                }
            }
            .frame(height: 4)
        }
        .frame(width: 124)
    }
}

/// Claude 계정마다 오늘 비용 · 토큰과 지금 5시간 구간 비용
private struct ClaudeUsageCard: View {
    let accounts: [ClaudeUsage]
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            UsageCardTitle(kind: .claude, title: "Claude", detail: "오늘")
            ForEach(accounts, id: \.account) { account in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if accounts.count > 1 || account.account != ".claude" {
                            Text(AgentsStyle.accountName(account.account))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(AgentsStyle.cost(account.todayCostUSD))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                        if !compact {
                            Text(AgentsStyle.tokens(account.todayTokens))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .fixedSize()
                    Text(blockText(account))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .help(help(account))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func blockText(_ account: ClaudeUsage) -> String {
        guard account.blockCostUSD > 0 || account.blockEndsAt != nil else { return "5시간 구간 없음" }
        var text = "5시간 \(AgentsStyle.cost(account.blockCostUSD))"
        if !compact, let end = account.blockEndsAt, end > Date() { text += " · \(AgentsStyle.until(end))" }
        return text
    }

    private func help(_ account: ClaudeUsage) -> String {
        var lines = ["\(account.account): 오늘 \(AgentsStyle.cost(account.todayCostUSD)) · 토큰 \(AgentsStyle.tokens(account.todayTokens))"]
        lines.append("지금 5시간 구간 \(AgentsStyle.cost(account.blockCostUSD))")
        if let end = account.blockEndsAt, end > Date() { lines.append("구간은 \(AgentsStyle.until(end)) 끝나요") }
        return lines.joined(separator: "\n")
    }
}

private struct UsageCardTitle: View {
    let kind: AgentKind
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentsStyle.color(kind))
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

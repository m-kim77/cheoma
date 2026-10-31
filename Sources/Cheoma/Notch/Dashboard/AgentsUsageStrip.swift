import SwiftUI

/// 에이전트 탭 맨 위: Codex 사용 한도 · Claude 계정별 구독 한도(또는 API 환산 비용), 새 에이전트 · 연결 설정 버튼
struct AgentsUsageStrip: View {
    let usage: AgentUsage
    @Binding var pane: AgentsPane
    @AppStorage(ClaudeUsageDisplay.defaultsKey) private var display = ClaudeUsageDisplay.limits
    static let height: CGFloat = 38

    var body: some View {
        // 자리가 모자라면 Codex를 작은 막대로, 단추를 아이콘만, Claude 비용은 토큰 수를 빼고, 그래도 모자라면 앞의 계정만 보여준다.
        // 계정은 되도록 다 보이게 단추부터 줄인다
        ViewThatFits(in: .horizontal) {
            row(codexCompact: false, claude: usage.claude, compact: false, compactButtons: false)
            row(codexCompact: true, claude: usage.claude, compact: false, compactButtons: false)
            row(codexCompact: true, claude: usage.claude, compact: false, compactButtons: true)
            row(codexCompact: true, claude: usage.claude, compact: true, compactButtons: true)
            row(codexCompact: true, claude: Array(usage.claude.prefix(2)), compact: true, compactButtons: true)
            row(codexCompact: true, claude: Array(usage.claude.prefix(1)), compact: true, compactButtons: true)
        }
        .frame(height: Self.height)
    }

    private func row(codexCompact: Bool, claude: [ClaudeUsage], compact: Bool, compactButtons: Bool) -> some View {
        HStack(spacing: 8) {
            cards(codexCompact: codexCompact, claude: claude, compact: compact)
                // 사용량 카드를 누르면 계정 한눈에 보기
                .contentShape(Rectangle())
                .onTapGesture { pane = pane == .accounts ? .session : .accounts }
            Spacer(minLength: 0)
            buttons(compact: compactButtons)
        }
    }

    private func cards(codexCompact: Bool, claude: [ClaudeUsage], compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let codex = usage.codex, codex.primary != nil || codex.secondary != nil {
                CodexUsageCard(usage: codex, compact: codexCompact)
            }
            if !claude.isEmpty {
                switch display {
                case .limits: ClaudeLimitsCard(accounts: claude)
                case .cost: ClaudeUsageCard(accounts: claude, compact: compact)
                }
            }
        }
        .fixedSize()
    }

    private func buttons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button { pane = pane == .accounts ? .session : .accounts } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(pane == .accounts ? 0.2 : 0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("계정 (이메일 · 요금제 · 한도)")
            .accessibilityLabel("계정")
            Button { pane = pane == .launcher ? .session : .launcher } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                    if !compact {
                        Text("새 에이전트")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: compact ? 26 : nil)
                .padding(.horizontal, compact ? 0 : 10)
                .frame(height: 26)
                .background(.white.opacity(pane == .launcher ? 0.2 : 0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("새 에이전트")
            .accessibilityLabel("새 에이전트")
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
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            UsageCardTitle(kind: .codex, title: "Codex", detail: usage.plan)
            if compact {
                HStack(spacing: 8) {
                    ForEach([usage.primary, usage.secondary].compactMap { $0 }, id: \.windowMinutes) { LimitGauge(window: $0) }
                }
            } else {
                if let primary = usage.primary { WindowGauge(window: primary) }
                if let secondary = usage.secondary { WindowGauge(window: secondary) }
            }
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

/// 작은 한도 막대 한 줄: "5시간 ▬▬ 12%". 초기화 시각은 마우스를 올리면 보인다
private struct LimitGauge: View {
    let window: UsageWindow

    var body: some View {
        let now = Date()
        let isReset = window.resetsAt.map { $0 <= now } ?? false
        let percent = isReset ? 0 : window.usedPercent
        HStack(spacing: 4) {
            Text(AgentsStyle.windowName(minutes: window.windowMinutes))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(AgentsStyle.usageColor(percent))
                    .frame(width: max(30 * min(percent / 100, 1), 2))
            }
            .frame(width: 30, height: 3)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .help(help(now: now, isReset: isReset))
    }

    private func help(now: Date, isReset: Bool) -> String {
        let name = AgentsStyle.windowName(minutes: window.windowMinutes)
        guard let resetsAt = window.resetsAt else { return "\(name) 한도" }
        return isReset ? "\(name) 한도 · 초기화됨" : "\(name) 한도 · \(AgentsStyle.until(resetsAt, now: now)) 초기화"
    }
}

/// Claude 계정마다 구독의 5시간 · 주간 한도 (계정 하나에 한 줄)
private struct ClaudeLimitsCard: View {
    let accounts: [ClaudeUsage]

    var body: some View {
        HStack(spacing: 10) {
            UsageCardTitle(kind: .claude, title: "Claude", detail: "구독")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(accounts, id: \.account) { account in
                    GridRow {
                        if accounts.count > 1 || account.account != ".claude" {
                            Text(AgentsStyle.accountName(account.account))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if account.limits.isEmpty {
                            Text("한도 정보 없음")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                                .gridCellColumns(2)
                                .help("설정(톱니)에서 Claude Code를 연결한 뒤 이 계정으로 Claude를 한 번 쓰면 보여요")
                        } else {
                            ForEach(account.limits, id: \.windowMinutes) { LimitGauge(window: $0) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help)
    }

    private var help: String {
        let lines = accounts.compactMap { account -> String? in
            guard let date = account.limitsUpdatedAt else { return nil }
            return "\(AgentsStyle.accountName(account.account)): \(AgentsStyle.ago(date)) 받은 값"
        }
        return (["Claude 구독 한도 (Claude Code 상태 줄에서 받아요)"] + lines).joined(separator: "\n")
    }
}

/// Claude 계정마다 오늘 쓴 토큰을 API 가격으로 셈한 비용과 지금 5시간 구간 비용. 구독이면 실제로 청구되는 돈이 아니다
private struct ClaudeUsageCard: View {
    let accounts: [ClaudeUsage]
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            UsageCardTitle(kind: .claude, title: "Claude", detail: "API 환산")
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
        var lines = ["\(AgentsStyle.accountName(account.account)): 오늘 \(AgentsStyle.cost(account.todayCostUSD)) · 토큰 \(AgentsStyle.tokens(account.todayTokens))",
                     "쓴 토큰을 API 가격으로 셈한 값이에요. 구독이면 실제로 청구되지 않아요"]
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

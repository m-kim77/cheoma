import SwiftUI

/// 에이전트 탭 맨 위: Codex 사용 한도 · Claude 계정별 구독 한도(또는 API 환산 비용), 새 에이전트 · 연결 설정 버튼
struct AgentsUsageStrip: View {
    let usage: AgentUsage
    @Binding var pane: AgentsPane
    @AppStorage(ClaudeUsageDisplay.defaultsKey) private var display = ClaudeUsageDisplay.limits
    static let height: CGFloat = 38

    var body: some View {
        // 로그인된 구독 계정은 빼지 않는다 (한도 기록이 아직 없어도 "한도 정보 없음"으로 보인다).
        // 자리가 모자라면 단추 → 로컬 카드를 요약으로 → Codex · Claude 막대를 계정마다 하나로 → 로컬 빼기 순서로 줄이고,
        // 그래도 모자라면 카드들을 옆으로 스크롤한다
        let codex = usage.codex.filter { $0.login != nil || $0.usage?.primary != nil || $0.usage?.secondary != nil }
        let named = codex.count > 1
        // 로컬 모델은 구독이 아니라서 올라온 게 있을 때만, 자리가 모자라면 뺀다
        let local = usage.local.filter { !$0.models.isEmpty }
        ViewThatFits(in: .horizontal) {
            row(codex: codex, named: named, codexCompact: false, claude: usage.claude, local: local, compact: false, compactButtons: false)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: false, compactButtons: false)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: false, compactButtons: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: true, compactButtons: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: true, compactButtons: true,
                localCompact: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: true, compactButtons: true,
                localCompact: true, codexFirstOnly: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: local, compact: true, compactButtons: true,
                localCompact: true, codexFirstOnly: true, claudeFirstOnly: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: [], compact: true, compactButtons: true,
                codexFirstOnly: true, claudeFirstOnly: true)
            row(codex: codex, named: named, codexCompact: true, claude: usage.claude, local: [], compact: true, compactButtons: true,
                codexFirstOnly: true, claudeFirstOnly: true, scrolls: true)
        }
        .agentsFrame(height: Self.height)
    }

    private func row(codex: [CodexAccountUsage], named: Bool, codexCompact: Bool, claude: [ClaudeUsage], local: [LocalModelServer],
                     compact: Bool, compactButtons: Bool, localCompact: Bool = false, codexFirstOnly: Bool = false,
                     claudeFirstOnly: Bool = false, scrolls: Bool = false) -> some View {
        let cards = cards(codex: codex, named: named, codexCompact: codexCompact, claude: claude, local: local, compact: compact,
                          localCompact: localCompact, codexFirstOnly: codexFirstOnly, claudeFirstOnly: claudeFirstOnly)
            // 사용량 카드를 누르면 계정 한눈에 보기
            .contentShape(Rectangle())
            .onTapGesture { pane = pane == .accounts ? .session : .accounts }
        return HStack(spacing: 8) {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { cards }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                cards
                Spacer(minLength: 0)
            }
            buttons(compact: compactButtons)
        }
    }

    /// named: Codex 계정이 여럿이라 카드에 계정 이름을 붙인다
    private func cards(codex: [CodexAccountUsage], named: Bool, codexCompact: Bool, claude: [ClaudeUsage], local: [LocalModelServer],
                       compact: Bool, localCompact: Bool, codexFirstOnly: Bool, claudeFirstOnly: Bool) -> some View {
        HStack(spacing: 8) {
            // 계정이 하나면 큰 막대, 여럿이면 Claude처럼 한 카드에 계정마다 한 줄
            if named {
                CodexLimitsCard(accounts: codex, firstOnly: codexFirstOnly)
            } else if let account = codex.first {
                if let limits = account.usage, limits.primary != nil || limits.secondary != nil {
                    CodexUsageCard(usage: limits, compact: codexCompact,
                                   name: account.account != ".codex" ? AgentsStyle.accountName(account.account) : nil)
                } else {
                    // 로그인은 했지만 아직 Codex를 쓰지 않아 한도 기록이 없다
                    CodexLimitsCard(accounts: [account])
                }
            }
            if !claude.isEmpty {
                switch display {
                case .limits: ClaudeLimitsCard(accounts: claude, firstOnly: claudeFirstOnly)
                case .cost: ClaudeUsageCard(accounts: claude, compact: compact)
                }
            }
            if let antigravity = usage.antigravity, !antigravity.groups.isEmpty {
                AntigravityLimitsCard(usage: antigravity)
            }
            if !local.isEmpty { LocalModelsCard(servers: local, compact: localCompact) }
        }
        .fixedSize()
    }

    private func buttons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button { pane = pane == .accounts ? .session : .accounts } label: {
                Image(systemName: "person.2")
                    .agentsFont(size: 10.5, weight: .semibold)
                    .agentsFrame(width: 26, height: 26)
                    .background(.white.opacity(pane == .accounts ? 0.2 : 0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("계정 (이메일 · 요금제 · 한도)")
            .accessibilityLabel("계정")
            Button { pane = pane == .launcher ? .session : .launcher } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .agentsFont(size: 9.5, weight: .bold)
                    if !compact {
                        Text("새 에이전트")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .agentsFont(size: 11, weight: .semibold)
                .frame(minWidth: compact ? 26 : nil)
                .padding(.horizontal, compact ? 0 : 10)
                .agentsFrame(height: 26)
                .background(.white.opacity(pane == .launcher ? 0.2 : 0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("새 에이전트")
            .accessibilityLabel("새 에이전트")
            Button { pane = pane == .setup ? .session : .setup } label: {
                Image(systemName: "gearshape")
                    .agentsFont(size: 11.5, weight: .semibold)
                    .agentsFrame(width: 26, height: 26)
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
    /// 계정이 여럿이면 계정 이름 ("account2")
    var name: String?

    var body: some View {
        HStack(spacing: 10) {
            UsageCardTitle(kind: .codex, title: "Codex", detail: name ?? usage.plan)
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
        .help("Codex\(name.map { " · \($0)" } ?? "") 사용 한도 · \(AgentsStyle.ago(usage.updatedAt)) 기록")
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
                    .agentsFont(size: 9.5)
                    .foregroundStyle(.secondary)
                Text("\(Int(percent.rounded()))%")
                    .agentsFont(size: 11, weight: .semibold)
                    .monospacedDigit()
                Spacer(minLength: 6)
                if let resetsAt = window.resetsAt {
                    Text(isReset ? "초기화됨" : "\(AgentsStyle.until(resetsAt, now: now)) 초기화")
                        .agentsFont(size: 9)
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
        .agentsFrame(width: 124)
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
                .agentsFont(size: 9.5)
                .foregroundStyle(.secondary)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(AgentsStyle.usageColor(percent))
                    .frame(width: max(30 * min(percent / 100, 1), 2))
            }
            .frame(width: 30, height: 3)
            Text("\(Int(percent.rounded()))%")
                .agentsFont(size: 10.5, weight: .semibold)
                .monospacedDigit()
                .agentsFrame(width: 30, alignment: .trailing)
        }
        .help(help(now: now, isReset: isReset))
    }

    private func help(now: Date, isReset: Bool) -> String {
        let name = AgentsStyle.windowName(minutes: window.windowMinutes)
        guard let resetsAt = window.resetsAt else { return "\(name) 한도" }
        return isReset ? "\(name) 한도 · 초기화됨" : "\(name) 한도 · \(AgentsStyle.until(resetsAt, now: now)) 초기화"
    }
}

/// 에이전트 하나의 계정별 한도: 계정 하나에 한 줄. 두 줄이 넘으면 카드 안에서 아래로 스크롤한다
private struct AccountLimitsCard: View {
    struct Row: Identifiable {
        var id: String
        /// 계정 이름 (기본 계정 하나뿐이면 nil)
        var name: String?
        var windows: [UsageWindow]
        var emptyHelp: String
    }

    let kind: AgentKind
    let title: String
    let detail: String?
    let rows: [Row]
    let help: String
    /// 계정마다 막대 하나만 (5시간, 없으면 첫 한도). 자리가 모자랄 때
    var firstOnly = false

    /// 이 줄 수까지는 스크롤 없이 보인다 (사용량 줄 높이에 두 줄이 들어간다)
    private static let visibleRows = 2

    var body: some View {
        HStack(spacing: 10) {
            UsageCardTitle(kind: kind, title: title, detail: detail)
            if rows.count > Self.visibleRows {
                ScrollView(.vertical, showsIndicators: false) { grid.padding(.vertical, 4) }
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                grid
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help)
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(rows) { row in
                GridRow {
                    if let name = row.name {
                        Text(name)
                            .agentsFont(size: 9.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if row.windows.isEmpty {
                        Text("한도 정보 없음")
                            .agentsFont(size: 9.5)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .gridCellColumns(2)
                            .help(row.emptyHelp)
                    } else {
                        ForEach(shown(row.windows), id: \.windowMinutes) { LimitGauge(window: $0) }
                    }
                }
            }
        }
    }
}

extension AccountLimitsCard {
    func shown(_ windows: [UsageWindow]) -> [UsageWindow] {
        guard firstOnly else { return windows }
        return [windows.first { $0.windowMinutes == 300 } ?? windows.first].compactMap { $0 }
    }
}

/// Codex 계정이 여럿일 때: 계정마다 5시간 · 주간 (무료 요금제는 30일) 한도
private struct CodexLimitsCard: View {
    let accounts: [CodexAccountUsage]
    var firstOnly = false

    var body: some View {
        AccountLimitsCard(
            kind: .codex, title: "Codex", detail: accounts.count > 1 ? "계정 \(accounts.count)개" : nil,
            rows: accounts.map { account in
                .init(id: account.home, name: AgentsStyle.accountName(account.account),
                      windows: [account.usage?.primary, account.usage?.secondary].compactMap { $0 },
                      emptyHelp: "이 계정으로 Codex를 한 번 쓰면 보여요")
            },
            help: (["Codex 사용 한도 (기록에서 읽어요)"] + accounts.map { account in
                let plan = (account.login?.plan ?? account.usage?.plan).map { " · \($0)" } ?? ""
                let date = account.usage.map { " · \(AgentsStyle.ago($0.updatedAt)) 기록" } ?? ""
                return "\(AgentsStyle.accountName(account.account))\(plan)\(date)"
            }).joined(separator: "\n"),
            firstOnly: firstOnly)
    }
}

/// Antigravity CLI: 모델 묶음(Gemini, Claude · GPT)마다 한 줄
private struct AntigravityLimitsCard: View {
    let usage: AntigravityUsage

    var body: some View {
        AccountLimitsCard(
            kind: .antigravity, title: "Antigravity", detail: nil,
            rows: usage.groups.map { group in
                .init(id: group.name, name: AntigravityQuota.shortName(group.name), windows: group.windows,
                      emptyHelp: "agy -p /usage로 받은 한도가 없어요")
            },
            help: (["Antigravity 사용 한도 (agy -p /usage)", usage.email, "\(AgentsStyle.ago(usage.updatedAt)) 받음"].compactMap { $0 })
                .joined(separator: "\n"))
    }
}

/// Claude 계정마다 구독의 5시간 · 주간 한도 (계정 하나에 한 줄)
private struct ClaudeLimitsCard: View {
    let accounts: [ClaudeUsage]
    var firstOnly = false

    var body: some View {
        AccountLimitsCard(
            kind: .claude, title: "Claude", detail: "구독",
            rows: accounts.map { account in
                .init(id: account.account,
                      name: accounts.count > 1 || account.account != ".claude" ? AgentsStyle.accountName(account.account) : nil,
                      windows: account.limits,
                      emptyHelp: "설정(톱니)에서 Claude Code를 연결한 뒤 이 계정으로 Claude를 한 번 쓰면 보여요")
            },
            help: help, firstOnly: firstOnly)
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
                                .agentsFont(size: 9.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(AgentsStyle.cost(account.todayCostUSD))
                            .agentsFont(size: 11, weight: .semibold)
                            .monospacedDigit()
                        if !compact {
                            Text(AgentsStyle.tokens(account.todayTokens))
                                .agentsFont(size: 9.5)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .fixedSize()
                    Text(blockText(account))
                        .agentsFont(size: 9)
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

/// 메모리에 올라온 로컬 모델: 모델 하나에 한 줄 ("Ollama  qwen3:8b  5.2GB"). 두 줄이 넘으면 아래로 스크롤
private struct LocalModelsCard: View {
    let servers: [LocalModelServer]
    /// 제목과 모델 수 · 메모리 합만
    var compact = false

    private var rows: [(server: String, model: LocalModel)] {
        servers.flatMap { server in server.models.map { (server.kind.displayName, $0) } }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("로컬")
                    .agentsFont(size: 10, weight: .semibold)
                    .foregroundStyle(AgentsStyle.localColor)
                Text(compact ? summary : "모델 \(rows.count)개")
                    .agentsFont(size: 9)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .fixedSize()
            if compact {
                EmptyView()
            } else if rows.count > 2 {
                ScrollView(.vertical, showsIndicators: false) { grid.padding(.vertical, 4) }
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                grid
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(rows.map { row in
            "\(row.server) · \(row.model.name)" + (row.model.memoryBytes.map { " · \(AgentsStyle.bytes($0))" } ?? "")
        }.joined(separator: "\n"))
    }

    /// "모델 2개 · 9.4GB"
    private var summary: String {
        let total = rows.compactMap(\.model.memoryBytes).reduce(0, +)
        return "모델 \(rows.count)개" + (total > 0 ? " · \(AgentsStyle.bytes(total))" : "")
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.server)
                        .agentsFont(size: 9.5)
                        .foregroundStyle(.secondary)
                    // 긴 이름은 앞부분만 (카드가 사용량 줄을 다 차지하지 않게)
                    Text(row.model.name.count > 26 ? row.model.name.prefix(25) + "…" : row.model.name)
                        .agentsFont(size: 10.5, weight: .semibold)
                    Text(row.model.memoryBytes.map(AgentsStyle.bytes) ?? "")
                        .agentsFont(size: 10)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

private struct UsageCardTitle: View {
    let kind: AgentKind
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .agentsFont(size: 10, weight: .semibold)
                .foregroundStyle(AgentsStyle.color(kind))
            if let detail {
                Text(detail)
                    .agentsFont(size: 9)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

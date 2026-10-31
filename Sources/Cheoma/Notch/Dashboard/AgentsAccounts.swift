import SwiftUI

/// 계정 한눈에 보기: Claude 계정마다 이메일 · 요금제 · 5시간 · 주간 한도 · 돌고 있는 세션, 그리고 Codex 로그인
struct AgentsAccountsPane: View {
    @ObservedObject var store: AgentStore
    @Binding var pane: AgentsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AgentsPaneHeader(title: "계정", detail: "이 맥에 로그인된 에이전트 계정이에요", pane: $pane)
            ViewThatFits(in: .vertical) {
                cards
                ScrollView(.vertical, showsIndicators: false) { cards }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 한 줄에 셋씩 (Lazy 격자는 미리보기 그림에 안 그려지고 계정 수도 몇 개 안 된다)
    private var cards: some View {
        let items = cardItems
        return Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: Self.columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + Self.columns, items.count), id: \.self) { index in
                        card(items[index])
                    }
                }
            }
        }
    }

    private static let columns = 3

    private enum Item {
        case claude(ClaudeUsage)
        case codex(AgentAccounts.Codex)
    }

    private var cardItems: [Item] {
        store.usage.claude.map(Item.claude) + (store.usage.codexAccount.map { [Item.codex($0)] } ?? [])
    }

    @ViewBuilder
    private func card(_ item: Item) -> some View {
        switch item {
        case .claude(let account):
            ClaudeAccountCard(account: account, running: store.sessions.filter { $0.account == account.account && $0.state != .exited }.count)
        case .codex(let codex):
            CodexAccountCard(account: codex, usage: store.usage.codex,
                             running: store.sessions.filter { $0.kind == .codex && $0.state != .exited }.count)
        }
    }
}

private struct ClaudeAccountCard: View {
    let account: ClaudeUsage
    let running: Int

    var body: some View {
        AccountCard(kind: .claude, title: AgentsStyle.accountName(account.account), plan: account.plan,
                    email: account.email ?? "로그인 정보 없음") {
            if account.limits.isEmpty {
                Text("한도 정보 없음 · 이 계정으로 Claude Code를 한 번 쓰면 보여요")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(account.limits, id: \.windowMinutes) { AccountUsageBar(window: $0) }
            }
        } footer: {
            Text(footer)
        }
        .help(help)
    }

    private var footer: String {
        var parts = [running > 0 ? "세션 \(running)개 도는 중" : "도는 세션 없음"]
        if let date = account.limitsUpdatedAt { parts.append("한도 \(AgentsStyle.ago(date)) 받음") }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        let run = AgentResume.isDefault(configDir: account.configDir) ? "claude" : "CLAUDE_CONFIG_DIR=\(AgentsStyle.abbreviated(account.configDir)) claude"
        return ["설정 폴더 \(AgentsStyle.abbreviated(account.configDir))", "실행: \(run)",
                "오늘 \(AgentsStyle.tokens(account.todayTokens)) 토큰"].joined(separator: "\n")
    }
}

private struct CodexAccountCard: View {
    let account: AgentAccounts.Codex
    let usage: CodexUsage?
    let running: Int

    var body: some View {
        AccountCard(kind: .codex, title: "Codex", plan: account.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() },
                    email: account.email ?? (account.mode == "apikey" ? "API 키로 로그인" : "로그인 정보 없음")) {
            let windows = [usage?.primary, usage?.secondary].compactMap { $0 }
            if windows.isEmpty {
                Text("한도 정보 없음 · Codex를 한 번 쓰면 보여요")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(windows, id: \.windowMinutes) { AccountUsageBar(window: $0) }
            }
        } footer: {
            Text(([running > 0 ? "세션 \(running)개 도는 중" : "도는 세션 없음"]
                  + [usage.map { "한도 \(AgentsStyle.ago($0.updatedAt)) 기록" }].compactMap { $0 }).joined(separator: " · "))
        }
        .help(account.mode == "chatgpt" ? "ChatGPT 계정으로 로그인 (~/.codex/auth.json)" : "~/.codex/auth.json")
    }
}

private struct AccountCard<Bars: View, Footer: View>: View {
    let kind: AgentKind
    let title: String
    let plan: String?
    let email: String
    @ViewBuilder let bars: Bars
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AgentMark(kind: kind, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        if let plan {
                            Text(plan)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AgentsStyle.color(kind))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(AgentsStyle.color(kind).opacity(0.18), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(email)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            bars
            footer
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "5시간 13% ▬▬▬▬ 2시간 뒤 초기화"
struct AccountUsageBar: View {
    let window: UsageWindow

    var body: some View {
        let now = Date()
        let isReset = window.resetsAt.map { $0 <= now } ?? false
        let percent = isReset ? 0 : window.usedPercent
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(AgentsStyle.windowName(minutes: window.windowMinutes))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Spacer(minLength: 6)
                if let resetsAt = window.resetsAt {
                    // 좁으면 "초기화"를 뺀다
                    ViewThatFits(in: .horizontal) {
                        Text(isReset ? "초기화됨" : "\(AgentsStyle.until(resetsAt, now: now)) 초기화")
                        Text(isReset ? "초기화됨" : AgentsStyle.until(resetsAt, now: now))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
    }
}

/// 오른쪽 칸 위 제목과 닫기 단추
struct AgentsPaneHeader: View {
    let title: String
    var detail: String?
    @Binding var pane: AgentsPane

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            AgentsCloseButton(pane: $pane)
        }
    }
}

/// 오른쪽 칸을 닫고 세션 화면으로 돌아간다
struct AgentsCloseButton: View {
    @Binding var pane: AgentsPane

    var body: some View {
        Button { pane = .session } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("닫기")
    }
}

// MARK: - 기록으로 남은 세션

/// 왼쪽 '최근 기록'에서 고른 세션: 무엇을 하던 세션인지, 이어서 하기
struct AgentsRecordDetail: View {
    let record: RecordedSession
    @ObservedObject var store: AgentStore
    @Binding var pane: AgentsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentMark(kind: record.kind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(record.kind.displayName) · \(project)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let title = record.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                AgentsCloseButton(pane: $pane)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let cwd = record.cwd { info("폴더", AgentsStyle.abbreviated(cwd)) }
                if let account = record.account { info("계정", accountText(account)) }
                info("마지막", "\(AgentsStyle.ago(record.lastActivity)) · \(record.isTurnComplete == false ? "하던 중에 멈춤" : "차례를 마침")")
                if let cost = record.costUSD { info("API 환산", AgentsStyle.cost(cost)) }
            }
            if let message = record.lastMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Spacer(minLength: 0)
            if let target = AgentsResumeOptions.target(record) {
                AgentsResumeOptions(target: target, currentAccount: record.account, store: store) { pane = .session }
            } else {
                Text(record.cwd == nil ? "작업 폴더를 몰라서 이어서 할 수 없어요" : "\(record.kind.displayName)는 여기서 이어서 할 수 없어요")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var project: String {
        record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
    }

    private func accountText(_ account: String) -> String {
        let email = store.usage.claude.first { $0.account == account }?.email
        return [AgentsStyle.accountName(account), email].compactMap { $0 }.joined(separator: " · ")
    }

    private func info(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 이어서 하기 단추들: 같은 계정으로, 또는 다른 Claude 계정으로 (그 계정의 5시간 한도도 같이 보여준다)
struct AgentsResumeOptions: View {
    let target: AgentResume.Target
    let currentAccount: String?
    var includesCurrent = true
    @ObservedObject var store: AgentStore
    var onStart: () -> Void = {}

    static func target(_ record: RecordedSession) -> AgentResume.Target? {
        guard AgentResume.canResume(record.kind), let cwd = record.cwd, !cwd.isEmpty else { return nil }
        let configDir = record.transcriptPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
        return AgentResume.Target(kind: record.kind, sessionID: record.id, cwd: cwd, configDir: record.kind == .claude ? configDir : nil)
    }

    static func target(_ session: AgentSession, store: AgentStore) -> AgentResume.Target? {
        guard AgentResume.canResume(session.kind), let id = session.sessionID ?? session.lastEvent?.sessionID,
              let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let configDir = session.account.flatMap { account in store.usage.claude.first { $0.account == account }?.configDir }
        return AgentResume.Target(kind: session.kind, sessionID: id, cwd: cwd, configDir: configDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.isTmuxAvailable ? "tmux 새 세션에서 이어서 해요" : "이어서 하려면 tmux가 필요해요 (brew install tmux)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                ForEach(options, id: \.title) { option in
                    AgentsCapsuleButton(title: option.title, symbol: option.symbol, prominent: option.isCurrent) {
                        store.resume(target, configDir: option.configDir)
                        onStart()
                    }
                    .help(option.help)
                    .disabled(!store.isTmuxAvailable)
                }
            }
        }
    }

    private struct Option {
        var title: String
        var symbol: String
        var configDir: String?
        var isCurrent: Bool
        var help: String
    }

    private var options: [Option] {
        guard target.kind == .claude else {
            return [Option(title: "이어서 하기", symbol: "play.fill", configDir: nil, isCurrent: true,
                           help: AgentResume.resumeCommand(target, configDir: nil))]
        }
        let accounts = store.usage.claude
        let current = currentAccount ?? accounts.first { $0.configDir == target.configDir }?.account
        return accounts.map { account in
            let isCurrent = account.account == current
            let fiveHour = account.limits.first { $0.windowMinutes == 300 }
            let percent = fiveHour.map { window -> String in
                let reset = window.resetsAt.map { $0 <= Date() } ?? false
                return " · 5시간 \(reset ? 0 : Int(window.usedPercent.rounded()))%"
            } ?? ""
            let name = AgentsStyle.accountName(account.account)
            return Option(title: isCurrent ? "이어서 하기" : "\(name)로 이어서\(percent)",
                          symbol: isCurrent ? "play.fill" : "arrow.triangle.swap",
                          configDir: account.configDir, isCurrent: isCurrent,
                          help: (isCurrent ? "\(name) 계정으로 이어서 해요" : "대화 기록을 \(name) 계정으로 복사하고 그 계정으로 이어서 해요 (원래 기록은 그대로)")
                              + "\n\(AgentResume.resumeCommand(target, configDir: account.configDir))")
        }
        .filter { includesCurrent || !$0.isCurrent }
        .sorted { $0.isCurrent && !$1.isCurrent }
    }
}

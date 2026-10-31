import SwiftUI

/// 에이전트 탭 왼쪽: 돌고 있는 세션 (최근에 움직인 것 먼저), 그 아래 기록으로만 아는 최근 세션
struct AgentsSessionList: View {
    let sessions: [AgentSession]
    let recorded: [RecordedSession]
    let selectedID: AgentSession.ID?
    let selectedRecordID: RecordedSession.ID?
    let onSelect: (AgentSession.ID) -> Void
    let onSelectRecord: (RecordedSession.ID) -> Void

    var body: some View {
        // 경과 시간("3분")은 세션이 안 바뀌어도 흐르므로 30초마다 다시 그린다
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // 다 들어가면 그냥 쌓고, 넘칠 때만 스크롤한다 (스크롤 뷰는 AppKit 뷰라 무겁다)
            ViewThatFits(in: .vertical) {
                rows(now: context.date)
                ScrollView(.vertical, showsIndicators: false) { rows(now: context.date) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if sessions.isEmpty {
                Text("실행 중인 에이전트가 없어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            ForEach(sessions) { session in
                SessionRow(session: session, isSelected: session.id == selectedID, now: now)
                    .onTapGesture { onSelect(session.id) }
            }
            if !recorded.isEmpty {
                Text("최근 기록 · 눌러서 이어서 하기")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.top, sessions.isEmpty ? 0 : 8)
                    .padding(.bottom, 2)
                ForEach(recorded) { record in
                    RecordedRow(record: record, isSelected: record.id == selectedRecordID, now: now)
                        .onTapGesture { onSelectRecord(record.id) }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            AgentMark(kind: session.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    AgentStateChip(state: session.state)
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(place) · \(AgentsStyle.elapsed(since: session.stateSince, now: now))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isSelected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .help("\(session.kind.displayName) · \(session.cwd.map(AgentsStyle.abbreviated) ?? session.projectName)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var subtitle: String {
        if let title = session.title, !title.isEmpty { return title }
        if let summary = session.analysis?.summary, !summary.isEmpty { return summary }
        return session.kind.displayName
    }

    /// 어디서 도는지, 기본 계정이 아니면 계정 이름도 ("터미널 · account2")
    private var place: String {
        let where_: String = switch session.location {
        case .terminalApp: "터미널"
        case .tmux: "tmux"
        case .other(_, let app): app ?? "보기만"
        }
        guard let account = session.account, account != ".claude" else { return where_ }
        return "\(where_) · \(AgentsStyle.accountName(account))"
    }
}

private struct RecordedRow: View {
    let record: RecordedSession
    let isSelected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            AgentMark(kind: record.kind, size: 15)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(AgentsStyle.ago(record.lastActivity, now: now))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: 21)
        .background(isSelected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var project: String? {
        guard let cwd = record.cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private var text: String {
        [record.kind.displayName, project, record.title].compactMap { $0 }.joined(separator: " · ")
    }

    private var help: String {
        var lines = [text]
        if let message = record.lastMessage { lines.append(message) }
        if let cost = record.costUSD { lines.append("비용 \(AgentsStyle.cost(cost))") }
        lines.append("누르면 이어서 할 수 있어요")
        return lines.joined(separator: "\n")
    }
}

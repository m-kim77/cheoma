import AppKit
import SwiftUI

/// 연결 설정: 세션이 없을 때 처음 보이는 안내, 또는 톱니 버튼으로 연다.
/// Terminal 자동화 권한, Claude Code · Codex 훅, 새 에이전트 실행
struct AgentsSetupPane: View {
    @ObservedObject var store: AgentStore
    let isEmpty: Bool
    @Binding var pane: AgentsPane
    @AppStorage(ClaudeUsageDisplay.defaultsKey) private var usageDisplay = ClaudeUsageDisplay.limits

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(isEmpty ? "코드 에이전트를 여기서 지켜봐요" : "연결 설정")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    AgentsCapsuleButton(title: "설정 창 열기", symbol: "macwindow") {
                        NotificationCenter.default.post(name: SettingsWindowController.openNotification, object: nil)
                    }
                    .help("계정 · 알림 연결 · 노치 모양을 한곳에서 봐요")
                    if !isEmpty { closeButton }
                }
                Text("Terminal 탭이나 tmux에서 도는 Claude Code · Codex 같은 에이전트의 상태를 보여주고, 터미널로 가지 않고도 여기서 답할 수 있어요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                terminalRow
                claudeRow
                codexRow
                usageRow
                launchRow
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var closeButton: some View {
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

    private var terminalRow: some View {
        SetupRow(symbol: "terminal", title: "Terminal") {
            switch store.terminalPermission {
            case .granted:
                SetupDone(text: "연결됨")
            case .notDetermined:
                SetupDetail(text: "Terminal 탭의 화면을 읽고 답을 보내려면 허락이 필요해요")
                AgentsCapsuleButton(title: "Terminal 연결", prominent: true) { store.requestTerminalAccess() }
            case .denied:
                SetupDetail(text: "거절됨 · 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 Cheoma의 Terminal을 켜 주세요")
            case .targetNotRunning:
                SetupDetail(text: "Terminal을 켜면 연결할 수 있어요")
            }
        }
    }

    @ViewBuilder
    private var claudeRow: some View {
        let targets = store.hookStatus.claude
        SetupRow(symbol: "bell.badge", title: "Claude Code") {
            if targets.isEmpty {
                SetupDetail(text: "Claude Code 설정 폴더(~/.claude)가 없어요")
            } else if targets.allSatisfy(\.isInstalled) {
                let occupied = targets.filter { if case .occupied = $0.statusLine { return true }; return false }
                if occupied.isEmpty {
                    SetupDone(text: targets.count > 1 ? "계정 \(targets.count)개 연결됨" : "연결됨")
                } else {
                    SetupDetail(text: "연결됨 · \(occupied.map { AgentsStyle.accountName($0.configDir.lastPathComponent) }.joined(separator: ", "))은 "
                                + "상태 줄을 다른 프로그램이 쓰고 있어서 구독 한도를 받을 수 없어요")
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    SetupDetail(text: "선택을 기다리거나 차례가 끝나면 바로 알리고, 상태 줄로 구독 한도를 받아요")
                    HStack(spacing: 10) {
                        ForEach(targets, id: \.configDir) { target in
                            Label(AgentsStyle.accountName(target.configDir.lastPathComponent),
                                  systemImage: target.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(target.isInstalled ? Color.green : Color.white.opacity(0.5))
                                .lineLimit(1)
                                .help(target.isInstalled ? "연결됨" : "아직 연결 안 됨")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AgentsCapsuleButton(title: "Claude Code 연결", prominent: true) { store.installHooks() }
            }
        }
    }

    @ViewBuilder
    private var codexRow: some View {
        switch store.hookStatus.codex {
        case .unavailable:
            EmptyView()
        case .installed:
            SetupRow(symbol: "bell.badge", title: "Codex") { SetupDone(text: "연결됨") }
        case .notInstalled:
            SetupRow(symbol: "bell.badge", title: "Codex") {
                SetupDetail(text: "차례가 끝나면 바로 알려요")
                AgentsCapsuleButton(title: "Codex 연결", prominent: true) { store.installHooks() }
            }
        case .occupied(let program):
            SetupRow(symbol: "bell.badge", title: "Codex") {
                SetupDetail(text: "notify 자리를 \(program)에서 쓰고 있어서 건드리지 않았어요 · 상태는 화면을 읽어서 알아내요")
            }
        }
    }

    /// 위쪽 Claude 사용량: 구독 한도(기본) 또는 API 가격으로 셈한 비용
    private var usageRow: some View {
        SetupRow(symbol: "gauge.with.dots.needle.50percent", title: "Claude 사용량") {
            SetupDetail(text: usageDisplay == .limits ? "구독의 5시간 · 주간 한도를 쓴 비율" : "쓴 토큰을 API 가격으로 셈한 값 · 구독이면 실제로 청구되지 않아요")
            HStack(spacing: 2) {
                ForEach(ClaudeUsageDisplay.allCases, id: \.self) { option in
                    Button { usageDisplay = option } label: {
                        Text(option.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(usageDisplay == option ? Color.white.opacity(0.2) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.white.opacity(0.07), in: Capsule())
        }
    }

    private var launchRow: some View {
        SetupRow(symbol: "plus.rectangle.on.rectangle", title: "새 에이전트") {
            if store.isTmuxAvailable {
                SetupDetail(text: "tmux 새 세션에서 띄우면 Esc · 방향키까지 보낼 수 있어요")
                AgentsCapsuleButton(title: "새 에이전트 실행", prominent: true) { pane = .launcher }
            } else {
                SetupDetail(text: "tmux가 필요해요 (brew install tmux)")
            }
        }
    }
}

private struct SetupRow<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(width: 74, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    }
}

private struct SetupDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupDone: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 새 에이전트 고르기: 어떤 에이전트를 어느 폴더에서 띄울지. 노치 안에서 고른다 (창을 따로 띄우지 않는다)
struct AgentsLauncherPane: View {
    @ObservedObject var store: AgentStore
    let model: NotchModel
    @Binding var pane: AgentsPane
    @State private var kind: AgentKind?
    @State private var folder: String?
    /// "다른 폴더…"로 고른 폴더 (목록 맨 앞에 붙는다)
    @State private var pickedFolder: String?
    /// Claude를 띄울 계정 (설정 폴더). 고르지 않으면 한도가 가장 넉넉한 계정
    @State private var configDir: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("새 에이전트")
                    .font(.system(size: 13, weight: .semibold))
                Text("tmux 새 세션에서 실행해요")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
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

            section("에이전트") {
                if store.installedAgents.isEmpty {
                    Text("설치된 에이전트를 찾지 못했어요")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        ForEach(store.installedAgents, id: \.self) { item in
                            agentButton(item)
                        }
                    }
                }
            }

            if selectedKind == .claude, store.usage.claude.count > 1 {
                section("계정") {
                    HStack(spacing: 5) {
                        ForEach(store.usage.claude, id: \.account) { account in
                            accountButton(account)
                        }
                    }
                }
            }

            section("폴더") {
                ViewThatFits(in: .vertical) {
                    folderList
                    ScrollView(.vertical, showsIndicators: false) { folderList }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                if !store.isTmuxAvailable {
                    Label("tmux가 필요해요 (brew install tmux)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if let kind = selectedKind, let folder = selectedFolder {
                    Text("\(AgentResume.launchCommand(kind, configDir: kind == .claude ? selectedConfigDir : nil)) · \(AgentsStyle.abbreviated(folder))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                AgentsCapsuleButton(title: "실행", symbol: "play.fill", prominent: canLaunch) {
                    guard canLaunch, let kind = selectedKind, let folder = selectedFolder else { return }
                    store.launch(kind, in: folder, configDir: kind == .claude ? selectedConfigDir : nil)
                    pane = .session
                }
                .disabled(!canLaunch)
                .opacity(canLaunch ? 1 : 0.45)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var selectedKind: AgentKind? { kind ?? store.installedAgents.first }

    /// 고른 계정, 아니면 5시간 한도를 가장 적게 쓴 계정
    private var selectedConfigDir: String? {
        if let configDir { return configDir }
        return store.usage.claude.min { Self.fiveHourPercent($0) < Self.fiveHourPercent($1) }?.configDir
    }

    private static func fiveHourPercent(_ account: ClaudeUsage) -> Double {
        guard let window = account.limits.first(where: { $0.windowMinutes == 300 }) else { return 100 }
        return (window.resetsAt.map { $0 <= Date() } ?? false) ? 0 : window.usedPercent
    }

    private func accountButton(_ account: ClaudeUsage) -> some View {
        let isSelected = account.configDir == selectedConfigDir
        let percent = account.limits.isEmpty ? "" : " \(Int(Self.fiveHourPercent(account).rounded()))%"
        return Button { configDir = account.configDir } label: {
            Text(AgentsStyle.accountName(account.account) + percent)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.white.opacity(isSelected ? 0.2 : 0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help([account.email, account.plan].compactMap { $0 }.joined(separator: " · ") + (percent.isEmpty ? "" : " · 5시간 한도\(percent) 씀"))
    }
    private var selectedFolder: String? { folder ?? folders.first }
    private var canLaunch: Bool { store.isTmuxAvailable && selectedKind != nil && selectedFolder != nil }

    private var folders: [String] {
        var list = store.recentFolders
        if let pickedFolder {
            list.removeAll { $0 == pickedFolder }
            list.insert(pickedFolder, at: 0)
        }
        return list
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func agentButton(_ item: AgentKind) -> some View {
        let isSelected = item == selectedKind
        return Button { kind = item } label: {
            HStack(spacing: 5) {
                AgentMark(kind: item, size: 16)
                Text(item.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(.white.opacity(isSelected ? 0.2 : 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var folderList: some View {
        VStack(spacing: 2) {
            ForEach(folders, id: \.self) { path in
                folderRow(path)
            }
            otherFolderRow
        }
    }

    private func folderRow(_ path: String) -> some View {
        let isSelected = path == selectedFolder
        return Button { folder = path } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text(AgentsStyle.abbreviated(path))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(isSelected ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var otherFolderRow: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("다른 폴더…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 폴더 고르기 창. 노치는 메뉴바 앱이라 잠깐 앞으로 나왔다가, 다 고르면 원래 쓰던 앱을 다시 앞으로 돌려준다
    private func chooseFolder() {
        let previous = NSWorkspace.shared.frontmostApplication
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "고르기"
        panel.message = "에이전트를 실행할 폴더를 고르세요"
        if let current = selectedFolder { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        // 고르는 동안 마우스가 노치 밖에 있어도 닫히지 않게
        model.keepsOpen = true
        NSApp.activate()
        let response = panel.runModal()
        model.keepsOpen = false
        if response == .OK, let url = panel.url {
            pickedFolder = url.path
            folder = url.path
        }
        if let previous, previous != NSRunningApplication.current { previous.activate() }
    }
}

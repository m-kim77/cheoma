import AppKit
import ServiceManagement
import SwiftUI

/// 설정 창: 노치 안에 다 넣기 어려운 설정을 한곳에서 본다 (메뉴바 메뉴의 "설정…", 에이전트 탭 연결 설정의 "설정 창 열기")
@MainActor
final class SettingsWindowController {
    /// 노치 안에서 설정 창을 열 때 보낸다 (노치 뷰는 이 컨트롤러를 모른다)
    static let openNotification = Notification.Name("io.github.m-kim77.cheoma.openSettings")

    private let model: NotchModel
    private let agents: AgentStore
    private let updates: UpdateChecker
    private let dictation: DictationController
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// 닫았다 다시 열어도 제자리에 뜨게 마지막 자리를 기억한다 (창은 닫을 때 놓는다)
    private var lastOrigin: CGPoint?

    init(model: NotchModel, agents: AgentStore, updates: UpdateChecker, dictation: DictationController) {
        self.model = model
        self.agents = agents
        self.updates = updates
        self.dictation = dictation
    }

    /// tab을 주면 그 탭으로 연다 (메뉴의 "업데이트 확인…" → 업데이트)
    func show(tab: SettingsView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        let window = loadWindow()
        agents.refreshNow()
        // 메뉴바 앱이라 앞으로 나오게 해야 창이 다른 앱 뒤에 숨지 않는다
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 창을 만들어 둔다 (이미 있으면 그대로). 띄우지는 않는다
    func loadWindow() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        self.window = window
        return window
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model, agents: agents, updates: updates,
                                                                 dictation: dictation, navigation: navigation))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cheoma 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 560, height: 520))
        if let lastOrigin { window.setFrameOrigin(lastOrigin) } else { window.center() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        return window
    }

    /// 닫으면 창과 뷰를 놓는다. 들고 있으면 닫힌 창도 AgentStore가 바뀔 때마다 탭 네 개를 다시 계산하고,
    /// 그때마다 Picker가 만든 객체가 쌓였다 (3초에 하나, 앱을 끌 때까지)
    private func windowWillClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let closing = window else { return }
        lastOrigin = closing.frame.origin
        window = nil
        // 닫히는 중인 창의 내용은 다음 차례에 뗀다
        DispatchQueue.main.async {
            MainActor.assumeIsolated { closing.contentViewController = nil }
        }
    }
}

/// 설정 창이 보여 줄 탭. 창 밖(메뉴)에서도 바꿀 수 있게 따로 둔다
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsView.Tab

    init(tab: SettingsView.Tab = .general) {
        self.tab = tab
    }
}

struct SettingsView: View {
    enum Tab: Hashable { case general, agents, accounts, dictation, updates }

    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentStore
    let updates: UpdateChecker
    /// 받아쓰기 탭만 지켜본다 (설정이 바뀔 때 다른 탭까지 다시 그리지 않게)
    let dictation: DictationController
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(model: model)
                .tabItem { Label("일반", systemImage: "gearshape") }
                .tag(Tab.general)
            AgentSettings(agents: agents)
                .tabItem { Label("에이전트", systemImage: "terminal") }
                .tag(Tab.agents)
            AccountSettings(agents: agents)
                .tabItem { Label("계정", systemImage: "person.2") }
                .tag(Tab.accounts)
            DictationSettingsTab(dictation: dictation)
                .tabItem { Label("받아쓰기", systemImage: "mic") }
                .tag(Tab.dictation)
            UpdateSettings(updates: updates)
                .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - 일반

private struct GeneralSettings: View {
    @ObservedObject var model: NotchModel
    @AppStorage(AgentsScreenTextSize.defaultsKey) private var screenTextSize = AgentsScreenTextSize.fit
    @State private var warnings = WarningAlerts.isEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("노치") {
                Picker("펼친 모양", selection: $model.theme) {
                    ForEach(NotchTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("과열 · 메모리 · 배터리 경고", isOn: $warnings)
                    .onChange(of: warnings) { _, value in WarningAlerts.isEnabled = value }
            }
            Section("에이전트 탭") {
                Picker("글자 크기", selection: $model.agentsTextScale) {
                    ForEach(AgentsTextScale.allCases, id: \.self) { Text("\($0.title) · \($0.percent)").tag($0) }
                }
                Picker("터미널 글자 크기", selection: $screenTextSize) {
                    ForEach(AgentsScreenTextSize.steps, id: \.self) { Text(AgentsScreenTextSize.title($0)).tag($0) }
                }
                LabeledContent("탭 크기") {
                    HStack {
                        Text("\(Int(model.agentsSize.width)) × \(Int(model.agentsSize.height))").monospacedDigit()
                        Button("기본값으로") { model.resetAgentsSize() }
                            .disabled(model.isAgentsSizeDefault)
                    }
                }
            }
            // 로그인 항목은 .app 번들로 실행할 때만 등록할 수 있다
            if Bundle.main.bundleIdentifier != nil {
                Section("시작") {
                    Toggle("로그인 시 열기", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, value in setLaunchAtLogin(value) }
                }
            }
            Section("언어") {
                LabeledContent("화면 언어", value: "한국어")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            AppLog.write("로그인 항목 설정 실패: \(error.localizedDescription)")
        }
        launchAtLogin = service.status == .enabled
    }
}

// MARK: - 업데이트

private struct UpdateSettings: View {
    @ObservedObject var updates: UpdateChecker
    @AppStorage(UpdateChecker.enabledKey) private var checksUpdates = true

    var body: some View {
        Form {
            Section {
                Toggle("자동으로 업데이트 확인", isOn: $checksUpdates)
                    .onChange(of: checksUpdates) { _, value in if value { updates.checkIfDue() } }
                LabeledContent("현재 버전", value: updates.current?.description ?? "개발 빌드")
                HStack {
                    Text(updateStatus).foregroundStyle(.secondary)
                    Spacer()
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Button("지금 확인") { updates.checkNow() }
                        .disabled(updates.isChecking || updates.current == nil)
                }
            } footer: {
                Text("하루에 한 번 GitHub에서 새 버전을 확인합니다.")
            }
            if let release = updates.available {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("변경 사항")
                        Self.markdown(release.summary())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("Cheoma.zip").foregroundStyle(.secondary)
                        Spacer()
                        Button("다운로드") { NSWorkspace.shared.open(release.htmlURL) }
                            .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("새 버전 \(release.version?.description ?? release.tagName)")
                } footer: {
                    Text("Cheoma를 종료한 후 응용 프로그램 폴더의 Cheoma를 새 버전으로 교체하십시오.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updateStatus: String {
        if updates.current == nil { return "개발 빌드에서는 확인하지 않음" }
        if updates.isChecking { return "확인 중…" }
        if updates.lastCheckFailed { return "확인할 수 없음 · 인터넷 연결 확인 필요" }
        guard let checked = updates.lastChecked else { return "확인 기록 없음" }
        let when = AgentsStyle.ago(checked)
        return updates.available == nil ? "최신 버전 · \(when) 확인" : "새 버전 있음 · \(when) 확인"
    }

    /// 굵게 · 링크 같은 줄 안의 마크다운만 그린다 (줄바꿈은 그대로)
    private static func markdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map(Text.init) ?? Text(text)
    }
}

// MARK: - 에이전트

private struct AgentSettings: View {
    @ObservedObject var agents: AgentStore
    @AppStorage(ClaudeUsageDisplay.defaultsKey) private var usageDisplay = ClaudeUsageDisplay.limits

    var body: some View {
        Form {
            Section {
                if agents.installedAgents.isEmpty {
                    Text("설치된 에이전트 없음").foregroundStyle(.secondary)
                }
                ForEach(shownKinds, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { !agents.hiddenKinds.contains(kind) },
                                         set: { agents.setHidden(kind, !$0) })) {
                        Label {
                            Text(kind.displayName)
                            if !agents.installedAgents.contains(kind) { Text("설치 안 됨") }
                        } icon: {
                            AgentMark(kind: kind, size: 18)
                        }
                    }
                }
            } header: {
                Text("표시할 에이전트")
            } footer: {
                Text("끈 에이전트는 노치에 표시되지 않습니다.")
            }

            Section {
                LabeledContent("Terminal") {
                    switch agents.terminalPermission {
                    case .granted: Label("연결됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined: Button("연결…") { agents.requestTerminalAccess() }
                    case .denied: Text("거부됨 · 개인정보 보호 및 보안 › 자동화").foregroundStyle(.secondary)
                    case .targetNotRunning: Text("Terminal 실행 안 됨").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("tmux", value: agents.isTmuxAvailable ? "설치됨" : "설치 안 됨 (brew install tmux)")
            } header: {
                Text("터미널")
            } footer: {
                Text("Terminal 탭을 읽고 입력하려면 자동화 권한이 필요합니다.")
            }

            Section {
                ForEach(agents.hookStatus.claude, id: \.configDir) { target in
                    LabeledContent {
                        Text(claudeStatus(target)).foregroundStyle(target.isInstalled ? .green : .secondary)
                    } label: {
                        Text("Claude Code · \(AgentsStyle.accountName(target.configDir.lastPathComponent))")
                        Text(AgentsStyle.abbreviated(target.configDir.path))
                    }
                }
                LabeledContent("Codex", value: codexStatus)
                HStack {
                    Spacer()
                    Button("연결 해제") { agents.uninstallHooks() }
                        .disabled(!agents.hookStatus.claude.contains { $0.hooks } && agents.hookStatus.codex != .installed)
                    Button("모두 연결") { agents.installHooks() }
                        .disabled(agents.hookStatus.claude.allSatisfy(\.isInstalled) && agents.hookStatus.codex != .notInstalled)
                }
            } header: {
                Text("알림 연결")
            } footer: {
                Text("에이전트가 입력을 기다리거나 작업을 마치면 노치에 알립니다. 기존 설정 파일은 .cheoma-backup으로 백업됩니다.")
            }

            Section {
                Picker("Claude 사용량", selection: $usageDisplay) {
                    ForEach(ClaudeUsageDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("사용량 표시")
            } footer: {
                Text(usageDisplay == .limits ? "5시간 · 주간 한도 사용률" : "API 가격 환산 · 구독 요금제는 청구되지 않음")
            }
        }
        .formStyle(.grouped)
    }

    /// 설치된 에이전트와, 설치는 안 됐지만 숨겨 둔 에이전트
    private var shownKinds: [AgentKind] {
        AgentKind.allCases.filter { agents.installedAgents.contains($0) || agents.hiddenKinds.contains($0) }
    }

    private func claudeStatus(_ target: HookInstaller.ClaudeTarget) -> String {
        guard target.hooks else { return "연결 안 됨" }
        switch target.statusLine {
        case .installed: return "연결됨"
        case .notInstalled: return "알림만 연결됨"
        case .occupied: return "연결됨 · 상태 줄은 다른 프로그램이 사용 중"
        }
    }

    private var codexStatus: String {
        switch agents.hookStatus.codex {
        case .installed: "연결됨"
        case .notInstalled: "연결 안 됨"
        case .occupied(let program): "notify 사용 중: \(program)"
        case .unavailable: "설정 없음"
        }
    }
}

// MARK: - 계정 추가

/// 구독 계정 하나 더: 다음 번호 폴더 · alias를 만들고 Terminal에서 로그인한다 (Claude Code, Codex)
private struct AddAccountSection: View {
    @ObservedObject var agents: AgentStore
    let kinds: [AgentKind]
    @Binding var kind: AgentKind
    /// 다음 번호 · alias (AccountSettings가 읽어 둔 것)
    let plan: AccountSetup.Plan?

    var body: some View {
        Section {
            if kinds.isEmpty {
                Text("Claude Code 또는 Codex가 설치되어 있지 않음").foregroundStyle(.secondary)
            } else {
                Picker("에이전트", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if let plan {
                    LabeledContent("새 폴더", value: AgentsStyle.abbreviated(plan.folder.path))
                    LabeledContent(plan.aliasExists ? "터미널 명령" : "\(AgentsStyle.abbreviated(plan.shellFile.path))에 추가") {
                        Text(plan.aliasExists ? plan.aliasName : plan.aliasLine)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    LabeledContent("로그인") {
                        Text(plan.kind == .claude ? "Terminal에서 Claude Code 로그인" : "Terminal에서 codex login 실행")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("\(plan.kind.displayName) 계정 추가 (account\(plan.number))") {
                            agents.addAccount(plan)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        } header: {
            Text("계정 추가")
        } footer: {
            Text("셸 설정 파일 끝에 한 줄을 추가합니다.")
        }
    }
}

// MARK: - 계정

private struct AccountSettings: View {
    @ObservedObject var agents: AgentStore
    @State private var addKind: AgentKind = .claude
    /// 계정 추가의 다음 번호 · alias. 홈 폴더와 셸 설정 파일을 읽어 정하므로 그릴 때마다 읽지 않고 바뀔 만한 때만 다시 읽는다
    @State private var addPlan: AccountSetup.Plan?

    /// 폴더로 계정을 나눌 수 있고 설치된 에이전트
    private var addKinds: [AgentKind] {
        [AgentKind.claude, .codex].filter { agents.installedAgents.contains($0) }
    }

    /// 고른 에이전트가 설치돼 있지 않으면 첫 번째
    private var shownAddKind: AgentKind? {
        addKinds.contains(addKind) ? addKind : addKinds.first
    }

    private func reloadAddPlan() {
        addPlan = shownAddKind.flatMap { AccountSetup.plan($0) }
    }

    var body: some View {
        Form {
            ForEach(agents.usage.claude, id: \.account) { account in
                Section {
                    LabeledContent("이메일", value: account.email ?? "-")
                    LabeledContent("요금제", value: account.plan ?? "-")
                    limits(account.limits, updatedAt: account.limitsUpdatedAt)
                    LabeledContent("실행 중인 세션", value: "\(agents.sessions.filter { $0.account == account.account && $0.state != .exited }.count)개")
                    LabeledContent("설정 폴더", value: AgentsStyle.abbreviated(account.configDir))
                    LabeledContent("실행 명령") {
                        Text(AgentResume.launchCommand(.claude, configDir: account.configDir))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Claude Code · \(AgentsStyle.accountName(account.account))")
                }
            }
            ForEach(agents.usage.codex, id: \.home) { codex in
                Section {
                    LabeledContent("로그인", value: codex.login?.mode == "chatgpt" ? "ChatGPT 계정" : (codex.login?.mode == "apikey" ? "API 키" : "-"))
                    LabeledContent("이메일", value: codex.login?.email ?? "-")
                    LabeledContent("요금제", value: (codex.login?.plan ?? codex.usage?.plan).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "-")
                    limits([codex.usage?.primary, codex.usage?.secondary].compactMap { $0 }, updatedAt: codex.usage?.updatedAt)
                    LabeledContent("폴더", value: AgentsStyle.abbreviated(codex.home))
                    LabeledContent("실행 명령") {
                        Text(AgentResume.launchCommand(.codex, configDir: codex.home))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Codex · \(AgentsStyle.accountName(codex.account))")
                }
            }
            if agents.usage.claude.isEmpty && agents.usage.codex.isEmpty {
                Text("로그인된 계정 없음").foregroundStyle(.secondary)
            }
            AddAccountSection(agents: agents, kinds: addKinds, kind: $addKind, plan: addPlan)
        }
        .formStyle(.grouped)
        .onAppear { reloadAddPlan() }
        .onChange(of: shownAddKind) { reloadAddPlan() }
        // 계정 추가가 끝나면(폴더 · alias가 생기면) 알림이 뜬다: 그때 다음 번호로 넘어간다
        .onChange(of: agents.message) { reloadAddPlan() }
    }

    @ViewBuilder
    private func limits(_ windows: [UsageWindow], updatedAt: Date?) -> some View {
        if windows.isEmpty {
            LabeledContent("한도", value: "정보 없음")
        }
        ForEach(windows, id: \.windowMinutes) { window in
            let isReset = window.resetsAt.map { $0 <= Date() } ?? false
            let percent = isReset ? 0 : window.usedPercent
            LabeledContent {
                HStack(spacing: 8) {
                    ProgressView(value: min(percent, 100), total: 100)
                        .tint(AgentsStyle.usageColor(percent))
                        .frame(width: 140)
                    Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } label: {
                Text("\(AgentsStyle.windowName(minutes: window.windowMinutes)) 한도")
                if let resetsAt = window.resetsAt {
                    Text(isReset ? "초기화됨" : "\(AgentsStyle.until(resetsAt)) 초기화")
                }
            }
        }
        if let updatedAt, !windows.isEmpty {
            LabeledContent("마지막 업데이트", value: AgentsStyle.ago(updatedAt))
        }
    }
}

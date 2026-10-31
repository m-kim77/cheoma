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
    private var window: NSWindow?

    init(model: NotchModel, agents: AgentStore) {
        self.model = model
        self.agents = agents
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        agents.refreshNow()
        // 메뉴바 앱이라 앞으로 나오게 해야 창이 다른 앱 뒤에 숨지 않는다
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model, agents: agents))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cheoma 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 560, height: 520))
        window.center()
        return window
    }
}

struct SettingsView: View {
    enum Tab: Hashable, CaseIterable { case general, agents, accounts }

    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentStore
    @State var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("일반", systemImage: "gearshape") }
                .tag(Tab.general)
            AgentSettings(agents: agents)
                .tabItem { Label("에이전트", systemImage: "terminal") }
                .tag(Tab.agents)
            AccountSettings(agents: agents)
                .tabItem { Label("계정", systemImage: "person.2") }
                .tag(Tab.accounts)
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
                Toggle("경고 알림 (과열 · 메모리 · 배터리)", isOn: $warnings)
                    .onChange(of: warnings) { _, value in WarningAlerts.isEnabled = value }
            }
            Section("에이전트 탭") {
                Picker("글자 크기", selection: $model.agentsTextScale) {
                    ForEach(AgentsTextScale.allCases, id: \.self) { Text("\($0.title) · \($0.percent)").tag($0) }
                }
                Picker("터미널 화면 글자", selection: $screenTextSize) {
                    ForEach(AgentsScreenTextSize.steps, id: \.self) { Text(AgentsScreenTextSize.title($0)).tag($0) }
                }
                Text(screenTextSize == AgentsScreenTextSize.fit
                     ? "맞춤: 가장 긴 줄이 들어가게 글자를 줄여요"
                     : "폭을 넘는 줄은 다음 줄로 넘겨요. 미리보기 오른쪽 위 − + 로도 바꿔요")
                    .foregroundStyle(.secondary)
                LabeledContent("탭 크기", value: "\(Int(model.agentsSize.width)) × \(Int(model.agentsSize.height))")
                HStack {
                    Text("노치를 펼친 뒤 오른쪽 아래 모서리를 끌어서 바꿔요")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("기본 크기로") { model.resizeAgents(to: model.agentsMinimumSize) }
                        .disabled(model.agentsSize == model.agentsMinimumSize)
                }
            }
            // 로그인 항목은 .app 번들로 실행할 때만 등록할 수 있다
            if Bundle.main.bundleIdentifier != nil {
                Section("시작") {
                    Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
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

// MARK: - 에이전트

private struct AgentSettings: View {
    @ObservedObject var agents: AgentStore
    @AppStorage(ClaudeUsageDisplay.defaultsKey) private var usageDisplay = ClaudeUsageDisplay.limits

    var body: some View {
        Form {
            Section {
                LabeledContent("Terminal") {
                    switch agents.terminalPermission {
                    case .granted: Label("연결됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined: Button("Terminal 연결") { agents.requestTerminalAccess() }
                    case .denied: Text("거절됨 · 시스템 설정 › 개인정보 보호 및 보안 › 자동화").foregroundStyle(.secondary)
                    case .targetNotRunning: Text("Terminal을 켜면 연결할 수 있어요").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("tmux", value: agents.isTmuxAvailable ? "있음 · 새 에이전트 · 이어서 하기에 써요" : "없음 (brew install tmux)")
            } header: {
                Text("터미널")
            } footer: {
                Text("Terminal 탭의 화면을 읽고 답을 보내려면 Terminal 자동화 허락이 필요해요.")
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
                    Button("연결 끊기") { agents.uninstallHooks() }
                        .disabled(!agents.hookStatus.claude.contains { $0.hooks } && agents.hookStatus.codex != .installed)
                    Button("모두 연결") { agents.installHooks() }
                        .disabled(agents.hookStatus.claude.allSatisfy(\.isInstalled) && agents.hookStatus.codex != .notInstalled)
                }
            } header: {
                Text("알림 연결 (훅)")
            } footer: {
                Text("선택을 기다리거나 차례가 끝나면 노치로 바로 알려요. Claude Code는 상태 줄로 구독 한도도 받아요. 고치기 전의 설정 파일은 .cheoma-backup으로 남겨요.")
            }

            Section("사용량 표시") {
                Picker("Claude 사용량", selection: $usageDisplay) {
                    ForEach(ClaudeUsageDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(usageDisplay == .limits ? "구독의 5시간 · 주간 한도를 쓴 비율" : "쓴 토큰을 API 가격으로 셈한 값 · 구독이면 실제로 청구되지 않아요")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func claudeStatus(_ target: HookInstaller.ClaudeTarget) -> String {
        guard target.hooks else { return "연결 안 됨" }
        switch target.statusLine {
        case .installed: return "연결됨"
        case .notInstalled: return "알림만 연결됨"
        case .occupied: return "연결됨 · 상태 줄은 다른 프로그램이 써요"
        }
    }

    private var codexStatus: String {
        switch agents.hookStatus.codex {
        case .installed: "연결됨"
        case .notInstalled: "연결 안 됨"
        case .occupied(let program): "notify를 \(program)에서 써서 건드리지 않아요"
        case .unavailable: "설정 없음"
        }
    }
}

// MARK: - 계정

private struct AccountSettings: View {
    @ObservedObject var agents: AgentStore

    var body: some View {
        Form {
            ForEach(agents.usage.claude, id: \.account) { account in
                Section {
                    LabeledContent("이메일", value: account.email ?? "-")
                    LabeledContent("요금제", value: account.plan ?? "-")
                    limits(account.limits, updatedAt: account.limitsUpdatedAt)
                    LabeledContent("도는 세션", value: "\(agents.sessions.filter { $0.account == account.account && $0.state != .exited }.count)개")
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
            if let codex = agents.usage.codexAccount {
                Section("Codex") {
                    LabeledContent("로그인", value: codex.mode == "chatgpt" ? "ChatGPT 계정" : (codex.mode == "apikey" ? "API 키" : "-"))
                    LabeledContent("이메일", value: codex.email ?? "-")
                    LabeledContent("요금제", value: codex.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "-")
                    limits([agents.usage.codex?.primary, agents.usage.codex?.secondary].compactMap { $0 }, updatedAt: agents.usage.codex?.updatedAt)
                }
            }
            if agents.usage.claude.isEmpty && agents.usage.codexAccount == nil {
                Text("로그인된 에이전트 계정을 찾지 못했어요").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func limits(_ windows: [UsageWindow], updatedAt: Date?) -> some View {
        if windows.isEmpty {
            LabeledContent("한도", value: "아직 정보 없음")
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
            LabeledContent("받은 때", value: AgentsStyle.ago(updatedAt))
        }
    }
}

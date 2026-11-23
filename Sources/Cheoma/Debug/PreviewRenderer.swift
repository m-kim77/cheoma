#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// `Cheoma --render <폴더>`: 화면 기록 권한 없이 노치 UI를 PNG로 그려서 레이아웃을 확인한다 (개발용).
/// 그래프는 24시간치 가짜 기록으로 채운다.
@MainActor
enum PreviewRenderer {
    static func run(outputDirectory: String) {
        let defaults = UserDefaults.standard
        let savedTab = defaults.object(forKey: "dashboardTab")
        let savedRange = defaults.object(forKey: "graphRange")
        let savedTheme = defaults.object(forKey: "notchTheme")
        defer {
            // 렌더링하느라 바꾼 사용자 설정은 되돌린다
            defaults.set(savedTab, forKey: "dashboardTab")
            defaults.set(savedRange, forKey: "graphRange")
            defaults.set(savedTheme, forKey: "notchTheme")
        }

        let stats = StatsStore(savesHistory: false)
        stats.showsApps = true
        stats.start()
        // 대시보드가 열린 것처럼 매초 잰다. CPU/네트워크 사용률과 구성요소별 전력(2초 간격)은 두 번째 측정부터 나오므로 잠깐 기다린다
        stats.isDashboardOpen = true
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        stats.fillSampleHistory()

        let folder = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = NotchModel()
        let fans = FanController()
        let agents = AgentStore.preview()
        model.notchSize = CGSize(width: 220, height: 38)
        model.theme = .basic

        // 가장 긴 문구까지 귀 안에 들어가는지 본다
        let alerts = [NotchAlert(symbol: "bolt.fill", tint: .green, text: "충전 중 90%"),
                      WarningAlerts.thermal(.critical), WarningAlerts.memory(.critical), WarningAlerts.battery(level: 10),
                      UpdateChecker.alert(for: UpdateChecker.sampleRelease), UpdateChecker.alert(for: AppRelease(
                          tagName: "v10.10.10", body: nil, htmlURL: UpdateChecker.latestURL, draft: false, prerelease: false))]
        for (index, alert) in alerts.compactMap({ $0 }).enumerated() {
            model.previewAlert(alert)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("alert-\(index).png"))
        }
        renderDictation(model: model, stats: stats, fans: fans, agents: agents, folder: folder)

        for tab in DashboardTab.allCases {
            model.previewOpen(tab)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("tab-\(tab).png"))
        }
        // 팬 탭: 도우미가 설치된 것처럼 모드마다 그린다
        let fanPreviews: [(name: String, mode: FanController.Mode, linked: Bool)] = [
            ("automatic", .automatic, true), ("fixed", .fixed, true), ("fixed-split", .fixed, false), ("curve", .curve, true),
        ]
        for preview in fanPreviews {
            fans.preview(mode: preview.mode, temperature: 72, linked: preview.linked)
            model.previewOpen(.fans)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("fans-\(preview.name).png"))
        }
        for range in GraphRange.allCases {
            defaults.set(range.rawValue, forKey: "graphRange")
            model.previewOpen(.graphs)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("graphs-\(range).png"))
        }
        defaults.set(GraphRange.minute.rawValue, forKey: "graphRange")
        TimeGraph.previewHoverFraction = 0.62
        render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("graphs-hover.png"))
        TimeGraph.previewHoverFraction = nil

        // 광화문 테마
        model.theme = .gwanghwamun
        for tab in DashboardTab.allCases {
            model.previewOpen(tab)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("gwanghwamun-\(tab).png"))
        }
        model.theme = .basic

        // 펼친 대시보드에서 받아쓰는 중 (카메라 양옆 띠에 귀)
        let openListening = DictationIndicator(stage: .listening, level: 0.4, text: "답장: 테스트도 통과했어요", handsFree: true)
        for theme in [NotchTheme.basic, .gwanghwamun] {
            model.theme = theme
            model.previewOpen(.agents)
            model.dictation = openListening
            model.dictationLive.push(level: 0.7)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents),
                   to: folder.appendingPathComponent("dictation-open-\(theme == .basic ? "basic" : "gwanghwamun").png"))
            model.dictation = nil
        }
        model.theme = .basic

        renderAgents(model: model, stats: stats, fans: fans, agents: agents, folder: folder)
        renderSettings(model: model, agents: agents, folder: folder)
        checkOverflow(model: model, stats: stats, fans: fans, agents: agents)
        // `--live`: 이 맥의 진짜 세션 · 사용량으로 에이전트 탭을 그린다 (개인 정보가 보이니 문서 그림으로 쓰지 않는다)
        if CommandLine.arguments.contains("--live") {
            let live = AgentStore()
            live.isVisible = true
            live.start()
            // Antigravity 한도는 agy에 묻는 데 몇 초 걸린다
            RunLoop.main.run(until: Date().addingTimeInterval(10))
            AgentReplyField.drawsPlaceholderOnly = true
            model.previewOpen(.agents)
            render(NotchView(model: model, stats: stats, fans: fans, agents: live), to: folder.appendingPathComponent("agents-live.png"))
            AgentsTab.previewPane = .accounts
            render(NotchView(model: model, stats: stats, fans: fans, agents: live), to: folder.appendingPathComponent("agents-live-accounts.png"))
            AgentsTab.previewPane = .launcher
            render(NotchView(model: model, stats: stats, fans: fans, agents: live), to: folder.appendingPathComponent("agents-live-launcher.png"))
            AgentsTab.previewPane = nil
            AgentReplyField.drawsPlaceholderOnly = false
        }
    }

    /// 받아쓰기 귀의 단계마다 (들은 글이 긴 것 · 손을 떼고 듣는 것 · 붙였어요 · 못 했어요)
    private static func renderDictation(model: NotchModel, stats: StatsStore, fans: FanController, agents: AgentStore, folder: URL) {
        let samples: [(name: String, indicator: DictationIndicator, levels: [Float])] = [
            ("listening", DictationIndicator(stage: .listening, level: 0.25,
                                             text: "Swift 코드에서 async await를 써서 API 호출 부분을 리팩터링해 줘"), [0.5, 0.8]),
            ("listening-start", DictationIndicator(stage: .listening, level: 0.1), [0.2]),
            ("handsfree", DictationIndicator(stage: .listening, level: 0.4, text: "GitHub에 push하고 PR 올려 줘", handsFree: true), [0.3, 0.6]),
            ("handsfree-start", DictationIndicator(stage: .listening, level: 0.1, handsFree: true), []),
            ("transcribing", DictationIndicator(stage: .transcribing, text: "Docker 컨테이너 로그를 확인해 줘"), []),
            ("inserted", DictationIndicator(stage: .inserted("입력됨")), []),
            ("inserted-clipboard", DictationIndicator(stage: .inserted("클립보드에 복사됨")), []),
            ("failed", DictationIndicator(stage: .failed(DictationError.nothingHeard.message)), []),
            ("failed-long", DictationIndicator(stage: .failed(DictationController.shortCopiedReason("보안 입력이 켜져 있어 클립보드에만 복사했습니다"))), []),
            ("failed-headline", DictationIndicator(stage: .failed(DictationError.microphoneUnavailable("마이크 연결이 끊어졌습니다").headline)), []),
            ("failed-engine", DictationIndicator(stage: .failed(DictationError.engineUnavailable(
                "whisper 모델 파일(ggml-*.bin)을 찾을 수 없습니다. ~/models에 넣거나 설정에서 선택하십시오").headline)), []),
        ]
        // 귀가 있는 위쪽만 그린다
        let canvas = CGSize(width: model.notchSize.width + NotchModel.dictationEarWidth * 2 + 80, height: model.notchSize.height + 30)
        for sample in samples {
            model.dictation = sample.indicator
            for level in sample.levels { model.dictationLive.push(level: level) }
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents),
                   to: folder.appendingPathComponent("dictation-\(sample.name).png"), canvas: canvas)
        }
        model.dictation = nil
    }

    /// 설정 창의 탭마다. Form은 AppKit 뷰라 ImageRenderer 대신 창에 그려서 뜬다
    private static func renderSettings(model: NotchModel, agents: AgentStore, folder: URL) {
        // 업데이트 탭은 최신일 때와 새 버전이 있을 때
        let upToDate = UpdateChecker.preview(available: nil)
        let available = UpdateChecker.preview(available: UpdateChecker.sampleRelease)
        // 받아쓰기 설정은 따로 둔 곳에 저장해서 이 맥의 설정을 건드리지 않는다
        let suiteName = "io.github.m-kim77.cheoma.preview-dictation"
        let dictationDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        var sample = DictationSettings()
        sample.isEnabled = true
        sample.glossaryText = "# 우리 팀 용어\n체오마 → Cheoma\n트목스, 트웍스 → tmux\nSwiftData"
        sample.save(to: dictationDefaults)
        let dictation = previewDictation(model: model, defaults: dictationDefaults, microphone: .authorized, trusted: true)
        let variants: [(String, SettingsView.Tab, UpdateChecker)] = [
            ("general", .general, upToDate), ("agents", .agents, upToDate), ("accounts", .accounts, upToDate),
            ("dictation", .dictation, upToDate), ("updates", .updates, upToDate), ("updates-available", .updates, available),
        ]
        for (name, tab, updates) in variants {
            snapshot(SettingsView(model: model, agents: agents, updates: updates, dictation: dictation,
                                  navigation: SettingsNavigation(tab: tab)),
                     size: CGSize(width: 560, height: 520), to: folder.appendingPathComponent("settings-\(name).png"))
        }
        // 받아쓰기 탭 전체 (스크롤해야 보이는 아래쪽까지): Apple, 그리고 whisper · 권한 없음 · fn
        snapshot(DictationSettingsTab(dictation: dictation).frame(width: 560, height: 1320),
                 size: CGSize(width: 560, height: 1320), to: folder.appendingPathComponent("settings-dictation-full.png"))
        sample.engine = .whisper
        sample.hotKey = .fn
        sample.whisperModelPath = "~/models/ggml-large-v3-turbo-q5_0.bin"
        sample.save(to: dictationDefaults)
        let whisper = previewDictation(model: model, defaults: dictationDefaults, microphone: .denied, trusted: false,
                                       clipboard: .notAsked)
        snapshot(DictationSettingsTab(dictation: whisper).frame(width: 560, height: 1480),
                 size: CGSize(width: 560, height: 1480), to: folder.appendingPathComponent("settings-dictation-whisper-full.png"))
    }

    /// 마이크 · 단축키 · 붙여넣기는 쓰지 않는 받아쓰기 (설정 화면 그림용). 엔진 상태만 실제로 알아본다
    private static func previewDictation(model: NotchModel, defaults: UserDefaults, microphone: AVAuthorizationStatus,
                                         trusted: Bool, clipboard: DictationClipboardAccess = .allowed) -> DictationController {
        let dependencies = DictationController.Dependencies(
            audio: DictationAudioCapture(), makeEngine: DictationEngines.make,
            insert: { _, _, _ in .failed("미리보기") },
            microphoneStatus: { microphone }, requestMicrophone: { false }, accessibilityTrusted: { trusted },
            modifiersHeld: { _ in false }, ownPanelIsKey: { false }, clipboardAccess: { clipboard })
        let dictation = DictationController(notch: model, defaults: defaults, dependencies: dependencies)
        dictation.refreshStatus()
        // 엔진 상태(설치된 언어 모델 · whisper 파일)를 알아볼 때까지
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return dictation
    }

    /// 화면 밖 창에 띄워서 찍는다
    private static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("저장:", url.path)
    }

    /// 에이전트 탭의 여러 모습: tmux 세션(특수 키), 세션 없음, 새 에이전트 고르기, 연결 설정. 두 테마 모두
    private static func renderAgents(model: NotchModel, stats: StatsStore, fans: FanController, agents: AgentStore, folder: URL) {
        let empty = AgentStore()
        let savedSelection = agents.selectedID
        AgentReplyField.drawsPlaceholderOnly = true
        defer {
            AgentReplyField.drawsPlaceholderOnly = false
            agents.select(savedSelection)
            AgentsTab.previewPane = nil
            model.theme = .basic
        }
        for theme in NotchTheme.allCases {
            model.theme = theme
            let prefix = theme == .basic ? "agents" : "gwanghwamun-agents"
            for (name, store, pane, selection) in agentVariants(agents: agents, empty: empty) {
                AgentsTab.previewPane = pane
                if let selection { store.select(selection) }
                model.previewOpen(.agents)
                render(NotchView(model: model, stats: stats, fans: fans, agents: store),
                       to: folder.appendingPathComponent("\(prefix)-\(name).png"))
            }
        }
        model.theme = .basic
        // 터미널 미리보기 글자를 따로 키운 모습 (폭을 넘는 줄은 다음 줄로)
        let defaults = UserDefaults.standard
        let savedScreenSize = defaults.object(forKey: AgentsScreenTextSize.defaultsKey)
        for size in [14.0, 18.0] {
            defaults.set(size, forKey: AgentsScreenTextSize.defaultsKey)
            AgentsTab.previewPane = .session
            agents.select("terminal:/dev/ttys004")
            model.previewOpen(.agents)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents),
                   to: folder.appendingPathComponent("agents-screen-\(Int(size))pt.png"))
        }
        defaults.set(savedScreenSize, forKey: AgentsScreenTextSize.defaultsKey)
        // 글자 크기를 키운 모습 (탭도 기본 크기 × 배율로 커진다)
        for scale in [AgentsTextScale.larger, .largest] {
            withTextScale(scale, model: model) {
                for (name, store, pane, selection) in agentVariants(agents: agents, empty: empty)
                where ["choice", "setup", "accounts", "launcher"].contains(name) {
                    AgentsTab.previewPane = pane
                    if let selection { store.select(selection) }
                    model.previewOpen(.agents)
                    render(NotchView(model: model, stats: stats, fans: fans, agents: store),
                           to: folder.appendingPathComponent("agents-\(name)-\(Int(scale.rawValue * 100)).png"),
                           canvas: model.largestOpenSize)
                }
            }
        }
    }

    /// 글자 크기를 잠깐 바꿔서 그린다 (탭 크기와 함께 원래대로 되돌린다)
    private static func withTextScale(_ scale: AgentsTextScale, model: NotchModel, _ body: () -> Void) {
        let savedScale = model.agentsTextScale
        let savedSize = model.agentsSize
        model.agentsTextScale = .normal
        model.resizeAgents(to: DashboardTab.agents.openSize)
        model.agentsTextScale = scale
        body()
        model.agentsTextScale = savedScale
        model.resizeAgents(to: savedSize)
    }

    private static func agentVariants(agents: AgentStore, empty: AgentStore)
        -> [(name: String, store: AgentStore, pane: AgentsPane, selection: AgentSession.ID?)] {
        [("choice", agents, .session, "terminal:/dev/ttys004"),
         ("tmux", agents, .session, "tmux:%3"),
         ("input", agents, .session, "tmux:%5"),
         ("empty", empty, .session, nil),
         ("launcher", agents, .launcher, "terminal:/dev/ttys004"),
         ("launcher-no-tmux", empty, .launcher, nil),
         ("setup", agents, .setup, "terminal:/dev/ttys004"),
         ("accounts", agents, .accounts, "terminal:/dev/ttys004"),
         ("record", agents, .record("c9db0d62"), "terminal:/dev/ttys004")]
    }

    /// 탭마다 내용이 펼친 크기 안에 들어가는지 잰다. 넘치면 아래쪽이 모양에 잘려 안 보인다
    private static func checkOverflow(model: NotchModel, stats: StatsStore, fans: FanController, agents: AgentStore) {
        let savedTheme = model.theme
        defer { model.theme = savedTheme }
        for theme in NotchTheme.allCases {
            model.theme = theme
            for tab in DashboardTab.allCases {
                model.tab = tab
                let size = model.dashboardSize
                let topInset = theme == .basic ? model.notchSize.height : Gwanghwamun.dashboardTopInset
                let view = DashboardView(topInset: topInset, stats: stats, fans: fans, agents: agents, model: model,
                                         tab: .constant(tab), theme: .constant(theme))
                    .frame(width: size.width)
                    .environment(\.colorScheme, .dark)
                // 높이를 0으로 제안하면 그래프처럼 늘었다 줄었다 하는 부분은 최소 크기로 줄고, 글자는 제 크기를 지킨다
                let needed = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: size.width, height: 0)).height
                let verdict = needed > size.height + 0.5 ? "넘침" : "맞음"
                print("\(verdict) \(theme) \(tab): 내용 \(Int(needed.rounded(.up))) / 자리 \(Int(size.height))")
            }
            // 에이전트 탭은 모습마다 높이가 달라서 따로 잰다
            model.tab = .agents
            let size = model.dashboardSize
            let topInset = theme == .basic ? model.notchSize.height : Gwanghwamun.dashboardTopInset
            for variant in agentVariants(agents: agents, empty: AgentStore()) {
                AgentsTab.previewPane = variant.pane
                let saved = variant.store.selectedID
                if let selection = variant.selection { variant.store.select(selection) }
                let view = DashboardView(topInset: topInset, stats: stats, fans: fans, agents: variant.store, model: model,
                                         tab: .constant(.agents), theme: .constant(theme))
                    .frame(width: size.width)
                    .environment(\.colorScheme, .dark)
                let needed = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: size.width, height: 0)).height
                variant.store.select(saved)
                let verdict = needed > size.height + 0.5 ? "넘침" : "맞음"
                print("\(verdict) \(theme) agents-\(variant.name): 내용 \(Int(needed.rounded(.up))) / 자리 \(Int(size.height))")
            }
            AgentsTab.previewPane = nil
        }
        // 글자 크기를 키우면 탭도 커지는데, 그 크기에서도 들어가는지
        model.tab = .agents
        for scale in AgentsTextScale.allCases where scale != .normal {
            withTextScale(scale, model: model) {
                let size = model.dashboardSize
                for variant in agentVariants(agents: agents, empty: AgentStore()) {
                    AgentsTab.previewPane = variant.pane
                    let saved = variant.store.selectedID
                    if let selection = variant.selection { variant.store.select(selection) }
                    let view = DashboardView(topInset: model.notchSize.height, stats: stats, fans: fans, agents: variant.store, model: model,
                                             tab: .constant(.agents), theme: .constant(.basic))
                        .frame(width: size.width)
                        .environment(\.colorScheme, .dark)
                        .environment(\.agentsScale, scale.rawValue)
                    let needed = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: size.width, height: 0)).height
                    variant.store.select(saved)
                    let verdict = needed > size.height + 0.5 ? "넘침" : "맞음"
                    print("\(verdict) basic agents-\(variant.name) \(scale.percent): 내용 \(Int(needed.rounded(.up))) / 자리 \(Int(size.height))")
                }
                AgentsTab.previewPane = nil
            }
        }
    }

    private static func render<V: View>(_ view: V, to url: URL, canvas: CGSize = NotchModel.maxOpenSize) {
        let size = CGSize(width: canvas.width + 60, height: canvas.height + 40)
        let content = view
            .frame(width: size.width, height: size.height)
            .background(LinearGradient(colors: [Color(red: 0.22, green: 0.27, blue: 0.42), Color(red: 0.52, green: 0.38, blue: 0.48)],
                                       startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)
        // `--window`: 실제 창에 띄워서 찍는다. ImageRenderer는 ScrollView 안을 그리지 않는다
        if CommandLine.arguments.contains("--window") {
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("저장:", url.path)
            }
            window.orderOut(nil)
            return
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            print("렌더링 실패:", url.lastPathComponent)
            return
        }
        try? png.write(to: url)
        print("저장:", url.path)
    }
}
#endif

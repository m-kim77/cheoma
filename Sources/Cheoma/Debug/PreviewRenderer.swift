#if DEBUG
import AppKit
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
                      WarningAlerts.thermal(.critical), WarningAlerts.memory(.critical), WarningAlerts.battery(level: 10)]
        for (index, alert) in alerts.compactMap({ $0 }).enumerated() {
            model.previewAlert(alert)
            render(NotchView(model: model, stats: stats, fans: fans, agents: agents), to: folder.appendingPathComponent("alert-\(index).png"))
        }

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

        checkOverflow(model: model, stats: stats, fans: fans, agents: agents)
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
        }
    }

    private static func render<V: View>(_ view: V, to url: URL) {
        let size = CGSize(width: NotchModel.maxOpenSize.width + 60, height: NotchModel.maxOpenSize.height + 40)
        let content = view
            .frame(width: size.width, height: size.height)
            .background(LinearGradient(colors: [Color(red: 0.22, green: 0.27, blue: 0.42), Color(red: 0.52, green: 0.38, blue: 0.48)],
                                       startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)
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

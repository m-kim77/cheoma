import SwiftUI

enum DashboardTab: String, CaseIterable {
    case overview = "개요"
    case graphs = "그래프"
    case power = "전력"
    case thermal = "온도"
    case fans = "팬"
    case apps = "앱"
    case agents = "에이전트"

    /// 탭마다 노치가 펼쳐지는 크기 (탭을 바꾸면 스프링으로 늘었다 줄었다 한다).
    /// 내용이 다 들어가는지는 `--render`가 탭마다 재서 알려준다
    var openSize: CGSize {
        switch self {
        case .graphs: CGSize(width: 720, height: 372)
        case .overview: CGSize(width: 660, height: 254)
        case .power: CGSize(width: 660, height: 292)
        case .thermal: CGSize(width: 660, height: 300)
        case .fans: CGSize(width: 700, height: 340)
        case .apps: CGSize(width: 660, height: 318)
        case .agents: CGSize(width: 760, height: 404)
        }
    }
}

struct DashboardView: View {
    /// 맨 위 여백. 기본 모양은 노치 높이만큼 비운다
    let topInset: CGFloat
    @ObservedObject var stats: StatsStore
    let fans: FanController
    let agents: AgentStore
    let model: NotchModel
    @Binding var tab: DashboardTab
    @Binding var theme: NotchTheme

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: topInset)
            header
            switch tab {
            case .overview: OverviewTab(snapshot: stats.snapshot, history: stats.history)
            case .graphs: GraphsTab(snapshot: stats.snapshot, history: stats.history)
            case .power: PowerTab(snapshot: stats.snapshot)
            case .thermal: ThermalTab(thermal: stats.snapshot.thermal, history: stats.history)
            case .fans: FanTab(thermal: stats.snapshot.thermal, controller: fans)
            case .apps: AppsTab(apps: stats.snapshot.apps)
            case .agents: AgentsTab(store: agents, model: model)
            }
        }
        // 위 양끝의 휜 부분(NotchShape.openEave)은 비워 두고 몸통 안쪽에만 그린다
        .padding(.horizontal, NotchShape.openEave + 12)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            // 시·분만 보여 주니 분이 바뀔 때만 다시 그린다
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 시계는 한 줄로 둔다. 좁은 탭에서 "오전"과 시각이 두 줄로 갈라지면 그만큼 아래 내용이 밀려 잘린다
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    // 자리가 모자라면 날짜를 줄이고, 그래도 모자라면 뺀다
                    ViewThatFits(in: .horizontal) {
                        Text(context.date, format: .dateTime.month().day().weekday(.abbreviated))
                        Text(context.date, format: .dateTime.day().weekday(.abbreviated))
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            // 탭 이름은 줄바꿈되지 않게 (자리가 모자라면 날짜가 줄어든다)
            tabPicker
                .fixedSize()
            Spacer(minLength: 10)
            if let power = stats.snapshot.power {
                BatteryBadge(power: power)
                    .fixedSize()
                    .padding(.trailing, 8)
            }
            themeButton
        }
    }

    /// 노치 모양(기본 ↔ 광화문)을 바로 바꾼다. `⌄` 우클릭 › 노치 모양과 같다
    private var themeButton: some View {
        Button {
            let all = NotchTheme.allCases
            theme = all[((all.firstIndex(of: theme) ?? 0) + 1) % all.count]
        } label: {
            Image(systemName: theme == .basic ? "building.columns" : "building.columns.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.white.opacity(theme == .basic ? 0.07 : 0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("노치 모양: \(theme.title) (누르면 바뀜)")
        .accessibilityLabel("노치 모양 바꾸기, 지금 \(theme.title)")
    }

    private var tabPicker: some View {
        HStack(spacing: 2) {
            // 팬이 없는 맥(MacBook Air 등)에는 팬 탭을 보여주지 않는다
            ForEach(DashboardTab.allCases.filter { $0 != .fans || fans.hasFans }, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tab == item ? .white.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

private struct BatteryBadge: View {
    let power: PowerStats

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.watts(power.systemWatts))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: power.isPluggedIn ? "battery.100percent.bolt" : symbol)
                .font(.system(size: 18))
                .foregroundStyle(power.isPluggedIn ? .green : (power.batteryLevel <= 20 ? .red : .white))
            Text("\(power.batteryLevel)%")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
    }

    private var symbol: String {
        switch power.batteryLevel {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        case 11...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

private struct OverviewTab: View {
    let snapshot: StatsSnapshot
    let history: StatsHistory

    // 타일 6개뿐이라 LazyVGrid 대신 Grid를 쓴다 (LazyVGrid는 화면이 바뀔 때마다 배치를 다시 계산해서 CPU를 꽤 쓴다)
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { cpuTile; gpuTile; memoryTile }
            GridRow { powerTile; networkTile; diskTile }
        }
    }

    private var cpuTile: some View {
        StatTile(title: "CPU", value: Format.percent(snapshot.cpu),
                 detail: "\(Format.watts(snapshot.power?.components?.cpu)) · \(Format.celsius(snapshot.thermal?.cpu))",
                 accent: .blue) {
            CoreBars(cores: snapshot.cores, color: .blue)
        }
    }

    private var gpuTile: some View {
        StatTile(title: "GPU", value: Format.percent(snapshot.gpu),
                 detail: "\(Format.watts(snapshot.power?.components?.gpu)) · \(Format.celsius(snapshot.thermal?.gpu))",
                 accent: .purple) {
            TimeGraph(history: history, lines: [GraphLine(metric: .gpu, label: "GPU", color: .purple)], span: 60)
        }
    }

    private var memoryTile: some View {
        StatTile(title: "메모리", value: memoryValue, detail: memoryDetail, accent: memoryColor) {
            UsageRing(fraction: snapshot.memory?.fraction ?? 0, color: memoryColor)
        }
    }

    private var powerTile: some View {
        StatTile(title: "전력", value: Format.watts(snapshot.power?.systemWatts),
                 detail: powerDetail, accent: .yellow) {
            TimeGraph(history: history, lines: [GraphLine(metric: .systemPower, label: "전력", color: .yellow)],
                      span: 60, scale: .auto(minimum: 10))
        }
    }

    private var networkTile: some View {
        StatTile(title: "네트워크", value: "↓ \(Format.rate(snapshot.network?.inPerSecond))",
                 detail: "↑ \(Format.rate(snapshot.network?.outPerSecond))", accent: .teal) {
            TimeGraph(history: history,
                      lines: [GraphLine(metric: .networkIn, label: "↓", color: .teal, aggregate: .maximum),
                              GraphLine(metric: .networkOut, label: "↑", color: .orange, style: .line, aggregate: .maximum)],
                      span: 60, scale: .auto(minimum: 100_000))
        }
    }

    private var diskTile: some View {
        StatTile(title: "저장장치", value: diskValue, detail: diskDetail, accent: .orange) {
            UsageRing(fraction: snapshot.disk?.usedFraction ?? 0, color: .orange)
        }
    }

    private var memoryValue: String {
        guard let m = snapshot.memory else { return "—" }
        return "\(Format.memory(m.used)) / \(Int(Double(m.total) / 1_073_741_824))GB"
    }

    private var memoryDetail: String {
        guard let m = snapshot.memory else { return "" }
        return "압축 \(Format.memory(m.compressed)) · 스왑 \(Format.memory(m.swapUsed))"
    }

    private var memoryColor: Color {
        switch snapshot.memory?.pressure {
        case .critical: .red
        case .warning: .yellow
        default: .green
        }
    }

    private var powerDetail: String {
        guard let p = snapshot.power else { return "" }
        if let input = p.adapterInputWatts, input > 0 { return "어댑터 입력 \(Format.watts(input))" }
        return p.isPluggedIn ? "전원 연결됨" : "배터리 사용 중"
    }

    private var diskValue: String {
        guard let rate = snapshot.disk?.rate else { return "—" }
        return "R \(Format.rate(rate.inPerSecond))"
    }

    private var diskDetail: String {
        guard let d = snapshot.disk else { return "" }
        return "W \(Format.rate(d.rate?.outPerSecond)) · 여유 \(Format.storage(d.free))"
    }
}

private struct PowerTab: View {
    let snapshot: StatsSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("구성요소별 전력")
                let total = max(snapshot.power?.systemWatts ?? 0, 1)
                let c = snapshot.power?.components
                MetricRow(label: "시스템 전체", value: Format.watts(snapshot.power?.systemWatts), fraction: 1, color: .yellow)
                MetricRow(label: "CPU", value: Format.watts(c?.cpu), fraction: c.map { $0.cpu / total }, color: .blue)
                MetricRow(label: "GPU", value: Format.watts(c?.gpu), fraction: c.map { $0.gpu / total }, color: .purple)
                MetricRow(label: "뉴럴 엔진", value: Format.watts(c?.ane), fraction: c.map { $0.ane / total }, color: .pink)
                MetricRow(label: "메모리", value: Format.watts(c?.dram), fraction: c.map { $0.dram / total }, color: .green)
                MetricRow(label: "디스플레이", value: Format.watts(c?.display), fraction: c.map { $0.display / total }, color: .cyan)
                // 백라이트, SSD, Wi-Fi, 팬, 주변기기 등 SoC 밖에서 쓰는 전력
                let other = c.flatMap { c in snapshot.power?.systemWatts.map { max($0 - c.cpu - c.gpu - c.ane - c.dram - c.display, 0) } }
                MetricRow(label: "기타", value: Format.watts(other), fraction: other.map { $0 / total }, color: .gray)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("배터리 · 전원")
                if let p = snapshot.power {
                    MetricRow(label: "상태", value: status(p))
                    MetricRow(label: p.batteryWatts >= 0 ? "충전 전력" : "방전 전력", value: Format.watts(abs(p.batteryWatts)))
                    MetricRow(label: "어댑터", value: adapter(p))
                    MetricRow(label: "건강도", value: Format.percent(p.health), fraction: p.health, color: .green)
                    MetricRow(label: "사이클 · 온도", value: "\(p.cycleCount.map(String.init) ?? "—")회 · \(p.temperature.map { String(format: "%.1f°C", $0) } ?? "—")")
                }
                MetricRow(label: "주사율", value: snapshot.refreshRate.map { "최대 \($0)Hz" } ?? "—")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func status(_ p: PowerStats) -> String {
        if p.isCharging { return "충전 중 \(p.batteryLevel)%" }
        if p.isPluggedIn { return "전원 연결 \(p.batteryLevel)%" }
        return "\(p.batteryLevel)% · \(Format.duration(minutes: p.minutesRemaining)) 남음"
    }

    private func adapter(_ p: PowerStats) -> String {
        guard p.isPluggedIn else { return "연결 안 됨" }
        let rated = p.adapterRatedWatts.map { "\($0)W" } ?? "—"
        return "\(rated) 어댑터 · 입력 \(Format.watts(p.adapterInputWatts))"
    }
}

/// 온도와 팬 속도, CPU·GPU 온도 추이. 팬 조절은 팬 탭에서 한다.
private struct ThermalTab: View {
    let thermal: ThermalStats?
    let history: StatsHistory
    @StateObject private var clock = GraphClock()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("온도")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                row("CPU 평균", thermal?.cpu)
                row("CPU 최고", thermal?.cpuMax)
                row("GPU", thermal?.gpu)
                row("SSD", thermal?.ssd)
                row("배터리", thermal?.battery)
                if let fans = thermal?.fans {
                    ForEach(fans.indices, id: \.self) { i in
                        MetricRow(label: fans.count > 1 ? "팬 \(i + 1)" : "팬",
                                  value: fans[i].rpm < 1 ? "멈춤" : "\(Int(fans[i].rpm)) RPM",
                                  fraction: fans[i].maximum > 0 ? fans[i].rpm / fans[i].maximum : 0, color: .cyan)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("CPU · GPU 온도 · 10분")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TimeGraph(history: history,
                          lines: [GraphLine(metric: .cpuTemperature, label: "CPU", color: .orange),
                                  GraphLine(metric: .gpuTemperature, label: "GPU", color: .purple, style: .line)],
                          span: 600, scale: .fixed(100), format: { Format.celsius($0) },
                          axisFormat: { "\(Int($0))°C" }, detailed: true, clock: clock)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .task { await clock.run() }
    }

    private func row(_ label: String, _ celsius: Double?) -> some View {
        MetricRow(label: label,
                  value: celsius.map { String(format: "%.1f°C", $0) } ?? "—",
                  fraction: celsius.map { $0 / 105 },
                  color: Self.color(for: celsius))
    }

    static func color(for celsius: Double?) -> Color {
        switch celsius ?? 0 {
        case 85...: .red
        case 70...: .orange
        case 55...: .yellow
        default: .green
        }
    }
}

enum GraphRange: String, CaseIterable {
    case minute = "1분"
    case tenMinutes = "10분"
    case hour = "1시간"
    case day = "24시간"

    var seconds: TimeInterval {
        switch self {
        case .minute: 60
        case .tenMinutes: 600
        case .hour: 3600
        case .day: 86_400
        }
    }
}

/// 시간 구간을 골라 CPU · GPU · 전력 · 네트워크 추이를 보는 탭
private struct GraphsTab: View {
    let snapshot: StatsSnapshot
    let history: StatsHistory
    @AppStorage("graphRange") private var range = GraphRange.minute
    /// 그래프 네 개가 같은 순간에 같이 흐르도록 시계 하나를 나눠 쓴다
    @StateObject private var clock = GraphClock()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            rangePicker
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card("CPU", value: Format.percent(snapshot.cpu), accent: .blue,
                         summary: summary(.cpu) { Format.percent($0) }) {
                        TimeGraph(history: history, lines: [GraphLine(metric: .cpu, label: "CPU", color: .blue)],
                                  span: range.seconds, detailed: true, clock: clock)
                    }
                    card("GPU", value: Format.percent(snapshot.gpu), accent: .purple,
                         summary: summary(.gpu) { Format.percent($0) }) {
                        TimeGraph(history: history, lines: [GraphLine(metric: .gpu, label: "GPU", color: .purple)],
                                  span: range.seconds, detailed: true, clock: clock)
                    }
                }
                GridRow {
                    card("전력", value: Format.watts(snapshot.power?.systemWatts), accent: .yellow,
                         summary: summary(.systemPower) { Format.watts($0) }) {
                        TimeGraph(history: history,
                                  lines: [GraphLine(metric: .systemPower, label: "전체", color: .yellow),
                                          GraphLine(metric: .cpuPower, label: "CPU", color: .blue, style: .line),
                                          GraphLine(metric: .gpuPower, label: "GPU", color: .purple, style: .line)],
                                  span: range.seconds, scale: .auto(minimum: 10),
                                  format: { Format.watts($0) }, axisFormat: { "\(Int($0))W" }, detailed: true, clock: clock)
                    }
                    card("네트워크",
                         value: "↓\(Format.rate(snapshot.network?.inPerSecond)) ↑\(Format.rate(snapshot.network?.outPerSecond))",
                         accent: .teal, summary: peak(.networkIn) { "최대 ↓" + Format.rate($0) }) {
                        TimeGraph(history: history,
                                  lines: [GraphLine(metric: .networkIn, label: "↓", color: .teal, aggregate: .maximum),
                                          GraphLine(metric: .networkOut, label: "↑", color: .orange, style: .line, aggregate: .maximum)],
                                  span: range.seconds, scale: .auto(minimum: 100_000),
                                  format: { Format.rate($0) }, detailed: true, clock: clock)
                    }
                }
            }
        }
        .task { await clock.run() }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(GraphRange.allCases, id: \.self) { item in
                Button { range = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(range == item ? .white.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: Capsule())
    }

    /// 선택한 구간의 평균 · 최대
    private func summary(_ metric: Metric, _ format: (Double) -> String) -> String {
        guard let s = history[metric].summary(since: Date().timeIntervalSinceReferenceDate - range.seconds) else { return "" }
        return "평균 \(format(s.average)) · 최대 \(format(s.maximum))"
    }

    private func peak(_ metric: Metric, _ format: (Double) -> String) -> String {
        history[metric].summary(since: Date().timeIntervalSinceReferenceDate - range.seconds).map { format($0.maximum) } ?? ""
    }

    private func card(_ title: String, value: String, accent: Color, summary: String,
                      @ViewBuilder graph: () -> TimeGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            graph()
                .frame(height: 76)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

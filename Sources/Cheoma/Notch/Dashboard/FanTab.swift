import SwiftUI

/// 팬 탭: 왼쪽은 팬마다 지금 속도와 목표, 오른쪽은 조절 (자동 · 고정 · 온도별).
/// 노치 패널은 키보드 입력을 받지 않으므로 숫자는 슬라이더와 그래프를 끌어서 바꾼다.
struct FanTab: View {
    let thermal: ThermalStats?
    @ObservedObject var controller: FanController

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            status
                .padding(12)
                .frame(width: 196)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            controls
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("팬")
            let fans = thermal?.fans ?? []
            if fans.isEmpty {
                Text(controller.hasFans ? "팬 정보 읽는 중" : "팬 없음")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fans.indices, id: \.self) { i in
                    FanGauge(name: fans.count > 1 ? "팬 \(i + 1)" : "팬", fan: fans[i], target: target(for: i))
                }
            }
            Spacer(minLength: 0)
            if let temperature = controller.ruleTemperature {
                Text("CPU·GPU \(Int(temperature.rounded()))°C" as String)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// 도우미에 걸어 둔 이 팬의 목표 (nil이면 자동)
    private func target(for index: Int) -> Double? {
        guard let applied = controller.appliedRPMs, !applied.isEmpty else { return nil }
        return applied[min(index, applied.count - 1)]
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionTitle("조절")
                Spacer(minLength: 0)
                if controller.hasFans, controller.helperState == .installed { modePicker }
            }
            content
            if let message = controller.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !controller.hasFans {
            Text("이 맥은 팬이 없어서 조절할 수 없어요 (팬 없이 식히는 모델)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            switch controller.helperState {
            case .installed:
                switch controller.mode {
                case .automatic:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("macOS가 온도에 맞춰 조절해요. 시원할 때는 팬이 멈춰 있어요.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            Button("도우미 제거") { controller.uninstallHelper() }
                                .buttonStyle(.plain)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                case .fixed:
                    FixedControls(controller: controller)
                case .curve:
                    CurveEditor(controller: controller)
                }
            case .notInstalled:
                installPrompt("팬 속도를 바꾸려면 관리자 권한 도우미가 필요해요", button: "도우미 설치")
            case .needsReinstall(let reason):
                installPrompt(reason, button: "다시 설치")
            case .working:
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(FanController.Mode.allCases) { mode in
                Button { controller.setMode(mode) } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(controller.mode == mode ? .white.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private func installPrompt(_ text: String, button: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button) { controller.installHelper() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// 팬 하나: 지금 RPM을 크게 보여주고, 막대 위에 목표 위치를 흰 눈금으로 표시한다
private struct FanGauge: View {
    let name: String
    let fan: ThermalStats.Fan
    let target: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(fan.rpm < 1 ? "멈춤" : String(Int(fan.rpm)))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if fan.rpm >= 1 {
                    Text("RPM")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(Color.cyan)
                        .frame(width: max(geo.size.width * fraction(fan.rpm), 3))
                    if let target {
                        Capsule().fill(.white)
                            .frame(width: 2, height: 11)
                            .offset(x: geo.size.width * fraction(target) - 1)
                    }
                }
            }
            .frame(height: 6)
            Text(targetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 0 RPM(멈춤)부터 이 팬의 최대까지
    private func fraction(_ rpm: Double) -> Double {
        fan.maximum > 0 ? min(max(rpm / fan.maximum, 0), 1) : 0
    }

    private var targetText: String {
        guard let target else { return "자동 · 최대 \(Int(fan.maximum)) RPM" }
        if target <= 0 { return "목표 멈춤" }
        return "목표 \(Int(min(max(target, fan.minimum), fan.maximum))) RPM"
    }
}

/// 고정: 슬라이더로 팬마다(또는 좌우 같이) RPM을 정한다. 끄는 동안에도 팬이 따라온다.
private struct FixedControls: View {
    @ObservedObject var controller: FanController
    /// 끄는 중인 슬라이더 값 (키: 팬 번호, 좌우를 묶었으면 -1)
    @State private var drafts: [Int: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isLinked || controller.fanLimits.count < 2 {
                sliderRow(label: controller.fanLimits.count < 2 ? "팬" : "모든 팬", fan: nil)
            } else {
                ForEach(controller.fanLimits.indices, id: \.self) { i in
                    sliderRow(label: "팬 \(i + 1)", fan: i)
                }
            }
            HStack(spacing: 6) {
                if controller.fanLimits.count > 1 {
                    pill("좌우 같이", symbol: "link", isOn: controller.isLinked) { controller.setLinked(!controller.isLinked) }
                }
                pill("멈춤", symbol: "stop.fill", isOn: controller.isStopped) { controller.stopFans() }
                Spacer(minLength: 0)
            }
            savedRow
            Spacer(minLength: 0)
            Text(rangeCaption)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private func sliderRow(label: String, fan: Int?) -> some View {
        let range = fan.map { controller.fanLimits[$0] } ?? controller.rpmRange ?? 0...1
        let key = fan ?? -1
        let stored = controller.fixedRPMs[min(fan ?? 0, controller.fixedRPMs.count - 1)]
        let value = drafts[key] ?? max(stored, range.lowerBound)
        let stopped = drafts[key] == nil && controller.isStopped
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            RPMSlider(value: Binding(get: { value }, set: {
                drafts[key] = $0
                controller.setFixedRPM($0, fan: fan, commit: false)
            }), range: range) {
                controller.setFixedRPM($0, fan: fan)
                drafts[key] = nil
            }
            .opacity(stopped ? 0.4 : 1)
            Text(stopped ? "멈춤" : "\(Int(min(max(FanController.rounded(value), range.lowerBound), range.upperBound))) RPM" as String)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
        }
    }

    /// 저장해 둔 속도: 누르면 적용, ×로 지운다
    private var savedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            ForEach(controller.savedSpeeds, id: \.self) { speed in
                let isCurrent = controller.mode == .fixed && speed == controller.fixedRPMs
                HStack(spacing: 0) {
                    Button { controller.applySavedSpeed(speed) } label: {
                        Text(Self.label(speed))
                            .font(.system(size: 10.5, weight: .semibold))
                            .monospacedDigit()
                            .padding(.leading, 9)
                            .padding(.trailing, 4)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { controller.removeSavedSpeed(speed) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(isCurrent ? Color.cyan.opacity(0.3) : .white.opacity(0.08), in: Capsule())
            }
            if controller.savedSpeeds.count < FanController.maximumSavedSpeeds,
               !controller.savedSpeeds.contains(controller.fixedRPMs) {
                pill("지금 속도 저장", symbol: "plus", isOn: false) { controller.saveCurrentSpeed() }
            }
            Spacer(minLength: 0)
        }
    }

    private var rangeCaption: String {
        let limits = controller.fanLimits
        guard limits.count > 1 else {
            return limits.first.map { "\(Int($0.lowerBound))~\(Int($0.upperBound)) RPM" } ?? ""
        }
        return limits.indices.map { "팬 \($0 + 1) \(Int(limits[$0].lowerBound))~\(Int(limits[$0].upperBound))" }
            .joined(separator: " · ") + " RPM"
    }

    /// 2000 (좌우 같음) 또는 2000·2600 (팬마다 다름)
    private static func label(_ speed: [Double]) -> String {
        let names = speed.map { $0 <= 0 ? "멈춤" : "\(Int($0))" }
        return Set(names).count == 1 ? names[0] : names.joined(separator: "·")
    }

    private func pill(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isOn ? Color.cyan.opacity(0.3) : .white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 온도별: 30~100°C 여덟 점의 RPM을 위아래로 끌어서 정한다. 커브는 뜨거운 쪽으로 갈수록 내려가지 않는다:
/// 점을 올리면 오른쪽 점들이 같이 올라가고, 내리면 왼쪽 점들이 같이 내려간다.
/// 아래 회색 띠(팬 최소보다 낮은 곳)에 둔 구간은 macOS가 알아서 조절한다.
private struct CurveEditor: View {
    @ObservedObject var controller: FanController
    @State private var draft: [Double]?
    @State private var dragIndex: Int?
    /// 끌기 시작할 때의 커브. 밀려난 점들은 이 값을 기준으로 계산해서, 다시 내리면 제자리로 돌아온다
    @State private var dragStart: [Double]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let range = controller.rpmRange {
                GeometryReader { geo in
                    CurveGraph(values: draft ?? controller.curve, style: controller.curveStyle,
                               minimum: range.lowerBound, maximum: range.upperBound,
                               temperature: controller.ruleTemperature, activeIndex: dragIndex)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let plot = CurveGraph.plotRect(in: geo.size)
                                let start = dragStart ?? controller.curve
                                let index = dragIndex ?? CurveGraph.nearestIndex(toX: drag.startLocation.x, in: plot)
                                let value = controller.curvePoint(
                                    CurveGraph.rpm(atY: drag.location.y, in: plot, maximum: range.upperBound))
                                dragStart = start
                                dragIndex = index
                                draft = FanController.editing(start, index: index, to: value)
                            }
                            .onEnded { _ in
                                if let draft { controller.setCurve(draft) }
                                draft = nil
                                dragIndex = nil
                                dragStart = nil
                            })
                }
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(FanController.CurveStyle.allCases) { style in
                        Button { controller.setCurveStyle(style) } label: {
                            Text(style.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(controller.curveStyle == style ? .white.opacity(0.18) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.white.opacity(0.07), in: Capsule())
                Button("기본값") { controller.resetCurve() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var status: String {
        guard let temperature = controller.ruleTemperature else { return "온도 읽는 중" }
        let speed = controller.appliedRPMs?.max().map { "\(Int($0)) RPM" } ?? "자동"
        return "CPU·GPU \(Int(temperature.rounded()))°C → \(speed)"
    }
}

/// 온도(가로) - RPM(세로) 커브 그래프. 주황 점선은 지금 온도.
private struct CurveGraph: View {
    let values: [Double]
    let style: FanController.CurveStyle
    let minimum: Double
    let maximum: Double
    let temperature: Double?
    let activeIndex: Int?

    private static let labelColor = Color.white.opacity(0.42)
    private static let gridColor = Color.white.opacity(0.08)

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 34, y: 14, width: max(size.width - 40, 1), height: max(size.height - 30, 1))
    }

    static func nearestIndex(toX x: CGFloat, in plot: CGRect) -> Int {
        let last = FanController.curveTemperatures.count - 1
        return min(max(Int(((x - plot.minX) / plot.width * CGFloat(last)).rounded()), 0), last)
    }

    static func rpm(atY y: CGFloat, in plot: CGRect, maximum: Double) -> Double {
        Double(min(max((plot.maxY - y) / plot.height, 0), 1)) * maximum
    }

    private static func x(index: Int, in plot: CGRect) -> CGFloat {
        plot.minX + plot.width * CGFloat(index) / CGFloat(FanController.curveTemperatures.count - 1)
    }

    private static func x(temperature: Double, in plot: CGRect) -> CGFloat {
        let temperatures = FanController.curveTemperatures
        let fraction = (temperature - temperatures[0]) / (temperatures[temperatures.count - 1] - temperatures[0])
        return plot.minX + plot.width * CGFloat(min(max(fraction, 0), 1))
    }

    private func y(_ rpm: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(min(max(rpm / maximum, 0), 1))
    }

    var body: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            let label = { (text: String) in Text(text).font(.system(size: 8.5)).foregroundStyle(Self.labelColor) }
            let line = { (from: CGPoint, to: CGPoint) -> Path in
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                return path
            }

            // 팬 최소보다 낮은 띠: 이 높이에 둔 구간은 자동
            let bandTop = y(minimum, in: plot)
            context.fill(Path(CGRect(x: plot.minX, y: bandTop, width: plot.width, height: plot.maxY - bandTop)),
                         with: .color(.white.opacity(0.06)))
            context.draw(label("자동"), at: CGPoint(x: plot.minX - 5, y: (bandTop + plot.maxY) / 2), anchor: .trailing)
            for rpm in [2000, 4000, maximum] where rpm > minimum + 300 && rpm <= maximum {
                let yy = y(rpm, in: plot)
                context.stroke(line(CGPoint(x: plot.minX, y: yy), CGPoint(x: plot.maxX, y: yy)), with: .color(Self.gridColor), lineWidth: 0.5)
                context.draw(label("\(Int(rpm))"), at: CGPoint(x: plot.minX - 5, y: yy), anchor: .trailing)
            }
            for (index, temperature) in FanController.curveTemperatures.enumerated() {
                let xx = Self.x(index: index, in: plot)
                context.stroke(line(CGPoint(x: xx, y: plot.minY), CGPoint(x: xx, y: plot.maxY)), with: .color(Self.gridColor.opacity(0.6)), lineWidth: 0.5)
                context.draw(label("\(Int(temperature))°"), at: CGPoint(x: xx, y: plot.maxY + 3), anchor: .top)
            }

            // 커브와 그 아래 면
            let points = values.indices.map { CGPoint(x: Self.x(index: $0, in: plot), y: y(values[$0], in: plot)) }
            guard let first = points.first, let last = points.last else { return }
            var curve = Path()
            curve.move(to: first)
            for index in points.indices.dropFirst() {
                if style == .step { curve.addLine(to: CGPoint(x: points[index].x, y: points[index - 1].y)) }
                curve.addLine(to: points[index])
            }
            var area = curve
            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [.cyan.opacity(0.28), .cyan.opacity(0.03)]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            context.stroke(curve, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // 지금 온도와 그 온도의 커브 값
            if let temperature {
                let xx = Self.x(temperature: temperature, in: plot)
                context.stroke(line(CGPoint(x: xx, y: plot.minY), CGPoint(x: xx, y: plot.maxY)),
                               with: .color(.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let rpm = FanController.curveRPM(at: temperature, values: values, style: style)
                let yy = y(rpm, in: plot)
                context.fill(Path(ellipseIn: CGRect(x: xx - 3.5, y: yy - 3.5, width: 7, height: 7)), with: .color(.orange))
            }

            // 점 (자동 띠에 있는 점은 회색)
            for (index, point) in points.enumerated() {
                let radius: CGFloat = index == activeIndex ? 6 : 4.5
                let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(values[index] >= minimum ? .white : Color(white: 0.45)))
                context.stroke(dot, with: .color(.cyan), lineWidth: 1.5)
            }
            // 끌고 있는 점의 값
            if let activeIndex, points.indices.contains(activeIndex) {
                let value = values[activeIndex]
                context.draw(Text(value >= minimum ? "\(Int(value)) RPM" : "자동")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white),
                             at: CGPoint(x: points[activeIndex].x, y: points[activeIndex].y - 9), anchor: .bottom)
            }
        }
    }
}

/// 노치 패널용 슬라이더. 시스템 슬라이더는 어두운 노치에서 모양이 튀고 PNG 미리보기에도 그려지지 않아서 직접 그린다.
/// 끄는 동안은 value만 바꾸고, 손을 떼면 onCommit으로 알린다.
private struct RPMSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void

    private static let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let x = (geo.size.width - Self.knob) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                Capsule().fill(Color.cyan).frame(width: x + Self.knob / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value = rpm(at: $0.location.x, width: geo.size.width) }
                .onEnded { onCommit(rpm(at: $0.location.x, width: geo.size.width)) })
        }
        .frame(height: 18)
    }

    private func rpm(at x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max((x - Self.knob / 2) / max(width - Self.knob, 1), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }
}

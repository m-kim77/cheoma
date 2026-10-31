import SwiftUI

struct GraphLine {
    enum Style { case area, line }
    /// 한 픽셀에 여러 샘플이 들어갈 때 대표값 (네트워크처럼 순간 튀는 값은 최대값이 낫다)
    enum Aggregate { case average, maximum }

    let metric: Metric
    let label: String
    let color: Color
    var style: Style = .area
    var aggregate: Aggregate = .average
}

enum GraphScale {
    case fixed(Double)
    /// 보이는 구간의 최대값에 맞춰 1·2·5 단위로 올림. 값이 작아도 minimum 아래로는 줄이지 않는다.
    case auto(minimum: Double)

    func upperBound(for maximum: Double) -> Double {
        switch self {
        case .fixed(let value):
            return value
        case .auto(let minimum):
            let target = max(maximum * 1.1, minimum)
            let magnitude = pow(10, floor(log10(target)))
            // 1·2·5만 쓰면 59W → 100W처럼 그래프가 절반만 차므로 더 촘촘한 단위로 올림
            let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
            let nice = steps.first { target / magnitude <= $0 } ?? 10
            return nice * magnitude
        }
    }
}

/// 시간이 흐르면서 오른쪽에서 왼쪽으로 부드럽게 흘러가는 그래프.
/// detailed면 시계 기준 시간 눈금(그래프와 함께 흘러감), 최대값 눈금, 마우스를 올린 시점의 값을 보여준다.
struct TimeGraph: View {
    let history: StatsHistory
    let lines: [GraphLine]
    let span: TimeInterval
    var scale: GraphScale = .fixed(1)
    var format: (Double) -> String = { Format.percent($0) }
    /// 세로축 최대값 라벨 (없으면 format)
    var axisFormat: ((Double) -> String)?
    var detailed = false
    /// 있으면 이 시계가 갈 때마다 다시 그려서 흐르듯 보인다. 없으면 새 값이 들어올 때만 다시 그린다
    var clock: GraphClock?

    @State private var hoverX: CGFloat?

    #if DEBUG
    /// 미리보기 렌더링에서 마우스 위치를 흉내 낼 때만 쓴다 (그래프 폭 대비 비율)
    static var previewHoverFraction: CGFloat?
    #endif

    /// 최신 샘플이 오른쪽 끝까지 항상 채워져 있도록 샘플 간격(1초)만큼 늦게 그린다
    private static let lag: TimeInterval = 1
    private static let timeAxisHeight: CGFloat = 13
    private static let labelColor = Color.white.opacity(0.42)
    private static let gridColor = Color.white.opacity(0.08)

    var body: some View {
        GeometryReader { geo in
            if let clock {
                // 큰 그래프는 한 포인트 움직일 때마다 다시 그려서 흐르듯 보이게 한다 (긴 구간일수록 덜 자주).
                // TimelineView는 쓰지 않는다: .animation은 화면 주사율마다 깨어나고, .periodic은 간격이 0.3초쯤보다
                // 짧으면 창 배치를 쉬지 않고 되풀이해서 1분 구간 그래프 탭이 CPU를 110% 썼다 (macOS 26)
                let interval = span / Double(max(geo.size.width, 1))
                ClockReader(clock: clock) { canvas(now: $0) }
                    .onAppear { clock.interval = interval }
                    .onChange(of: interval) { _, new in clock.interval = new }
            } else {
                // 작은 그래프(60초를 64pt)는 1초에 1pt 움직이므로 새 값이 들어올 때(1초) 다시 그리는 것으로 충분하다.
                // 따로 타이머를 두면 깨어날 때마다 대시보드 전체 배치를 다시 계산해서 CPU를 꽤 쓴다 (개요 탭 9% → 2%)
                canvas(now: Date())
            }
        }
        .onContinuousHover { phase in
            guard detailed else { return }
            switch phase {
            case .active(let point): hoverX = point.x
            case .ended: hoverX = nil
            }
        }
    }

    // MARK: - 그리기

    private func canvas(now: Date) -> some View {
        Canvas { ctx, size in
            draw(in: ctx, size: size, now: now.timeIntervalSinceReferenceDate)
        }
    }

    /// 그린 횟수 (--bench에서 초당 몇 번 그리는지 본다)
    static var drawCount = 0

    private func draw(in ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        Self.drawCount += 1
        let plot = CGRect(x: 0, y: 0, width: size.width,
                          height: size.height - (detailed ? Self.timeAxisHeight : 0))
        guard plot.width > 1, plot.height > 1 else { return }
        let end = now - Self.lag
        let start = end - span

        // 이 간격보다 멀리 떨어진 점들은 잇지 않는다 (앱이 꺼져 있던 시간 등)
        let gapLimit = max(5, 3 * span / Double(max(Int(plot.width), 1)))
        let reduced = lines.map { line in
            reduce(history[line.metric].points(since: start), start: start, end: end,
                   columns: Int(plot.width), aggregate: line.aggregate, gapLimit: gapLimit)
        }
        let visibleMax = reduced.joined().filter { $0.time >= start }.map(\.value).max() ?? 0
        let upper = scale.upperBound(for: visibleMax)

        func position(_ point: TimeSeries.Point) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((point.time - start) / span) * plot.width,
                    y: plot.maxY - CGFloat(min(max(point.value / upper, 0), 1)) * plot.height)
        }

        if detailed { drawGrid(in: ctx, plot: plot, start: start, end: end, upper: upper) }

        ctx.drawLayer { layer in
            layer.clip(to: Path(plot))
            for (line, points) in zip(lines, reduced) {
                var stroke = Path()
                var fill = Path()
                for segment in Self.segments(points, gapLimit: gapLimit) where segment.count > 1 {
                    let positions = segment.map(position)
                    stroke.addLines(positions)
                    if line.style == .area, let first = positions.first, let last = positions.last {
                        fill.addLines(positions)
                        fill.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                        fill.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                        fill.closeSubpath()
                    }
                }
                if line.style == .area {
                    layer.fill(fill, with: .linearGradient(
                        Gradient(colors: [line.color.opacity(0.38), line.color.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                }
                layer.stroke(stroke, with: .color(line.color),
                             style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }

        var hover = hoverX
        #if DEBUG
        if hover == nil, let fraction = Self.previewHoverFraction { hover = plot.minX + plot.width * fraction }
        #endif
        if detailed, let hover, hover >= plot.minX, hover <= plot.maxX {
            drawHover(in: ctx, plot: plot, x: hover, start: start, reduced: reduced, position: position)
        }
    }

    private func drawGrid(in ctx: GraphicsContext, plot: CGRect, start: TimeInterval, end: TimeInterval, upper: Double) {
        for fraction in [0.5, 1.0] {
            let y = plot.maxY - plot.height * fraction
            ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                       with: .color(Self.gridColor), lineWidth: 0.5)
        }
        ctx.draw(Text((axisFormat ?? format)(upper)).font(.system(size: 8.5)).foregroundStyle(Self.labelColor),
                 at: CGPoint(x: plot.minX + 2, y: plot.minY + 1), anchor: .topLeading)

        // 시계 기준 눈금: 현지 시각으로 15초/2분/15분/6시간 단위에 맞춰서 그래프와 같이 흘러간다
        let step = Self.tickStep(for: span)
        let offset = TimeInterval(TimeZone.current.secondsFromGMT())
        var tick = ((start + offset) / step).rounded(.up) * step - offset
        while tick <= end {
            let x = plot.minX + CGFloat((tick - start) / span) * plot.width
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                       with: .color(Self.gridColor), lineWidth: 0.5)
            let label = ctx.resolve(Text(Self.tickLabel(Date(timeIntervalSinceReferenceDate: tick), step: step))
                .font(.system(size: 8.5)).monospacedDigit().foregroundStyle(Self.labelColor))
            // 카드 밖으로 삐져나오는 가장자리 라벨은 생략 (눈금선은 그대로)
            let halfWidth = label.measure(in: plot.size).width / 2
            if x - halfWidth >= plot.minX, x + halfWidth <= plot.maxX {
                ctx.draw(label, at: CGPoint(x: x, y: plot.maxY + 2), anchor: .top)
            }
            tick += step
        }
    }

    private func drawHover(in ctx: GraphicsContext, plot: CGRect, x: CGFloat, start: TimeInterval,
                           reduced: [[TimeSeries.Point]], position: (TimeSeries.Point) -> CGPoint) {
        let time = start + Double((x - plot.minX) / plot.width) * span
        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                   with: .color(.white.opacity(0.35)), lineWidth: 1)

        var parts = [Self.hoverFormatter.string(from: Date(timeIntervalSinceReferenceDate: time))]
        for (line, points) in zip(lines, reduced) {
            guard let nearest = points.min(by: { abs($0.time - time) < abs($1.time - time) }) else { continue }
            let dot = position(nearest)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(line.color))
            parts.append("\(line.label) \(format(nearest.value))")
        }

        let text = ctx.resolve(Text(parts.joined(separator: "  "))
            .font(.system(size: 9.5, weight: .medium)).monospacedDigit().foregroundStyle(.white))
        let size = text.measure(in: plot.size)
        let box = CGRect(x: min(max(x - size.width / 2 - 5, plot.minX), plot.maxX - size.width - 10),
                         y: plot.minY + 1, width: size.width + 10, height: size.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.black.opacity(0.8)))
        ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY))
    }

    // MARK: - 데이터

    /// 한 픽셀에 샘플이 여러 개 몰리면 픽셀당 하나로 줄인다 (1시간 = 3600개 → 그래프 폭만큼)
    private func reduce(_ points: [TimeSeries.Point], start: TimeInterval, end: TimeInterval,
                        columns: Int, aggregate: GraphLine.Aggregate, gapLimit: TimeInterval) -> [TimeSeries.Point] {
        var points = points
        // 다음 샘플이 오기 전까지는 마지막 값을 오른쪽 끝까지 이어서 그린다 (기록이 끊긴 지 오래면 그대로 둔다)
        if let last = points.last, last.time < end, end - last.time < gapLimit {
            points.append(TimeSeries.Point(time: end, value: last.value))
        }
        guard columns > 0, points.count > columns * 2 else {
            return aggregate == .maximum ? points.map { TimeSeries.Point(time: $0.time, value: $0.peak) } : points
        }

        let width = (end - start) / Double(columns)
        var result: [TimeSeries.Point] = []
        result.reserveCapacity(columns + 2)
        var column = Int.min
        var sum = 0.0
        var count = 0
        var peak = -Double.infinity
        func flush() {
            guard count > 0 else { return }
            let value = aggregate == .maximum ? peak : sum / Double(count)
            result.append(TimeSeries.Point(time: start + (Double(column) + 0.5) * width, value: value))
        }
        for point in points {
            let index = Int(((point.time - start) / width).rounded(.down))
            if index != column {
                flush()
                column = index
                sum = 0
                count = 0
                peak = -.infinity
            }
            sum += point.value
            count += 1
            peak = max(peak, point.peak)
        }
        flush()
        return result
    }

    /// 시간 간격이 gapLimit보다 크게 벌어진 곳에서 끊어 여러 조각으로 나눈다
    private static func segments(_ points: [TimeSeries.Point], gapLimit: TimeInterval) -> [ArraySlice<TimeSeries.Point>] {
        guard !points.isEmpty else { return [] }
        var result: [ArraySlice<TimeSeries.Point>] = []
        var segmentStart = points.startIndex
        for index in points.indices.dropFirst() where points[index].time - points[index - 1].time > gapLimit {
            result.append(points[segmentStart..<index])
            segmentStart = index
        }
        result.append(points[segmentStart...])
        return result
    }

    private static func tickStep(for span: TimeInterval) -> TimeInterval {
        switch span {
        case ...60: 15
        case ...600: 120
        case ...3600: 15 * 60
        default: 6 * 3600
        }
    }

    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let minutesFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let hoverFormatter = secondsFormatter

    private static func tickLabel(_ date: Date, step: TimeInterval) -> String {
        (step < 60 ? secondsFormatter : minutesFormatter).string(from: date)
    }
}

/// 흐르는 그래프들이 같이 쓰는 시계. 한 화면의 그래프가 모두 같은 순간에 다시 그려져서
/// 창 배치가 그래프 수만큼이 아니라 한 번만 일어난다. 보이는 동안 `run()`을 `.task`로 돌린다
@MainActor
final class GraphClock: ObservableObject {
    @Published private(set) var now = Date()
    /// 그래프가 1pt 움직이는 시간. 그래프가 자기 폭으로 계산해서 알려 준다.
    /// 구간을 바꾸면(24시간 → 1분) 바로 지금 시각으로 다시 그린다
    var interval: TimeInterval = 1 {
        didSet { if interval != oldValue { now = Date() } }
    }

    /// 초당 30번보다 자주는 그리지 않는다
    private static let minimumInterval: TimeInterval = 1.0 / 30
    /// 긴 간격(24시간 구간은 약 5분)도 한 번에 다 자지 않고 이만큼씩 깨어 간격이 바뀌었는지 본다
    private static let longestSleep: TimeInterval = 1

    func run() async {
        now = Date()
        while !Task.isCancelled {
            let due = now.addingTimeInterval(max(interval, Self.minimumInterval))
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(min(wait, Self.longestSleep)))
            } else {
                now = Date()
            }
        }
    }
}

/// 시계가 갈 때 이 뷰만 다시 그린다 (부모 뷰는 다시 계산하지 않는다)
private struct ClockReader<Content: View>: View {
    @ObservedObject var clock: GraphClock
    @ViewBuilder let content: (Date) -> Content

    var body: some View { content(clock.now) }
}

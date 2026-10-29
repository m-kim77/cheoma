import SwiftUI

/// 광화문 테마의 크기 계산. 광화문 사진에서 잰 비례를 쓴다:
/// 아래층 지붕 끝에서 끝까지 840, 석축 폭 690, 지붕 부분 높이 177 (세로는 사진의 0.55배로 낮췄다).
/// 대시보드 폭에 맞춰 전체를 같은 비율로 키우거나 줄인다.
enum Gwanghwamun {
    static let designWidth: CGFloat = 840
    static let baseHalf: CGFloat = 345
    static let roofHeight: CGFloat = 177
    /// 석축 아래 홍예문이 차지하는 높이
    static let archBand: CGFloat = 58
    /// 석축 가장자리와 대시보드 사이 여백
    static let margin: CGFloat = 10
    /// 대시보드 맨 위 여백 (기본 모양은 노치 높이만큼 비우지만, 여기서는 지붕이 노치를 덮는다)
    static let dashboardTopInset: CGFloat = 6

    static func scale(contentWidth: CGFloat) -> CGFloat {
        (contentWidth + margin * 2) / (baseHalf * 2)
    }

    static func frameSize(content: CGSize) -> CGSize {
        let k = scale(contentWidth: content.width)
        return CGSize(width: designWidth * k, height: roofHeight * k + margin + content.height + archBand * k)
    }

    /// 모양 맨 위에서 대시보드 맨 위까지
    static func contentTop(content: CGSize) -> CGFloat {
        roofHeight * scale(contentWidth: content.width) + margin
    }
}

/// 광화문 실루엣의 도형들. 설계 좌표(가운데 x = 0, 위 y = 0)로 계산해서 rect에 맞춰 옮긴다.
struct GwanghwamunGeometry {
    private(set) var body = Path()
    private(set) var whites = Path()
    private(set) var courses = Path()
    private(set) var rims = Path()
    private(set) var dots = Path()
    private(set) var archRims = Path()

    private struct Tier {
        var ridgeHalf, topY, hipEnd, steep, flatY, endY, cutY, tipHalf, tipY, mid, soffitHalf, soffitY, jFrom, jTo, jSize: CGFloat
    }

    // 사진 위에 겹쳐 보며 맞춘 값
    private static let upper = Tier(ridgeHalf: 199, topY: 9, hipEnd: 379, steep: 0.36, flatY: 16, endY: 20, cutY: 24, tipHalf: 390, tipY: 26,
                                    mid: 64, soffitHalf: 300, soffitY: 74, jFrom: 282, jTo: 352, jSize: 7)
    private static let lower = Tier(ridgeHalf: 273, topY: 99, hipEnd: 408, steep: 0.12, flatY: 99, endY: 97, cutY: 104, tipHalf: 420, tipY: 107,
                                    mid: 136, soffitHalf: 330, soffitY: 147, jFrom: 290, jTo: 396, jSize: 7.5)

    init(rect: CGRect) {
        let k = rect.width / Gwanghwamun.designWidth
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.midX + x * k, y: rect.minY + y * k) }

        for tier in [Self.upper, Self.lower] { addTier(tier, point: point) }

        // 용마루: 가운데가 아주 살짝 처지고, 양끝에 큰 취두
        let ridgeTop = stride(from: -199.0, through: 199, by: 5).map { x in point(x, 3 + 1.5 * (1 - pow(x / 199, 2))) }
        let ridgeBottom = stride(from: 199.0, through: -199, by: -5).map { x in point(x, 11 + 1.5 * (1 - pow(x / 199, 2))) }
        addPolygon(ridgeTop + ridgeBottom)
        whites.addLines(ridgeTop)
        for s: CGFloat in [-1, 1] {
            addPolygon([(192, 12), (192, 2), (196, 0), (208, 0), (211, 4), (207, 8), (205, 12)].map { point(s * $0.0, $0.1) })
        }

        // 층마다 공포대와 벽 (지붕 아래로 숨는 부분까지 이어 그려서 틈이 생기지 않게 한다)
        for (half, top, bottom) in [(300.0, 46.0, 75.0), (274, 74, 110), (330, 116, 147), (321, 146, 179)] {
            addPolygon([point(-half, top), point(half, top), point(half, bottom), point(-half, bottom)])
        }

        // 석축: 대시보드가 들어가는 곳. 아래에 홍예문 세 개 (가운데가 조금 크다)
        let baseTop = rect.minY + Gwanghwamun.roofHeight * k
        let baseHalf = Gwanghwamun.baseHalf * k
        let arches = [(-207.0, 40.0), (0, 46), (207, 40)].map { center, radius in
            arch(centerX: rect.midX + center * k, radius: radius * k, side: 6 * k, bottom: rect.maxY)
        }
        var base = [CGPoint(x: rect.midX - baseHalf, y: baseTop), CGPoint(x: rect.midX + baseHalf, y: baseTop),
                    CGPoint(x: rect.midX + baseHalf, y: rect.maxY)]
        for points in arches.reversed() { base += points.reversed() }
        base.append(CGPoint(x: rect.midX - baseHalf, y: rect.maxY))
        addPolygon(base)
        for points in arches { archRims.addLines(Array(points.dropFirst().dropLast())) }
    }

    private mutating func addTier(_ o: Tier, point: (CGFloat, CGFloat) -> CGPoint) {
        // 처마선: 가운데부터 은근히 휘다가 끝에서 크게 들린다
        func eaveY(_ a: CGFloat) -> CGFloat {
            let t = min(a / o.tipHalf, 1)
            return o.mid - (o.mid - o.tipY) * (0.55 * pow(t, 2.2) + 0.45 * pow(t, 9))
        }
        // 추녀마루: 용마루 끝에서 가파르게 내려오다가 바깥으로 거의 평평하게 뻗는다
        let hip: [(x: CGFloat, y: CGFloat)] = (0...30).map { i in
            let t = CGFloat(i) / 30
            let a = o.ridgeHalf + (o.hipEnd - o.ridgeHalf) * t
            let drop = 1 - pow(1 - min(t / o.steep, 1), 2.2)
            return (a, o.topY + (o.flatY - o.topY) * drop + (o.endY - o.flatY) * max(0, (t - o.steep) / (1 - o.steep)))
        }
        let left = hip.reversed().map { point(-$0.x, $0.y) }
        let right = hip.map { point($0.x, $0.y) }
        let eave = stride(from: o.tipHalf, through: -o.tipHalf, by: -3).map { x in point(x, eaveY(abs(x))) }

        // 추녀마루 끝을 수직으로 자르고, 기와층이 조금 더 나가 처마 끝이 된다
        addPolygon([point(-o.tipHalf, o.tipY), point(-o.hipEnd, o.cutY)] + left + right
                   + [point(o.hipEnd, o.cutY), point(o.tipHalf, o.tipY)] + eave)
        // 처마 밑: 끝에서 건물 모서리로 비스듬히 들어가는 추녀 밑면
        for s: CGFloat in [-1, 1] {
            addPolygon([point(s * o.tipHalf, o.tipY), point(s * o.soffitHalf, o.soffitY), point(s * o.soffitHalf, eaveY(o.soffitHalf) - 1)])
        }
        // 잡상: 추녀마루 바깥쪽에 줄지어 앉은 작은 상
        for s: CGFloat in [-1, 1] {
            for i in 0..<5 {
                let a = o.jFrom + (o.jTo - o.jFrom) * CGFloat(i) / 4
                guard let p = hip.min(by: { abs($0.x - a) < abs($1.x - a) }) else { continue }
                let y = p.y + 0.6, h = o.jSize * (1 - CGFloat(i) * 0.06), w = h * 0.6, x = s * a
                addPolygon([(x - w / 2, y), (x - w / 2, y - h * 0.6), (x - w * 0.3, y - h * 0.92), (x, y - h),
                            (x + w * 0.3, y - h * 0.92), (x + w / 2, y - h * 0.6), (x + w / 2, y)].map { point($0.0, $0.1) })
            }
        }

        whites.addLines(left)
        whites.addLines(right)
        rims.addLines(eave)
        // 지붕면 기와 줄: 처마 곡선을 따라 두 줄 (검은 실루엣 안에서도 곡선이 보이게)
        for fraction: CGFloat in [0.35, 0.68] {
            courses.addLines(stride(from: -o.tipHalf + 20, through: o.tipHalf - 20, by: 4).map { x in
                let a = abs(x)
                let top = a <= o.ridgeHalf ? o.topY : (hip.first { $0.x >= a } ?? hip[hip.count - 1]).y
                return point(x, top + (eaveY(a) - top) * fraction)
            })
        }
        // 수막새
        for x in stride(from: -o.tipHalf + 12, through: o.tipHalf - 12, by: 11) {
            let c = point(x, eaveY(abs(x)) - 1.3)
            let r = 2.3 * (point(1, 0).x - point(0, 0).x)
            dots.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    private func arch(centerX: CGFloat, radius: CGFloat, side: CGFloat, bottom: CGFloat) -> [CGPoint] {
        var points = [CGPoint(x: centerX - radius, y: bottom), CGPoint(x: centerX - radius, y: bottom - side)]
        for i in 0...18 {
            let t = Double.pi * (1 - Double(i) / 18)
            points.append(CGPoint(x: centerX + radius * cos(t), y: bottom - side - radius * sin(t)))
        }
        points.append(CGPoint(x: centerX + radius, y: bottom))
        return points
    }

    /// 모든 도형을 같은 방향으로 감아서, 겹쳐 칠해도 구멍이 나지 않게 한다
    private mutating func addPolygon(_ points: [CGPoint]) {
        let area = points.indices.reduce(0.0) { sum, i in
            let p = points[i], q = points[(i + 1) % points.count]
            return sum + p.x * q.y - q.x * p.y
        }
        body.addLines(area < 0 ? points.reversed() : points)
        body.closeSubpath()
    }
}

/// 검은 실루엣과 은은한 흰 선(용마루·추녀마루, 처마선, 기와 줄, 수막새, 홍예문 테두리)
struct GwanghwamunBackground: View {
    var body: some View {
        Canvas { context, size in
            let g = GwanghwamunGeometry(rect: CGRect(origin: .zero, size: size))
            context.fill(g.body, with: .color(.black))
            context.stroke(g.whites, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            context.stroke(g.courses, with: .color(.white.opacity(0.12)), lineWidth: 1)
            context.stroke(g.rims, with: .color(.white.opacity(0.24)), lineWidth: 1.2)
            context.fill(g.dots, with: .color(.white.opacity(0.13)))
            context.stroke(g.archRims, with: .color(.white.opacity(0.18)), lineWidth: 1.2)
        }
    }
}

import SwiftUI

/// 노치 모양. 펼치면 한옥 지붕처럼 보이도록 했다.
/// - 위쪽 양끝은 메뉴바 쪽으로 길게 휘어 붙는다.
/// - 아래 가장자리는 처마선이다. 가운데가 가장 낮고, 양끝으로 갈수록 올라가며 둥근 모서리로 이어진다.
struct NotchShape: Shape {
    /// 위쪽 곡선이 몸통 밖으로 뻗는 가로 길이
    var eave: CGFloat
    /// 위쪽 곡선이 내려오는 세로 길이
    var drop: CGFloat
    /// 아래 모서리 곡선의 세로 길이 (둥근 모서리 반지름)
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(eave, drop), bottomRadius) }
        set {
            eave = newValue.first.first
            drop = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let e = eave
        let d = min(drop, rect.height)
        let b = max(min(bottomRadius, rect.height - d, (rect.width - 2 * e) / 2), 0)
        let span = rect.width - 2 * e
        let left = rect.minX + e, right = rect.maxX - e
        let leftTip = CGPoint(x: left + b, y: rect.maxY)
        let rightTip = CGPoint(x: right - b, y: rect.maxY)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: left, y: rect.minY + d),
                   control1: CGPoint(x: rect.minX + e * 0.6, y: rect.minY),
                   control2: CGPoint(x: left, y: rect.minY + d * 0.2))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - b))
        p.addQuadCurve(to: leftTip, control: CGPoint(x: left, y: rect.maxY))
        // 처마선: 끝 근처에서 빠르게 내려오고 가운데는 거의 평평하다
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                   control1: CGPoint(x: leftTip.x + span * 0.14, y: rect.maxY),
                   control2: CGPoint(x: rect.midX - span * 0.22, y: rect.maxY))
        p.addCurve(to: rightTip,
                   control1: CGPoint(x: rect.midX + span * 0.22, y: rect.maxY),
                   control2: CGPoint(x: rightTip.x - span * 0.14, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - b), control: CGPoint(x: right, y: rect.maxY))
        p.addLine(to: CGPoint(x: right, y: rect.minY + d))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: right, y: rect.minY + d * 0.2),
                   control2: CGPoint(x: rect.maxX - e * 0.6, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

extension NotchShape {
    /// 닫힘·마우스 가까이: 실제 노치 모서리와 비슷하게
    static let closed = NotchShape(eave: 6, drop: 6, bottomRadius: 10)
    /// 알림: 양옆 귀에 짧은 곡선
    static let alert = NotchShape(eave: 10, drop: 8, bottomRadius: 12)
    /// 펼침(기본 테마): 둥근 네모. 위 양끝만 메뉴바 쪽으로 휜다
    static let open = NotchShape(eave: openEave, drop: 14, bottomRadius: 30)
    static let openEave: CGFloat = 14
}

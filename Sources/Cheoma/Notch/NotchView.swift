import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let stats: StatsStore
    let fans: FanController

    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    var body: some View {
        let size = model.shapeSize
        let shape: NotchShape = switch model.phase {
        case .open: .open
        case .alert: .alert
        case .closed, .hovering: .closed
        }

        // 내용은 처음부터 다 펼친 크기로 그려 두고, 커지는 검은 모양으로 잘라서 보여준다.
        // 내용이 모양과 같이 커지면 펼치는 동안 카드가 찌그러진 회색 상자로 보인다
        shape.fill(Color.black)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                content
                    .frame(width: targetSize.width, height: targetSize.height, alignment: .top)
            }
            .clipShape(shape)
            // 그림자는 검은 모양에만 단다. 내용 전체에 달면 그래프가 바뀔 때마다 창 전체 그림자를 다시 계산해서 CPU를 많이 쓴다
            .background {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(model.phase == .open ? 0.45 : 0), radius: 14, y: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Self.spring, value: model.phase)
            .animation(Self.spring, value: model.alert)
            .animation(Self.spring, value: model.tab)
    }

    /// 모양이 커지는 중에도 내용은 다 펼쳤을 때의 크기로 둔다
    private var targetSize: CGSize {
        model.phase == .open ? model.openSize : model.shapeSize
    }

    /// 펼칠 때는 모양이 거의 다 커진 뒤에 내용이 나타나고, 닫을 때는 모양이 줄기 전에 먼저 사라진다
    private static let dashboardTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: -6))
            .animation(.easeOut(duration: 0.2).delay(0.12)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .alert:
            if let alert = model.alert {
                AlertContent(alert: alert, notchWidth: model.notchSize.width)
                    .id(alert.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        case .open:
            DashboardView(notchHeight: model.notchSize.height, stats: stats, fans: fans, tab: $model.tab)
                .transition(Self.dashboardTransition)
        case .closed, .hovering:
            EmptyView()
        }
    }
}

/// 카메라가 있는 가운데는 비워두고 왼쪽 귀에 아이콘, 오른쪽 귀에 텍스트.
private struct AlertContent: View {
    let alert: NotchAlert
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: alert.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(alert.tint)
                .modifier(ChimeSwing(trigger: alert.id))
                .frame(width: NotchModel.earWidth)
            Spacer(minLength: notchWidth)
            Text(alert.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: NotchModel.earWidth - 12)
                .padding(.trailing, 12)
        }
        .frame(maxHeight: .infinity)
    }
}

/// 처마 끝 풍경처럼 위를 축으로 몇 번 흔들리다 멈춘다
private struct ChimeSwing: ViewModifier {
    let trigger: UUID

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, angle in
            view.rotationEffect(.degrees(angle), anchor: .top)
        } keyframes: { _ in
            SpringKeyframe(16, duration: 0.16)
            SpringKeyframe(-11, duration: 0.22)
            SpringKeyframe(7, duration: 0.22)
            SpringKeyframe(-3, duration: 0.2)
            SpringKeyframe(0, duration: 0.24)
        }
    }
}

import SwiftUI

/// 받아쓰는 동안 노치 양옆 귀. 카메라가 있는 가운데는 비워 둔다.
/// 왼쪽 귀: 마이크와 소리 크기 막대 (처마 끝 풍경처럼 가운데에서 양옆으로 퍼진다). 오른쪽 귀: 들은 글의 끝부분 · 단계 글.
/// 소리 크기와 중간 글은 live에서 읽어서, 바뀌어도 이 귀만 다시 그린다
struct DictationEars: View {
    let indicator: DictationIndicator
    @ObservedObject var live: DictationLiveState
    let notchWidth: CGFloat

    private static let earWidth = NotchModel.dictationEarWidth
    /// 귀 바깥쪽 모서리의 곡선을 피하는 여백
    private static let outerInset: CGFloat = 14
    /// 카메라 쪽 여백
    private static let innerInset: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            leftEar
                .padding(.leading, Self.outerInset)
                .padding(.trailing, Self.innerInset)
                .frame(width: Self.earWidth)
            Spacer(minLength: notchWidth)
            rightEar
                .padding(.leading, Self.innerInset)
                .padding(.trailing, Self.outerInset)
                .frame(width: Self.earWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 왼쪽 귀

    @ViewBuilder
    private var leftEar: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .modifier(ChimeSwing(trigger: swingKey))
            switch indicator.stage {
            case .listening:
                DictationLevelBars(levels: live.levels)
                    .transition(.opacity)
                if indicator.handsFree {
                    // 손을 떼도 계속 듣는다 (한 번 더 누르면 멈춘다)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Self.listeningTint.opacity(0.9))
                        .transition(.opacity)
                }
            case .transcribing:
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .transition(.opacity)
            case .inserted, .failed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static let listeningTint = Color(red: 1.0, green: 0.62, blue: 0.28)

    private var symbol: String {
        switch indicator.stage {
        case .listening: "mic.fill"
        case .transcribing: "waveform"
        case .inserted: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch indicator.stage {
        case .listening: Self.listeningTint
        case .transcribing: .white.opacity(0.8)
        case .inserted: .green
        case .failed: .orange
        }
    }

    /// 듣기 시작할 때 · 붙였을 때 · 못 했을 때 한 번씩 흔들린다
    private var swingKey: Int {
        switch indicator.stage {
        case .listening: 1
        case .transcribing: 1
        case .inserted: 2
        case .failed: 3
        }
    }

    // MARK: 오른쪽 귀

    @ViewBuilder
    private var rightEar: some View {
        switch indicator.stage {
        case .listening:
            if live.text.isEmpty {
                earText(indicator.handsFree ? "계속 듣는 중" : "듣는 중", secondary: true)
            } else {
                // 들은 글은 카메라 쪽에서부터 쓰고, 넘치면 앞을 줄여서 가장 새 낱말이 보이게 한다
                earText(live.text, secondary: false, alignment: .leading)
                    .truncationMode(.head)
            }
        case .transcribing:
            earText("변환 중…", secondary: true)
        case .inserted(let message):
            earText(message, secondary: false)
        case .failed(let reason):
            earText(reason, secondary: false)
                .minimumScaleFactor(0.75)
        }
    }

    /// 단계 글은 알림 귀처럼 가운데에, 들은 글은 왼쪽부터
    private func earText(_ text: String, secondary: Bool, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(secondary ? 0.6 : 1))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// 소리 크기 막대. 가운데가 지금 소리, 양옆으로 갈수록 조금 전 소리 (풍경이 바람을 받아 퍼지듯)
private struct DictationLevelBars: View {
    /// 뒤가 가장 새 값
    let levels: [Float]

    private static let maxHeight: CGFloat = 16
    private static let minHeight: CGFloat = 3
    /// 바깥 막대일수록 조금 짧게
    private static let weights: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<DictationLiveState.barCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: 3, height: height(at: index))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(.easeOut(duration: 0.08), value: levels)
    }

    private func height(at index: Int) -> CGFloat {
        // 가운데(2) → levels.last, 그 옆(1, 3) → 하나 전, 끝(0, 4) → 둘 전
        let distance = abs(index - DictationLiveState.barCount / 2)
        let level = levels.indices.contains(levels.count - 1 - distance) ? levels[levels.count - 1 - distance] : 0
        let weight = Self.weights.indices.contains(index) ? Self.weights[index] : 1
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(level) * weight
    }
}

import SwiftUI

struct StatTile<Graph: View>: View {
    let title: String
    let value: String
    let detail: String
    let accent: Color
    @ViewBuilder let graph: Graph

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            graph
                .frame(width: 64, height: 34)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // 같은 줄의 타일끼리 높이를 맞춘다
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 코어별 사용률 막대
struct CoreBars: View {
    let cores: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 1.5
            let width = max((geo.size.width - spacing * CGFloat(max(cores.count - 1, 0))) / CGFloat(max(cores.count, 1)), 1)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(cores.indices, id: \.self) { i in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(color)
                            .frame(height: max(geo.size.height * cores[i], width))
                    }
                    .frame(width: width)
                }
            }
        }
    }
}

struct UsageRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Format.percent(fraction))
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .padding(2)
    }
}

/// 라벨 — 값 — (선택) 비율 막대 한 줄
struct MetricRow: View {
    let label: String
    let value: String
    var fraction: Double?
    var color: Color = .white

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(color)
                            .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 3))
                    }
                }
                .frame(height: 5)
            } else {
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

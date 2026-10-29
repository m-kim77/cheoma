import AppKit
import SwiftUI

enum AppSort: String, CaseIterable {
    case cpu = "CPU"
    case power = "CPU 전력"
    case memory = "메모리"

    func value(_ app: AppUsage) -> Double {
        switch self {
        case .cpu: app.cpu
        case .power: app.cpuWatts
        case .memory: Double(app.memory)
        }
    }

    /// 막대 길이의 기준은 맨 위 앱이지만, 거의 안 쓸 때 막대가 꽉 차 보이지 않도록 최소 기준을 둔다
    var minimumScale: Double {
        switch self {
        case .cpu: 0.25
        case .power: 0.25
        case .memory: 536_870_912
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .power: .yellow
        case .memory: .green
        }
    }
}

/// CPU · 전력 · 메모리를 많이 쓰는 앱. 다른 계정(시스템) 프로세스는 권한이 없어 빠진다.
struct AppsTab: View {
    let apps: [AppUsage]?
    @AppStorage("appsSort") private var sort = AppSort.cpu
    private static let rowCount = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if let apps {
                let rows = Array(apps.sorted(by: isOrderedBefore).prefix(Self.rowCount))
                let scale = max(rows.first.map(sort.value) ?? 0, sort.minimumScale)
                ForEach(rows) { app in
                    AppRow(app: app, fraction: sort.value(app) / scale, color: sort.color)
                }
            } else {
                Text("측정 중…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("내 계정 앱 · CPU 100% = 코어 1개")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ForEach(AppSort.allCases, id: \.self) { item in
                Button { sort = item } label: {
                    HStack(spacing: 2) {
                        if sort == item {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        Text(item.rawValue)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(sort == item ? .primary : .secondary)
                    .frame(width: AppRow.columnWidth, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }

    /// 고른 기준으로 많이 쓰는 순. 같으면 메모리, 이름 순으로 고정해서 줄이 깜빡이지 않게 한다.
    private func isOrderedBefore(_ a: AppUsage, _ b: AppUsage) -> Bool {
        let (x, y) = (sort.value(a), sort.value(b))
        if x != y { return x > y }
        if a.memory != b.memory { return a.memory > b.memory }
        return a.name < b.name
    }
}

private struct AppRow: View {
    static let columnWidth: CGFloat = 62
    let app: AppUsage
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundlePath: app.bundlePath)
                .frame(width: 15, height: 15)
            Text(app.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                Text(Format.processCPU(app.cpu))
                Text(Format.watts(app.cpuWatts))
                Text(Format.processMemory(app.memory))
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .frame(width: Self.columnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.2))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

/// 앱 아이콘. 번들이 없는 프로세스는 터미널 모양. 매초 다시 읽지 않도록 기억해 둔다.
private struct AppIcon: View {
    let bundlePath: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let bundlePath {
            Image(nsImage: Self.icon(for: bundlePath))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        }
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

import SwiftUI

final class HiddenItemsModel: ObservableObject {
    enum State {
        case loading
        case needsPermission
        case loaded(hidden: [MenuBarItem], visible: [MenuBarItem])
    }

    @Published var isPresented = false
    @Published var state = State.loading
    /// 정리 모드: 구분선이 잠깐 보이고, 사용자가 메뉴바에서 직접 ⌘ 드래그로 정리한다
    @Published var isEditing = false
    var onSelect: ((MenuBarItem) -> Void)?
    var onFinishEditing: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRequestPermission: (() -> Void)?
}

/// 메뉴바 아래로 떨어지는 가려진 아이콘 목록
struct HiddenItemsView: View {
    @ObservedObject var model: HiddenItemsModel

    static let width: CGFloat = 360
    static let tileSize = CGSize(width: 62, height: 60)
    private let columns = Array(repeating: GridItem(.fixed(tileSize.width), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            if model.isPresented {
                content
                    .frame(width: Self.width)
                    .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity)
                    ))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
        // 패널의 투명한 빈 곳을 눌러도 닫히도록 (거의 투명한 배경이어야 클릭을 받는다)
        .background(Color.black.opacity(0.001).onTapGesture { model.onDismiss?() })
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.isPresented)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.isEditing)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(24)
        case .needsPermission:
            VStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text("가려진 아이콘을 읽고 누르려면\n손쉬운 사용 권한이 필요해요")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                Button("권한 허용하러 가기") { model.onRequestPermission?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        case .loaded(let hidden, let visible):
            VStack(alignment: .leading, spacing: 12) {
                header(hiddenCount: hidden.count)
                if model.isEditing {
                    guide
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            section("숨겨질 아이콘 (| 왼쪽)", items: hidden, empty: "아직 없어요")
                            section("보이는 아이콘", items: visible, empty: "모두 숨겨져 있어요")
                        }
                    }
                    .frame(maxHeight: 420)
                } else if hidden.isEmpty {
                    Text("가려진 아이콘이 없어요. 아이콘을 직접 숨기려면 정리를 눌러보세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    grid(hidden)
                }
            }
            .padding(14)
        }
    }

    private func header(hiddenCount: Int) -> some View {
        HStack {
            Text(model.isEditing ? "아이콘 정리" : "가려진 아이콘 \(hiddenCount)개")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.isEditing ? "완료" : "정리") {
                if model.isEditing { model.onFinishEditing?() }
                model.isEditing.toggle()
            }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("메뉴바에서 ⌘ 누른 채 아이콘을 | 왼쪽으로 끌면 숨겨져요", systemImage: "command")
            Label("꺼낼 때는 반대로 | 오른쪽으로 끌어 놓으세요", systemImage: "arrow.right")
            Label("완료를 누르면 | 왼쪽 아이콘이 노치 뒤로 들어가요", systemImage: "checkmark")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func section(_ title: String, items: [MenuBarItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            if items.isEmpty {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
            } else {
                grid(items)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func grid(_ items: [MenuBarItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                ItemTile(item: item, onDismiss: { model.onDismiss?() }) { model.onSelect?(item) }
            }
        }
    }
}

private struct ItemTile: View {
    let item: MenuBarItem
    let onDismiss: () -> Void
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 18))
                    } else if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 18))
                    }
                }
                .frame(width: 28, height: 28)
                Text(item.label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .frame(width: HiddenItemsView.tileSize.width, height: HiddenItemsView.tileSize.height)
            .background(isHovering ? .white.opacity(0.12) : .white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // 우클릭: 메뉴바 아이콘은 손쉬운 사용으로 "누르기"(왼쪽 클릭)만 할 수 있어서, 앱의 우클릭 메뉴 대신 앱 단위 동작을 보여준다
        .contextMenu {
            Button("열기") { action() }
            if let app = runningApp {
                if let url = app.bundleURL {
                    Button("Finder에서 보기") {
                        onDismiss()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                // 시스템 항목(제어 센터, 입력기 등)은 끄지 않는다
                if !(app.bundleIdentifier ?? "").hasPrefix("com.apple.") {
                    Divider()
                    Button("\(item.appName) 종료") {
                        onDismiss()
                        app.terminate()
                    }
                }
            }
        }
        .help(item.appName == item.label ? item.label : "\(item.appName) — \(item.label)")
    }

    private var runningApp: NSRunningApplication? {
        NSRunningApplication(processIdentifier: item.pid)
    }
}

import SwiftUI

/// 에이전트 탭 오른쪽에 보여줄 것
enum AgentsPane: Equatable {
    var recordID: String? {
        if case .record(let id) = self { return id }
        return nil
    }

    /// 고른 세션 (세션이 없으면 연결 설정 안내)
    case session
    /// 새 에이전트 고르기
    case launcher
    /// 연결 설정 (Terminal 권한 · 훅)
    case setup
    /// 계정 한눈에 보기
    case accounts
    /// 왼쪽 '최근 기록'에서 고른 세션 (세션 ID)
    case record(String)
}

/// 에이전트 탭: 위는 사용량, 왼쪽은 돌고 있는 코드 에이전트 목록, 오른쪽은 고른 세션의 화면 미리보기 · 선택지 · 답 입력
struct AgentsTab: View {
    @ObservedObject var store: AgentStore
    let model: NotchModel
    @State private var pane = AgentsTab.previewPane ?? .session
    /// 잠깐 보여주는 알림 (store.message)
    @State private var banner: String?
    /// `--render`에서 새 에이전트 · 설정 화면을 그릴 때 쓴다
    static var previewPane: AgentsPane?
    static let listWidth: CGFloat = 232
    #if DEBUG
    /// `--click-test`가 버튼이 눌렸는지 본다
    static var debugPane: AgentsPane?
    #endif

    var body: some View {
        let sessions = store.sessions
        let selected = store.selectedSession
        VStack(spacing: 8) {
            AgentsUsageStrip(usage: store.usage, pane: $pane)
            HStack(alignment: .top, spacing: 10) {
                AgentsSessionList(sessions: sessions, recorded: store.recordedSessions,
                                  selectedID: pane.recordID == nil ? selected?.id : nil, selectedRecordID: pane.recordID) { id in
                    store.select(id)
                    pane = .session
                } onSelectRecord: { id in
                    pane = .record(id)
                }
                .agentsFrame(width: Self.listWidth)
                detail(selected)
                    .overlay(alignment: .bottom) { bannerView }
            }
        }
        // 오른쪽 아래 모서리: 끌어서 크기 바꾸기 (아래 여백 자리에 둔다)
        .overlay(alignment: .bottomTrailing) {
            AgentsResizeGrip(model: model)
                .offset(x: 14, y: 14)
        }
        // 글자 칸의 글자 · 커서 색이 시스템 밝은 모드를 따라 검게 되지 않도록
        .environment(\.colorScheme, .dark)
        .onChange(of: store.message) { _, message in show(message) }
        #if DEBUG
        .onChange(of: pane) { _, pane in Self.debugPane = pane }
        #endif
        .onDisappear { model.keepsOpen = false }
    }

    @ViewBuilder
    private func detail(_ selected: AgentSession?) -> some View {
        switch pane {
        case .launcher:
            AgentsLauncherPane(store: store, model: model, pane: $pane)
        case .setup:
            AgentsSetupPane(store: store, model: model, isEmpty: false, pane: $pane)
        case .accounts:
            AgentsAccountsPane(store: store, pane: $pane)
        case .record(let id):
            if let record = store.recordedSessions.first(where: { $0.id == id }) {
                AgentsRecordDetail(record: record, store: store, pane: $pane)
            } else if let selected {
                // 그 세션이 다시 돌기 시작해서 기록 목록에서 빠졌다
                AgentsSessionDetail(session: selected, store: store, model: model)
            } else {
                AgentsSetupPane(store: store, model: model, isEmpty: true, pane: $pane)
            }
        case .session:
            if let selected {
                AgentsSessionDetail(session: selected, store: store, model: model)
            } else {
                AgentsSetupPane(store: store, model: model, isEmpty: true, pane: $pane)
            }
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            Text(banner)
                .agentsFont(size: 10.5, weight: .medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.2), in: Capsule())
                .padding(.bottom, 8)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func show(_ message: String?) {
        withAnimation(.easeOut(duration: 0.15)) { banner = message }
        guard let message else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard banner == message else { return }
            withAnimation(.easeIn(duration: 0.2)) { banner = nil }
        }
    }
}

/// 에이전트 탭 크기 바꾸기 손잡이. 끌면 노치가 양옆과 아래로 커진다 (가운데에 붙어 있어서 가로는 끈 만큼의 두 배).
/// 끄는 동안 창 크기가 바뀌어 뷰 좌표가 흔들리므로 화면 좌표(마우스 위치)로 잰다. 두 번 누르면 기본 크기
struct AgentsResizeGrip: View {
    let model: NotchModel
    @State private var start: (mouse: CGPoint, size: CGSize)?
    @State private var isHovering = false

    var body: some View {
        Canvas { context, size in
            for inset in [3.0, 7.0, 11.0] {
                var path = Path()
                path.move(to: CGPoint(x: size.width - 2, y: inset))
                path.addLine(to: CGPoint(x: inset, y: size.height - 2))
                context.stroke(path, with: .color(.white.opacity(isHovering || start != nil ? 0.7 : 0.3)), lineWidth: 1.2)
            }
        }
        .frame(width: 14, height: 14)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if start == nil {
                        start = (mouse, model.agentsSize)
                        model.isResizing = true
                    }
                    guard let start else { return }
                    // 화면 좌표는 위로 갈수록 y가 크다
                    model.resizeAgents(to: CGSize(width: start.size.width + (mouse.x - start.mouse.x) * 2,
                                                  height: start.size.height + (start.mouse.y - mouse.y)))
                }
                .onEnded { _ in
                    start = nil
                    model.isResizing = false
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.resizeAgents(to: model.agentsMinimumSize) })
        .help("끌어서 크기 바꾸기 · 두 번 누르면 기본 크기")
        .accessibilityLabel("에이전트 창 크기")
    }
}

import SwiftUI

/// 에이전트 탭 오른쪽에 보여줄 것
enum AgentsPane: Equatable {
    /// 고른 세션 (세션이 없으면 연결 설정 안내)
    case session
    /// 새 에이전트 고르기
    case launcher
    /// 연결 설정 (Terminal 권한 · 훅)
    case setup
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

    var body: some View {
        let sessions = AgentsStyle.sorted(store.sessions)
        let selected = store.selectedSession
        VStack(spacing: 8) {
            AgentsUsageStrip(usage: store.usage, pane: $pane)
            HStack(alignment: .top, spacing: 10) {
                AgentsSessionList(sessions: sessions, recorded: store.recordedSessions, selectedID: selected?.id) { id in
                    store.select(id)
                    pane = .session
                }
                .frame(width: Self.listWidth)
                detail(selected)
                    .overlay(alignment: .bottom) { bannerView }
            }
        }
        // 글자 칸의 글자 · 커서 색이 시스템 밝은 모드를 따라 검게 되지 않도록
        .environment(\.colorScheme, .dark)
        .onChange(of: store.message) { _, message in show(message) }
        .onDisappear { model.keepsOpen = false }
    }

    @ViewBuilder
    private func detail(_ selected: AgentSession?) -> some View {
        switch pane {
        case .launcher:
            AgentsLauncherPane(store: store, model: model, pane: $pane)
        case .setup:
            AgentsSetupPane(store: store, isEmpty: false, pane: $pane)
        case .session:
            if let selected {
                AgentsSessionDetail(session: selected, store: store, model: model)
            } else {
                AgentsSetupPane(store: store, isEmpty: true, pane: $pane)
            }
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(.system(size: 10.5, weight: .medium))
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

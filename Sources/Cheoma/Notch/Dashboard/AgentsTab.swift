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
    @Environment(\.agentsScale) private var scale
    /// 잠깐 보여주는 알림 (store.message)
    @State private var banner: String?
    static let listWidth: CGFloat = 232
    #if DEBUG
    @State private var pane = AgentsTab.previewPane ?? .session
    /// `--render`에서 새 에이전트 · 설정 화면을 그릴 때 쓴다
    static var previewPane: AgentsPane?
    /// `--click-test`가 버튼이 눌렸는지 본다
    static var debugPane: AgentsPane?
    #else
    @State private var pane = AgentsPane.session
    #endif

    var body: some View {
        let sessions = store.sessions
        let selected = store.selectedSession
        VStack(spacing: 0) {
            AgentsUsageStrip(usage: store.visibleUsage, pane: $pane)
                .padding(.bottom, 8)
            GeometryReader { area in
                HStack(alignment: .top, spacing: 10) {
                    AgentsSessionList(sessions: sessions, recorded: store.recordedSessions,
                                      selectedID: pane.recordID == nil ? selected?.id : nil, selectedRecordID: pane.recordID) { id in
                        store.select(id)
                        pane = .session
                    } onSelectRecord: { id in
                        pane = .record(id)
                    }
                    .frame(width: min(Self.listWidth * scale, area.size.width * 0.33))
                    // 작은 높이에서도 답 입력과 선택지까지 스크롤할 수 있게 한다.
                    ScrollView(.vertical) {
                        detail(selected)
                            .frame(minHeight: area.size.height, idealHeight: area.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .overlay(alignment: .bottom) { bannerView }
                }
            }
            AgentsResizeGrip(model: model)
                .frame(maxWidth: .infinity, alignment: .trailing)
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

/// 두 테마에서 같은 자리에 놓이는 크기 조절 손잡이. 내용이 스크롤되어도 늘 보인다.
private struct AgentsResizeGrip: View {
    let model: NotchModel
    /// 마우스가 올라가 있거나 끄는 중
    @State private var isActive = false

    var body: some View {
        Label("크기 조절", systemImage: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.white.opacity(isActive ? 0.2 : 0.1), in: Capsule())
            .frame(minWidth: 88, minHeight: 28)
            // 마우스는 위에 덮은 AppKit 뷰가 받으므로 올라감도 거기서 알려 준다
            .overlay { AgentsResizeTarget(model: model) { isActive = $0 } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("에이전트 탭 크기 조절")
            .accessibilityAction(named: "기본 크기로") { model.resetAgentsSize() }
    }
}

/// 키 창이 아닌 노치에서도 첫 마우스 누름부터 추적한다. 창 자체가 움직이므로 델타는 화면 좌표로 잰다.
private struct AgentsResizeTarget: NSViewRepresentable {
    let model: NotchModel
    let onActive: (Bool) -> Void

    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ view: GripView, context: Context) {
        view.model = model
        view.onActive = onActive
    }

    final class GripView: NSView {
        weak var model: NotchModel?
        var onActive: ((Bool) -> Void)?
        private var start: (point: CGPoint, size: CGSize)?
        private var isInside = false

        private static var resizeCursor: NSCursor {
            if #available(macOS 15, *) { .frameResize(position: .bottomRight, directions: .all) } else { .openHand }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            toolTip = "드래그하여 크기 조절 · 이중 클릭하여 기본 크기로"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // 커서 영역은 키 창에서만 쓰인다. 노치는 보통 키 창이 아니어서 들어오고 나갈 때 직접 바꾼다
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: Self.resizeCursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            isInside = true
            updateActive()
        }

        override func mouseExited(with event: NSEvent) {
            isInside = false
            updateActive()
        }

        private func updateActive() {
            let active = isInside || start != nil
            onActive?(active)
            (active ? Self.resizeCursor : .arrow).set()
        }

        override func mouseDown(with event: NSEvent) {
            guard let model, let window else { return }
            if event.clickCount == 2 {
                model.resetAgentsSize()
                return
            }
            start = (window.convertPoint(toScreen: event.locationInWindow), model.agentsSize)
            model.isResizing = true
            updateActive()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let model, let window else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            // 노치가 가운데 고정이라 한쪽 끝을 끈 거리의 두 배만큼 폭이 바뀐다.
            let width = start.size.width + 2 * (point.x - start.point.x)
            var height = start.size.height + start.point.y - point.y
            if model.theme == .gwanghwamun {
                // 폭을 바꾸면 지붕 높이도 바뀐다. 손잡이의 세로 위치는 마우스를 따라가야 한다.
                let fitted = NotchModel.clampAgents(CGSize(width: width, height: height),
                                                    minimum: NotchModel.agentsMinimumSize(scale: model.agentsTextScale.rawValue),
                                                    screen: model.screenSize, theme: model.theme)
                height -= Gwanghwamun.contentTop(content: fitted) - Gwanghwamun.contentTop(content: start.size)
            }
            model.resizeAgents(to: CGSize(width: width, height: height))
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil {
                mouseDragged(with: event)
                endDrag()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // 끄는 도중 탭이 사라지면 끌기를 끝낸다. SwiftUI가 뷰를 치우는 중이라 모델은 다음 차례에 바꾼다
            if newWindow == nil, start != nil {
                start = nil
                isInside = false
                DispatchQueue.main.async { [weak model] in model?.isResizing = false }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func endDrag() {
            guard start != nil else { return }
            start = nil
            model?.isResizing = false
            // 창 밖에서 놓았으면 나감 알림이 이미 지나갔으므로 지금 마우스 위치로 다시 판단한다
            if let window {
                isInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
            updateActive()
        }
    }
}

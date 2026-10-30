import SwiftUI

struct NotchAlert: Equatable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let text: String
}

/// 노치 영역의 상태. 크기는 phase 하나로 결정되고, 뷰는 그 크기로 스프링 애니메이션한다.
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case closed    // 실제 노치와 같은 크기 (안 보임)
        case hovering  // 마우스가 다가오면 살짝 커짐
        case alert     // 노치 양옆으로 귀가 생기며 아이콘/텍스트 표시
        case open      // 아래로 크게 펼쳐짐
    }

    static let earWidth: CGFloat = 100
    /// 창은 가장 큰 탭·테마에 맞춰 한 번만 만들어 두고, 모양만 탭 크기로 바뀐다
    static let maxOpenSize: CGSize = {
        let basic = DashboardTab.allCases.map(\.openSize)
        let sizes = basic + basic.map { Gwanghwamun.frameSize(content: $0) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }()
    private static let tabDefaultsKey = "dashboardTab"
    private static let openDelay: TimeInterval = 0.18
    private static let alertDuration: TimeInterval = 2.8

    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var isOpen = false
    @Published private(set) var isHovering = false
    @Published private(set) var alert: NotchAlert?
    @Published var tab = UserDefaults.standard.string(forKey: tabDefaultsKey).flatMap(DashboardTab.init) ?? .overview {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabDefaultsKey) }
    }

    @Published var theme = NotchTheme.saved {
        didSet { NotchTheme.saved = theme }
    }

    /// true인 동안은 마우스가 벗어나도 닫지 않는다 (에이전트에 보낼 답을 입력하는 중)
    @Published var keepsOpen = false

    /// 펼쳤을 때 모양 전체의 크기
    var openSize: CGSize {
        switch theme {
        case .basic: tab.openSize
        case .gwanghwamun: Gwanghwamun.frameSize(content: dashboardSize)
        }
    }

    /// 펼쳤을 때 대시보드 내용의 크기. 광화문은 지붕이 노치를 덮으니 노치 높이만큼 비울 필요가 없다
    var dashboardSize: CGSize {
        switch theme {
        case .basic: tab.openSize
        case .gwanghwamun: CGSize(width: tab.openSize.width,
                                  height: tab.openSize.height - notchSize.height + Gwanghwamun.dashboardTopInset)
        }
    }

    private var openWork: DispatchWorkItem?
    private var alertWork: DispatchWorkItem?

    var phase: Phase {
        if isOpen { return .open }
        if alert != nil { return .alert }
        if isHovering { return .hovering }
        return .closed
    }

    var shapeSize: CGSize {
        switch phase {
        case .closed: notchSize
        case .hovering: CGSize(width: notchSize.width + 18, height: notchSize.height + 4)
        case .alert: CGSize(width: notchSize.width + Self.earWidth * 2, height: notchSize.height)
        case .open: openSize
        }
    }

    func updateMouse(inHotZone: Bool, inOpenZone: Bool) {
        if isOpen {
            if !inOpenZone && !keepsOpen { isOpen = false; isHovering = false }
            return
        }
        if isHovering != inHotZone { isHovering = inHotZone }

        openWork?.cancel()
        guard inHotZone else { return }
        // 메뉴바 지나가다 실수로 열리지 않도록 짧게 머물러야 열림
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering else { return }
            self.isOpen = true
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
    }

    /// 미리보기 렌더링과 CPU 측정(--bench)용: 마우스 없이 대시보드를 연다
    func previewOpen(_ tab: DashboardTab) {
        self.tab = tab
        isOpen = true
    }

    func show(_ alert: NotchAlert) {
        self.alert = alert
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.alert = nil }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.alertDuration, execute: work)
    }
}

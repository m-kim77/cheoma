import Foundation

/// 노치를 펼쳤을 때의 모양. 닫힘·알림은 테마와 상관없이 노치 모양 그대로다.
enum NotchTheme: String, CaseIterable {
    /// 둥근 네모 (기본값)
    case basic
    /// 광화문 실루엣: 2층 지붕 아래 석축에 대시보드가 들어간다
    case gwanghwamun

    var title: String {
        switch self {
        case .basic: "기본"
        case .gwanghwamun: "광화문"
        }
    }

    private static let defaultsKey = "notchTheme"

    static var saved: NotchTheme {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(NotchTheme.init) ?? .basic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

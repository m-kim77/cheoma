import AppKit
import SwiftUI

/// `Cheoma --notify "빌드 완료" [--symbol hammer.fill] [--color green]`
/// 실행 중인 Cheoma에 알림을 보내 노치 양옆에 잠깐 띄운다 (소리 없음).
/// 오래 걸리는 스크립트나 빌드가 끝날 때 쓰기 좋다.
enum NotifyCommand {
    static let notificationName = Notification.Name("io.github.m-kim77.cheoma.notify")
    private static let maxLength = 40

    private static let colors: [String: Color] = [
        "green": .green, "red": .red, "orange": .orange, "yellow": .yellow, "blue": .blue,
        "purple": .purple, "pink": .pink, "cyan": .cyan, "teal": .teal, "white": .white, "gray": .gray,
    ]

    /// 알림을 보내는 쪽 (별도 프로세스로 실행된다)
    static func send(arguments: [String]) {
        var text: String?
        var symbol = "bell.fill"
        var color = "orange"
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--symbol" where index + 1 < arguments.count:
                symbol = arguments[index + 1]
                index += 1
            case "--color" where index + 1 < arguments.count:
                color = arguments[index + 1]
                index += 1
            default:
                if text == nil { text = arguments[index] }
            }
            index += 1
        }
        guard let text, !text.isEmpty else {
            print("사용법: Cheoma --notify \"내용\" [--symbol SF Symbol 이름] [--color green|red|orange|blue|…]")
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil,
            userInfo: ["text": String(text.prefix(maxLength)), "symbol": symbol, "color": color],
            deliverImmediately: true)
    }

    /// 받는 쪽 (실행 중인 앱): 알 수 없는 기호나 색은 기본값으로
    static func alert(from notification: Notification) -> NotchAlert? {
        guard let info = notification.userInfo, let text = info["text"] as? String, !text.isEmpty else { return nil }
        let symbol = (info["symbol"] as? String).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
        let color = (info["color"] as? String).flatMap { colors[$0.lowercased()] }
        return NotchAlert(symbol: symbol ?? "bell.fill", tint: color ?? .orange, text: String(text.prefix(maxLength)))
    }
}

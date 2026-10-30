import SwiftUI

/// 터미널 글자의 ANSI 색 코드 다루기. 구현 예정: 전경·배경색(16색 · 256색 · 24비트), 굵게, 흐리게, 반전
enum ANSIText {
    /// 미리보기에 그릴 색 입힌 글자
    static func attributed(_ text: String) -> AttributedString {
        AttributedString(plain(text))
    }

    /// 색 코드를 지운 글자
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

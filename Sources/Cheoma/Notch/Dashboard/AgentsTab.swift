import SwiftUI

/// 에이전트 탭: 돌고 있는 코드 에이전트 목록, 고른 세션의 화면 미리보기 · 선택지 · 답 입력, 사용량. 구현 예정
struct AgentsTab: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var model: NotchModel

    var body: some View {
        Text("에이전트 \(store.sessions.count)개")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

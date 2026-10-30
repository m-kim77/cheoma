import Foundation

/// 에이전트 기록 파일에서 사용량과 최근 세션을 읽는다 (내 맥 안의 파일만, 네트워크 없음). 구현 예정:
/// - Codex: ~/.codex/sessions/**/rollout-*.jsonl 의 token_count 이벤트 → rate_limits (5시간 · 1주 사용 %, 리셋 시각)
/// - Claude Code: ~/.claude*/projects/*/*.jsonl (설정 폴더마다 계정 하나) → 오늘 · 지금 5시간 구간의 비용과 토큰, 세션 제목
/// 바뀐 파일만 이어서 읽어서 몇 초마다 불러도 가볍다. 백그라운드 큐에서 부른다
final class AgentUsageReader {
    func read() -> AgentUsage {
        AgentUsage()
    }
}

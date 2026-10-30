import Foundation

/// 내 계정에서 도는 코드 에이전트 프로세스를 찾는다 (libproc, 권한 불필요).
/// 구현 예정: 프로세스 이름·인자로 종류를 가리고, tty · 작업 폴더 · 시작 시각 · 띄운 앱을 채운다.
enum AgentScanner {
    /// 지금 도는 에이전트 프로세스 전부. 백그라운드 큐에서 몇 초마다 부르므로 가볍게 (몇 ms 안)
    static func scan() -> [AgentProcess] {
        []
    }

    /// tty에 마지막으로 출력이 나간 시각 (tty 장치의 수정 시각). 화면이 바뀌는 중인지 Apple Event 없이 싸게 알 수 있다
    static func lastOutput(tty: String) -> Date? {
        nil
    }

    /// 프로세스가 아직 살아 있는지
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

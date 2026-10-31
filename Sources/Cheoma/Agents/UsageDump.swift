import Foundation

/// `Cheoma --usage`: 에이전트 사용량과 최근 세션, 훅 설치 상태를 출력한다 (개발용).
/// 두 번 읽어서 처음(전부 읽기)과 다음(바뀐 것만)의 시간을 같이 찍는다
enum UsageDump {
    static func run() {
        let reader = AgentUsageReader()
        var start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let usage = reader.read()
        let first = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        _ = reader.read()
        let second = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        print(String(format: "읽는 데 처음 %.1fms, 다음 %.1fms", first, second))

        print("\nCodex")
        if let account = usage.codexAccount {
            print("  로그인 \(account.mode ?? "-") · \(account.email ?? "-") · \(account.plan ?? "-")")
        }
        if let codex = usage.codex {
            print("  요금제 \(codex.plan ?? "?") · \(ago(codex.updatedAt)) 기록")
            for (name, window) in [("primary", codex.primary), ("secondary", codex.secondary)] {
                guard let window else { continue }
                let reset = window.resetsAt.map { " · \(date($0)) 초기화" } ?? ""
                print(String(format: "  %@ %d분 구간 %.0f%%", name, window.windowMinutes, window.usedPercent) + reset)
            }
        } else {
            print("  기록 없음")
        }

        print("\nClaude Code")
        if usage.claude.isEmpty { print("  기록 없음") }
        for account in usage.claude {
            print(String(format: "  %@  오늘 $%.2f · %@ 토큰", account.account, account.todayCostUSD, tokens(account.todayTokens)))
            print("    계정 \(account.email ?? "-") · 요금제 \(account.plan ?? "-") · 한도 받은 때 \(account.limitsUpdatedAt.map(date) ?? "-")")
            if let started = account.blockStartedAt, let ends = account.blockEndsAt {
                print(String(format: "    5시간 구간 $%.2f (%@ ~ %@)", account.blockCostUSD, date(started), date(ends)))
            }
            for limit in account.limits {
                print(String(format: "    한도 %d분 %.0f%%", limit.windowMinutes, limit.usedPercent))
            }
        }

        print("\n최근 세션 \(usage.recentSessions.count)개")
        for session in usage.recentSessions.prefix(12) {
            let cost = session.costUSD.map { String(format: " · $%.2f", $0) } ?? ""
            let done = session.isTurnComplete.map { $0 ? " · 끝남" : " · 진행 중" } ?? ""
            print("  \(session.kind.rawValue)  \(ago(session.lastActivity))\(cost)\(done)  \(session.cwd ?? "?")")
            if let title = session.title { print("      제목 \(title)") }
            if let message = session.lastMessage { print("      마지막 \(message.prefix(100))") }
        }

        print("\n훅")
        let status = HookInstaller.status()
        for target in status.claude {
            print("  Claude \(target.configDir.path): \(target.isInstalled ? "설치됨" : "없음")")
        }
        print("  Codex: \(status.codex)")
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)초 전" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1e6) : String(format: "%.0fk", Double(count) / 1e3)
    }
}

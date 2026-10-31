import Foundation

/// 이 맥에 로그인된 에이전트 계정 (내 맥 안의 파일만 읽는다).
/// - Claude Code: 설정 폴더마다 `.claude.json`의 oauthAccount(이메일 · 요금제)와 cachedUsageUtilization(Claude Code가 받아 둔 5시간 · 주간 한도).
///   기본 폴더(~/.claude)는 홈의 `~/.claude.json`, 다른 폴더(CLAUDE_CONFIG_DIR)는 그 안의 `.claude.json`을 쓴다 (10/31 확인)
/// - Codex: `~/.codex/auth.json`의 로그인 방식과 id_token 안의 이메일 · ChatGPT 요금제
enum AgentAccounts {
    struct Claude: Equatable, Sendable {
        var email: String?
        var displayName: String?
        /// "Max 20x", "Pro" …
        var plan: String?
        /// Claude Code가 마지막으로 받아 둔 한도와 받은 시각
        var limits: [UsageWindow] = []
        var limitsFetchedAt: Date?
    }

    /// 그 설정 폴더의 계정 파일
    static func claudeFile(configDir: URL, home: URL) -> URL {
        let inside = configDir.appendingPathComponent(".claude.json")
        // 기본 폴더는 홈의 ~/.claude.json에 로그인 정보가 있다. ~/.claude/.claude.json이 따로 있어도 로그인 정보는 없다
        if configDir.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path {
            return home.appendingPathComponent(".claude.json")
        }
        return inside
    }

    static func claude(json data: Data) -> Claude? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any] else { return nil }
        var account = Claude(email: oauth["emailAddress"] as? String,
                             displayName: (oauth["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             plan: planName(oauth))
        if let cached = object["cachedUsageUtilization"] as? [String: Any],
           let utilization = cached["utilization"] as? [String: Any] {
            account.limits = [("five_hour", 300), ("seven_day", 10_080)].compactMap { key, minutes in
                guard let window = utilization[key] as? [String: Any],
                      let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
                return UsageWindow(usedPercent: used, windowMinutes: minutes, resetsAt: (window["resets_at"] as? String).flatMap(date))
            }
            account.limitsFetchedAt = (cached["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return account
    }

    /// 화면에 보일 요금제 이름. planDisplayName이 있으면 그대로, 없으면 조직 종류와 한도 등급으로 ("default_claude_max_20x" → "Max 20x")
    static func planName(_ oauth: [String: Any]) -> String? {
        if let name = oauth["planDisplayName"] as? String, !name.isEmpty { return name }
        let tier = (oauth["organizationRateLimitTier"] as? String) ?? ""
        if let range = tier.range(of: "max_") { return "Max " + tier[range.upperBound...] }
        switch oauth["organizationType"] as? String {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }

    /// "2026-10-31T07:19:59.651958+00:00": 소수점 아래가 여섯 자리라 ISO8601DateFormatter가 못 읽어서 떼고 읽는다
    static func date(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: "."),
           let end = trimmed[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            trimmed.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - Codex

    struct Codex: Equatable, Sendable {
        /// "chatgpt" (ChatGPT 로그인) 또는 "apikey"
        var mode: String?
        var email: String?
        /// "plus", "pro" …
        var plan: String?
    }

    static func codex(authJSON data: Data) -> Codex? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var account = Codex(mode: object["auth_mode"] as? String)
        if account.mode == nil, let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { account.mode = "apikey" }
        if let tokens = object["tokens"] as? [String: Any], let token = tokens["id_token"] as? String,
           let claims = jwtClaims(token) {
            account.email = claims["email"] as? String
            account.plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        }
        return account
    }

    /// JWT 가운데 조각(base64url)의 JSON. 서명은 보지 않는다 (보여주기만 한다)
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

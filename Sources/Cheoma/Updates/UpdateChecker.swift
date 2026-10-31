import AppKit
import SwiftUI

/// 앱 버전. 점으로 나눈 숫자 단위로 비교한다 (0.10.0 > 0.9.0, 0.2 == 0.2.0)
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let parts: [Int]

    /// "v0.2.0", "0.2.0"을 읽는다. "0.2.0-beta" 같은 꼬리표는 떼고 숫자만 본다
    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.first == "v" || core.first == "V" { core.removeFirst() }
        core = String(core.prefix { $0 != "-" && $0 != "+" })
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    /// 이 앱의 버전 (Info.plist). 번들 없이 돌리는 개발 빌드는 nil
    static var bundle: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for (a, b) in zip(lhs.padded(to: rhs), rhs.padded(to: lhs)) where a != b { return a < b }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.padded(to: rhs) == rhs.padded(to: lhs)
    }

    /// 자릿수가 다르면 모자란 쪽에 0을 채운다
    private func padded(to other: AppVersion) -> [Int] {
        parts + Array(repeating: 0, count: max(0, other.parts.count - parts.count))
    }
}

/// GitHub 릴리스 API 응답에서 쓰는 부분
struct AppRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease
    }

    var version: AppVersion? { AppVersion(tagName) }

    static func decode(_ data: Data) throws -> AppRelease {
        try JSONDecoder().decode(AppRelease.self, from: data)
    }

    /// 정식 릴리스이고 지금 버전보다 새것이면 그 릴리스, 아니면 nil (draft · prerelease는 보지 않는다)
    func newer(than current: AppVersion) -> AppRelease? {
        guard !draft, !prerelease, let version, version > current else { return nil }
        return self
    }

    /// 설정 창에 보여 줄 바뀐 내용 앞부분. 릴리스 설명은 영어 다음 `---` 아래에 한국어가 오므로, 한국어 부분이 있으면 그쪽을 쓴다.
    /// 마크다운 제목(###)은 떼고 목록(-)은 •로 바꾼다. 굵게 · 링크 같은 줄 안의 표시는 화면에서 그린다
    func summary(maxLines: Int = 8) -> String {
        let sections = (body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n---")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let section = sections.first { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } } ?? sections.first ?? ""
        let lines = section.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.prefix(maxLines).map { line in
            if line.hasPrefix("#") { return String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return "• " + line.dropFirst(2) }
            return line
        }.joined(separator: "\n")
    }
}

/// GitHub의 최신 릴리스를 보고 새 버전이 나왔는지 알려 준다. 켜고 조금 뒤 한 번, 그 뒤로 하루에 한 번 확인한다.
/// 같은 버전은 한 번만 노치로 알리고, 네트워크 오류는 로그만 남긴다. 설치는 하지 않고 받는 곳(릴리스 페이지)만 연다
@MainActor
final class UpdateChecker: ObservableObject {
    nonisolated static let latestURL = URL(string: "https://api.github.com/repos/m-kim77/cheoma/releases/latest")!
    static let enabledKey = "update.checks"
    private static let lastCheckedKey = "update.lastChecked"
    private static let notifiedKey = "update.notifiedVersion"
    private static let launchDelay: TimeInterval = 20
    private static let interval: TimeInterval = 24 * 3600

    /// 지금 버전보다 새 릴리스 (없으면 nil)
    @Published private(set) var available: AppRelease?
    @Published private(set) var isChecking = false
    /// 마지막 확인이 실패했는지 (설정 창의 "지금 확인" 결과)
    @Published private(set) var lastCheckFailed = false
    @Published private(set) var lastChecked: Date?
    let current: AppVersion?
    var onAlert: ((NotchAlert) -> Void)?

    private let defaults: UserDefaults
    private let fetch: @Sendable () async throws -> Data
    private var timer: Timer?

    init(current: AppVersion? = AppVersion.bundle, defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable () async throws -> Data = { try await UpdateChecker.download() }) {
        self.current = current
        self.defaults = defaults
        self.fetch = fetch
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard current != nil else {
            AppLog.write("새 버전 확인: 버전 정보가 없는 개발 빌드라 확인하지 않음")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            guard let self, self.isEnabled else { return }
            await self.check()
        }
        // 한 시간마다 하루가 지났는지 본다 (잠자기에서 깨어난 뒤에도 늦지 않게)
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 켜져 있고 마지막 확인에서 하루가 지났으면 확인한다
    func checkIfDue() {
        guard isEnabled, !isChecking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Task { await check() }
    }

    /// 설정 창 · 메뉴의 "지금 확인". 사용자가 직접 보는 중이라 노치 알림은 띄우지 않는다
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool = false) async {
        guard let current, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try AppRelease.decode(try await fetch())
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
            lastCheckFailed = false
            available = release.newer(than: current)
            guard let newer = available, let version = newer.version else { return }
            let notified = defaults.string(forKey: Self.notifiedKey).flatMap(AppVersion.init)
            guard Self.shouldNotify(version, notified: notified) else { return }
            defaults.set(version.description, forKey: Self.notifiedKey)
            if !userInitiated { onAlert?(Self.alert(for: newer)) }
        } catch {
            lastCheckFailed = true
            AppLog.write("새 버전 확인 실패: \(error.localizedDescription)")
        }
    }

    /// 이미 알린 버전과 같거나 그보다 낮으면 다시 알리지 않는다
    nonisolated static func shouldNotify(_ version: AppVersion, notified: AppVersion?) -> Bool {
        notified.map { version > $0 } ?? true
    }

    /// 노치 알림. 누르면 릴리스 페이지를 연다 (미리보기에서도 쓴다)
    nonisolated static func alert(for release: AppRelease) -> NotchAlert {
        NotchAlert(symbol: "arrow.down.circle.fill", tint: .green,
                   text: "새 버전 \(release.version?.description ?? release.tagName)", url: release.htmlURL)
    }

    nonisolated private static let session = URLSession(configuration: .ephemeral)

    /// 쿠키 · 캐시를 남기지 않는 요청. GitHub이 요구하는 User-Agent에는 앱 이름과 버전만 넣는다
    nonisolated static func download() async throws -> Data {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cheoma/\(AppVersion.bundle?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
        return data
    }

    #if DEBUG
    /// 미리보기 렌더링용: 새 버전이 있는 것처럼
    static func preview(available: AppRelease?) -> UpdateChecker {
        let checker = UpdateChecker(current: AppVersion("0.1.0"), defaults: UserDefaults(suiteName: "cheoma.preview") ?? .standard) {
            throw URLError(.notConnectedToInternet)
        }
        checker.available = available
        checker.lastChecked = Date().addingTimeInterval(-3 * 3600)
        return checker
    }

    static let sampleRelease = AppRelease(
        tagName: "v0.2.0", name: "Cheoma 0.2.0", body: """
        Coding agents in the notch.

        ---

        노치에서 코드 에이전트를 봅니다.

        ### 새로 들어간 것

        - **코드 에이전트 탭**: Claude Code · Codex · OpenCode · pi의 상태를 보고 답을 보냅니다
        - 구독 5시간 · 주간 한도 %
        - 따로 여는 설정 창 (⌘,)
        - 새 버전 알림
        """,
        htmlURL: URL(string: "https://github.com/m-kim77/cheoma/releases/tag/v0.2.0")!, draft: false, prerelease: false)
    #endif
}

import XCTest
@testable import Cheoma

final class AppVersionTests: XCTestCase {
    private func version(_ text: String) -> AppVersion { AppVersion(text)! }

    func testComparesNumbersNotText() {
        XCTAssertGreaterThan(version("0.10.0"), version("0.9.0"))
        XCTAssertGreaterThan(version("1.0.0"), version("0.99.99"))
        XCTAssertLessThan(version("0.1.0"), version("0.2.0"))
        XCTAssertLessThan(version("0.2.0"), version("0.2.1"))
    }

    func testReadsTagsAndMissingParts() {
        XCTAssertEqual(version("v0.2.0"), version("0.2.0"))
        XCTAssertEqual(version("0.2"), version("0.2.0"))
        XCTAssertGreaterThan(version("0.2.1"), version("0.2"))
        XCTAssertEqual(version("v0.2.0-beta").description, "0.2.0")
        XCTAssertEqual(version(" 1.2.3 ").parts, [1, 2, 3])
    }

    func testRejectsNonVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("0..1"))
        XCTAssertNil(AppVersion("0.2.x"))
    }
}

final class AppReleaseTests: XCTestCase {
    /// GitHub `releases/latest` 응답을 줄인 것 (쓰지 않는 칸도 섞어 둔다)
    static func json(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false, body: String = "Notes") -> Data {
        let object: [String: Any] = [
            "url": "https://api.github.com/repos/m-kim77/cheoma/releases/1",
            "html_url": "https://github.com/m-kim77/cheoma/releases/tag/\(tag)",
            "id": 1, "tag_name": tag, "name": "Cheoma \(tag)", "draft": draft, "prerelease": prerelease,
            "published_at": "2026-11-01T09:00:00Z", "assets": [["name": "Cheoma.zip", "size": 1234]], "body": body,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testDecodesGitHubResponse() throws {
        let release = try AppRelease.decode(Self.json())
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.version, AppVersion("0.2.0"))
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/m-kim77/cheoma/releases/tag/v0.2.0")
        XCTAssertEqual(release.body, "Notes")
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
    }

    func testRejectsBrokenResponse() {
        XCTAssertThrowsError(try AppRelease.decode(Data(#"{"message": "Not Found"}"#.utf8)))
        XCTAssertThrowsError(try AppRelease.decode(Data("<html>".utf8)))
    }

    func testOnlyNewerFinalReleases() throws {
        let current = AppVersion("0.1.0")!
        XCTAssertNotNil(try AppRelease.decode(Self.json()).newer(than: current))
        XCTAssertNil(try AppRelease.decode(Self.json(tag: "v0.1.0")).newer(than: current))
        XCTAssertNil(try AppRelease.decode(Self.json(tag: "v0.0.9")).newer(than: current))
        XCTAssertNil(try AppRelease.decode(Self.json(draft: true)).newer(than: current))
        XCTAssertNil(try AppRelease.decode(Self.json(prerelease: true)).newer(than: current))
        XCTAssertNil(try AppRelease.decode(Self.json(tag: "nightly")).newer(than: current))
    }

    func testSummaryPrefersKoreanSection() throws {
        let body = "Agents in the notch.\n\n### What's in it\n\n- Agents tab\n- Click **다시 설치** (Reinstall)\n\n---\n\n노치에서 에이전트를 봅니다.\n\n### 들어 있는 기능\n\n- **에이전트 탭**\n* 새 버전 알림\n\n---\n\nSHA-256: abc"
        let release = try AppRelease.decode(Self.json(body: body))
        XCTAssertEqual(release.summary(), "노치에서 에이전트를 봅니다.\n들어 있는 기능\n• **에이전트 탭**\n• 새 버전 알림")
        XCTAssertEqual(release.summary(maxLines: 1), "노치에서 에이전트를 봅니다.")
        // 한국어가 없으면 맨 앞 부분
        let english = try AppRelease.decode(Self.json(body: "Fixes.\r\n\r\n- One\r\n---\r\nSHA"))
        XCTAssertEqual(english.summary(), "Fixes.\n• One")
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "cheoma.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// 응답을 바꿔 가며 줄 수 있는 가짜 GitHub
    private final class FakeServer: @unchecked Sendable {
        var tag = "v0.2.0"
        var fails = false
    }

    private var logged: [String] = []

    private func checker(current: String = "0.1.0", server: FakeServer) -> UpdateChecker {
        UpdateChecker(current: AppVersion(current), defaults: defaults, log: { [weak self] in self?.logged.append($0) }) {
            if server.fails { throw URLError(.notConnectedToInternet) }
            return AppReleaseTests.json(tag: server.tag)
        }
    }

    func testAlertsOncePerVersion() async {
        let server = FakeServer()
        let updates = checker(server: server)
        var alerts: [NotchAlert] = []
        updates.onAlert = { alerts.append($0) }

        await updates.check()
        XCTAssertEqual(alerts.map(\.text), ["새 버전 0.2.0"])
        XCTAssertEqual(alerts.first?.url?.absoluteString, "https://github.com/m-kim77/cheoma/releases/tag/v0.2.0")
        XCTAssertEqual(updates.available?.tagName, "v0.2.0")

        // 같은 버전은 다시 알리지 않는다 (앱을 다시 켜도)
        await updates.check()
        let relaunched = checker(server: server)
        relaunched.onAlert = { alerts.append($0) }
        await relaunched.check()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertNotNil(relaunched.available)

        // 더 새 버전이 나오면 다시 알린다
        server.tag = "v0.3.0"
        await relaunched.check()
        XCTAssertEqual(alerts.map(\.text), ["새 버전 0.2.0", "새 버전 0.3.0"])
    }

    func testNoAlertWhenUpToDate() async {
        let server = FakeServer()
        let updates = checker(current: "0.2.0", server: server)
        var alerts = 0
        updates.onAlert = { _ in alerts += 1 }
        await updates.check()
        XCTAssertEqual(alerts, 0)
        XCTAssertNil(updates.available)
        XCTAssertNotNil(updates.lastChecked)
    }

    func testCheckingByHandMarksVersionWithoutAlert() async {
        let server = FakeServer()
        let updates = checker(server: server)
        var alerts = 0
        updates.onAlert = { _ in alerts += 1 }
        // 설정 창에서 직접 확인해서 본 버전은 노치로 다시 알리지 않는다
        await updates.check(userInitiated: true)
        await updates.check()
        XCTAssertEqual(alerts, 0)
        XCTAssertNotNil(updates.available)
    }

    func testNetworkErrorIsQuietAndRetried() async {
        let server = FakeServer()
        server.fails = true
        let updates = checker(server: server)
        var alerts = 0
        updates.onAlert = { _ in alerts += 1 }
        await updates.check()
        XCTAssertEqual(alerts, 0)
        XCTAssertTrue(updates.lastCheckFailed)
        XCTAssertEqual(logged.count, 1)
        // 실패하면 마지막 확인 시각을 남기지 않아서 다음 차례에 다시 확인한다
        XCTAssertNil(updates.lastChecked)

        server.fails = false
        await updates.check()
        XCTAssertFalse(updates.lastCheckFailed)
        XCTAssertEqual(alerts, 1)
    }

    func testDevelopmentBuildNeverChecks() async {
        let updates = UpdateChecker(current: nil, defaults: defaults, log: { _ in }) {
            XCTFail("개발 빌드에서 GitHub에 접속함")
            return Data()
        }
        await updates.check()
        XCTAssertNil(updates.lastChecked)
    }

    func testRememberedVersionRule() {
        let v020 = AppVersion("0.2.0")!
        XCTAssertTrue(UpdateChecker.shouldNotify(v020, notified: nil))
        XCTAssertTrue(UpdateChecker.shouldNotify(v020, notified: AppVersion("0.1.5")))
        XCTAssertFalse(UpdateChecker.shouldNotify(v020, notified: AppVersion("0.2")))
        XCTAssertFalse(UpdateChecker.shouldNotify(v020, notified: AppVersion("0.3.0")))
    }
}

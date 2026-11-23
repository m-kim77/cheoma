import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Cheoma

// 붙여넣기는 키 이벤트를 보내거나 메뉴를 누르지 않고 확인한다. 클립보드는 이 테스트만 쓰는 이름 붙은 클립보드를 쓴다

final class DictationPlannerTests: XCTestCase {
    private func route(_ method: DictationPasteMethod, own: Bool = false, secureInput: Bool = false, secureField: Bool = false,
                       kind: DictationAppKind = .native, menu: Bool = true) -> DictationInsertionRoute? {
        DictationInsertionPlanner.route(method: method, ownPanelIsKey: own, isSecureInput: secureInput,
                                        focusedIsSecureField: secureField, appKind: kind, menuPasteAvailable: menu)
    }

    func testOwnPanelComesFirst() {
        for method in DictationPasteMethod.allCases {
            XCTAssertEqual(route(method, own: true), .ownPanel)
            XCTAssertEqual(route(method, own: true, secureInput: true, secureField: true, kind: .electron), .ownPanel)
        }
    }

    func testRefusesSecureInputAndPasswordFields() {
        for method in DictationPasteMethod.allCases {
            for kind in [DictationAppKind.native, .chromium, .electron] {
                XCTAssertNil(route(method, secureInput: true, kind: kind))
                XCTAssertNil(route(method, secureField: true, kind: kind))
            }
        }
    }

    /// 보안 입력은 시스템 전체 상태다. 켠 앱이 붙여 넣을 앱이거나 누군지 모를 때만 막는다
    func testSecureInputBlocksOnlyItsHolder() {
        XCTAssertFalse(DictationFocus.secureInputBlocks(isEnabled: false, holder: 10, target: 10))
        XCTAssertTrue(DictationFocus.secureInputBlocks(isEnabled: true, holder: 10, target: 10))
        XCTAssertFalse(DictationFocus.secureInputBlocks(isEnabled: true, holder: 10, target: 20))
        XCTAssertTrue(DictationFocus.secureInputBlocks(isEnabled: true, holder: nil, target: 20))
        XCTAssertTrue(DictationFocus.secureInputBlocks(isEnabled: true, holder: 10, target: nil))
        // 뒤에 있는 앱이 켜 둔 보안 입력은 붙여 넣기를 막지 않는다
        let blocks = DictationFocus.secureInputBlocks(isEnabled: true, holder: 10, target: 20)
        XCTAssertEqual(route(.automatic, secureInput: blocks), .commandV)
    }

    func testSecureReasonNamesHolder() {
        XCTAssertEqual(DictationTextInserter.secureReason(isSecureField: true, holder: nil), "암호 필드여서 클립보드에만 복사했습니다")
        XCTAssertEqual(DictationTextInserter.secureReason(isSecureField: false, holder: nil), "보안 입력이 켜져 있어 클립보드에만 복사했습니다")
        // 자기 자신(테스트 프로세스)은 이름을 대지 않는다
        let own = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(DictationTextInserter.secureReason(isSecureField: false, holder: own), "보안 입력이 켜져 있어 클립보드에만 복사했습니다")
        XCTAssertEqual(DictationController.shortCopiedReason("iTerm2의 보안 입력이 켜져 있어 클립보드에만 복사했습니다"),
                       "보안 입력 · 복사만 됨")
    }

    func testClipboardOnly() {
        for kind in [DictationAppKind.native, .chromium, .electron] {
            XCTAssertEqual(route(.clipboardOnly, kind: kind), .clipboardOnly)
            XCTAssertEqual(route(.clipboardOnly, kind: kind, menu: false), .clipboardOnly)
        }
    }

    func testMenuMethodFallsBackToCommandV() {
        for kind in [DictationAppKind.native, .chromium, .electron] {
            XCTAssertEqual(route(.menu, kind: kind), .menuPaste)
            XCTAssertEqual(route(.menu, kind: kind, menu: false), .commandV)
        }
    }

    func testAutomaticUsesMenuOnlyForChromiumAndElectron() {
        XCTAssertEqual(route(.automatic, kind: .native), .commandV)
        XCTAssertEqual(route(.automatic, kind: .native, menu: false), .commandV)
        XCTAssertEqual(route(.automatic, kind: .chromium), .menuPaste)
        XCTAssertEqual(route(.automatic, kind: .electron), .menuPaste)
        XCTAssertEqual(route(.automatic, kind: .chromium, menu: false), .commandV)
        XCTAssertEqual(route(.automatic, kind: .electron, menu: false), .commandV)
    }

    func testLooksUpMenuOnlyWhenItCouldBeUsed() {
        XCTAssertTrue(DictationInsertionPlanner.needsMenuLookup(method: .menu, appKind: .native))
        XCTAssertFalse(DictationInsertionPlanner.needsMenuLookup(method: .automatic, appKind: .native))
        XCTAssertTrue(DictationInsertionPlanner.needsMenuLookup(method: .automatic, appKind: .chromium))
        XCTAssertTrue(DictationInsertionPlanner.needsMenuLookup(method: .automatic, appKind: .electron))
        XCTAssertFalse(DictationInsertionPlanner.needsMenuLookup(method: .clipboardOnly, appKind: .electron))
    }

    func testMenuSearchStartsAtEditMenuAndSkipsAppleMenu() {
        XCTAssertEqual(DictationMenuPaste.searchOrder(count: 8), [3, 2, 4, 1, 5, 6, 7])
        XCTAssertEqual(DictationMenuPaste.searchOrder(count: 3), [2, 1])
        XCTAssertEqual(DictationMenuPaste.searchOrder(count: 1), [])
        XCTAssertEqual(DictationMenuPaste.searchOrder(count: 0), [])
    }
}

final class DictationAppKindTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CheomaAppKind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 가짜 앱 묶음. files는 Contents 아래 경로 (빈 파일), folders는 Contents 아래 폴더
    private func makeBundle(_ name: String, folders: [String] = [], files: [String] = []) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in files {
            let url = contents.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        return bundle
    }

    func testElectronFramework() throws {
        let bundle = try makeBundle("Claude", folders: ["Frameworks/Electron Framework.framework/Resources", "Frameworks/Squirrel.framework"],
                                    files: ["Resources/app.asar"])
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: "com.anthropic.claudefordesktop"), .electron)
    }

    func testRenamedElectronFramework() throws {
        let bundle = try makeBundle("ChatGPT", files: ["Frameworks/Codex Framework.framework/Resources/icudtl.dat", "Resources/app.asar"])
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: "com.openai.codex"), .electron)
    }

    func testChromiumByFrameworkName() throws {
        let bundle = try makeBundle("Brave Browser", folders: ["Frameworks/Brave Browser Framework.framework"])
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: "com.example.unknown"), .chromium)
    }

    func testChromiumByFrameworkResources() throws {
        let bundle = try makeBundle("Some Browser", files: [
            "Frameworks/Some Browser Framework.framework/Versions/Current/Resources/chrome_100_percent.pak",
        ])
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: nil), .chromium)
    }

    func testNativeAppsWithOtherFrameworks() throws {
        let bundle = try makeBundle("Word", folders: [
            "Frameworks/Sparkle.framework/Resources",
            "Frameworks/OutlookRightsFramework.framework/Resources",
            "Frameworks/Plain Framework.framework/Resources",
        ], files: ["Resources/app.asar"])
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: "com.microsoft.Word"), .native)
        let empty = try makeBundle("TextEdit")
        XCTAssertEqual(DictationAppKind.detect(bundleURL: empty, bundleIdentifier: "com.apple.TextEdit"), .native)
    }

    func testChromiumByBundleIdentifier() {
        for identifier in ["com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.app.abcdef", "com.brave.Browser.beta",
                           "company.thebrowser.Browser", "company.thebrowser.dia", "com.operasoftware.OperaGX", "com.microsoft.edgemac"] {
            XCTAssertEqual(DictationAppKind.detect(bundleURL: nil, bundleIdentifier: identifier), .chromium, identifier)
        }
        for identifier in ["com.apple.Safari", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.mitchellh.ghostty"] {
            XCTAssertEqual(DictationAppKind.detect(bundleURL: nil, bundleIdentifier: identifier), .native, identifier)
        }
        XCTAssertEqual(DictationAppKind.detect(bundleURL: nil, bundleIdentifier: nil), .native)
    }

    func testRemembersKindPerBundlePath() throws {
        let bundle = try makeBundle("Changing")
        XCTAssertEqual(DictationAppKind.of(bundleURL: bundle, bundleIdentifier: nil), .native)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(DictationAppKind.of(bundleURL: bundle, bundleIdentifier: nil), .native)
        XCTAssertEqual(DictationAppKind.detect(bundleURL: bundle, bundleIdentifier: nil), .electron)
        let other = try makeBundle("Other", folders: ["Frameworks/Electron Framework.framework"])
        XCTAssertEqual(DictationAppKind.of(bundleURL: other, bundleIdentifier: nil), .electron)
    }
}

final class DictationPasteKeyTests: XCTestCase {
    private func layoutData(_ identifier: String) throws -> Data {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first, let data = DictationPasteKey.layoutData(of: source) else {
            throw XCTSkip("\(identifier) 자판이 없어요")
        }
        return data
    }

    private func key(_ identifier: String) throws -> CGKeyCode {
        DictationPasteKey.resolve(layoutData: try layoutData(identifier), keyboardType: UInt32(LMGetKbdType()))
    }

    func testUSLayoutUsesKeyNine() throws {
        XCTAssertEqual(try key("com.apple.keylayout.US"), 9)
        XCTAssertEqual(try key("com.apple.keylayout.US"), CGKeyCode(kVK_ANSI_V))
    }

    func testOtherLayouts() throws {
        XCTAssertEqual(try key("com.apple.keylayout.2SetHangul"), 9)
        XCTAssertEqual(try key("com.apple.keylayout.Colemak"), 9)
        // 드보락은 V가 QWERTY의 마침표 자리에 있다. ⌘를 누르면 QWERTY가 되는 드보락은 9번 그대로
        XCTAssertEqual(try key("com.apple.keylayout.Dvorak"), CGKeyCode(kVK_ANSI_Period))
        XCTAssertEqual(try key("com.apple.keylayout.DVORAK-QWERTYCMD"), 9)
    }

    func testFallsBackToKeyNine() {
        XCTAssertEqual(DictationPasteKey.resolve(layoutData: nil, keyboardType: 0), 9)
        XCTAssertEqual(DictationPasteKey.resolve(layoutData: Data(), keyboardType: 0), 9)
    }

    @MainActor
    func testCurrentLayoutGivesAKey() {
        XCTAssertLessThan(DictationPasteKey.current(), 128)
    }
}

/// 이어 받아쓸 때 앞 글과 붙지 않게 빈칸을 넣는다
final class DictationSpacingTests: XCTestCase {
    private func space(_ text: String, _ caret: DictationCaret, recent: Bool = false) -> Bool {
        DictationSpacing.needsLeadingSpace(text, caret: caret, continuesRecent: recent)
    }

    func testSpaceAfterWordsAndSentenceEnds() {
        XCTAssertTrue(space("테스트도 통과했어요.", .after(".")))
        XCTAssertTrue(space("다음은 배포예요", .after("요")))
        XCTAssertTrue(space("next", .after("d")))
        XCTAssertTrue(space("그리고", .after(")")))
    }

    func testNoSpaceAtStartAfterSpaceOrOpeningBracket() {
        XCTAssertFalse(space("첫 말", .atStart, recent: true))
        XCTAssertFalse(space("말", .after(" ")))
        XCTAssertFalse(space("말", .after("\n")))
        XCTAssertFalse(space("말", .after("(")))
        XCTAssertFalse(space("말", .after("“")))
        // 이미 빈칸으로 시작하거나 문장 부호로 시작하는 글
        XCTAssertFalse(space(" 말", .after("요")))
        XCTAssertFalse(space(", 그리고", .after("요")))
        XCTAssertFalse(space("", .after("요")))
    }

    /// 커서 앞을 모르거나 테두리 기호(터미널)면 같은 앱에 방금 넣은 받아쓰기에 이어 말할 때만
    func testUnknownCaretUsesRecentDictation() {
        XCTAssertFalse(space("말", .unknown))
        XCTAssertTrue(space("말", .unknown, recent: true))
        XCTAssertFalse(space("말", .after("│")))
        XCTAssertTrue(space("말", .after("│"), recent: true))
    }

    /// 같은 앱에 방금 넣은 받아쓰기에 이어 말하는지: 그 뒤로 키를 쳤으면(⏎로 보냄 등) 아니다
    func testContinuesRecentOnlyWithoutTypingSince() {
        let start = Date(timeIntervalSince1970: 1_000)
        let last = DictationLastInsertion(pid: 42, date: start, endsWithSpace: false)
        let soon = start.addingTimeInterval(5)
        XCTAssertTrue(DictationSpacing.continuesRecent(last, pid: 42, now: soon, lastTyped: nil))
        XCTAssertTrue(DictationSpacing.continuesRecent(last, pid: 42, now: soon, lastTyped: start.addingTimeInterval(-1)))
        XCTAssertFalse(DictationSpacing.continuesRecent(last, pid: 42, now: soon, lastTyped: start.addingTimeInterval(1)))
        XCTAssertFalse(DictationSpacing.continuesRecent(last, pid: 7, now: soon, lastTyped: nil))
        XCTAssertFalse(DictationSpacing.continuesRecent(last, pid: nil, now: soon, lastTyped: nil))
        XCTAssertFalse(DictationSpacing.continuesRecent(nil, pid: 42, now: soon, lastTyped: nil))
        XCTAssertFalse(DictationSpacing.continuesRecent(last, pid: 42, now: start.addingTimeInterval(31), lastTyped: nil))
        var spaced = last
        spaced.endsWithSpace = true
        XCTAssertFalse(DictationSpacing.continuesRecent(spaced, pid: 42, now: soon, lastTyped: nil))
        // 커서 앞을 모르면 그대로 빈칸 여부가 된다
        XCTAssertFalse(space("다음은 QA예요", .unknown,
                             recent: DictationSpacing.continuesRecent(last, pid: 42, now: soon, lastTyped: soon)))
    }

    func testLanguagesWithoutSpaces() {
        XCTAssertTrue(DictationSpacing.separatesWords(localeIdentifier: "ko-KR"))
        XCTAssertTrue(DictationSpacing.separatesWords(localeIdentifier: "en-US"))
        XCTAssertFalse(DictationSpacing.separatesWords(localeIdentifier: "ja-JP"))
        XCTAssertFalse(DictationSpacing.separatesWords(localeIdentifier: "zh-Hans"))
    }
}

@MainActor
final class DictationClipboardTests: XCTestCase {
    private let customType = NSPasteboard.PasteboardType("io.github.m-kim77.cheoma.test.custom")

    /// 테스트마다 새 이름의 클립보드. 끝나면 releaseGlobally()로 돌려준다
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("io.github.m-kim77.cheoma.test.\(UUID().uuidString)"))
    }

    private func makeClipboard(_ pasteboard: NSPasteboard, readable: Bool = true) -> DictationClipboard {
        let clipboard = DictationClipboard(pasteboard: pasteboard)
        clipboard.readsContentsOverride = readable
        clipboard.restoreDelay = .milliseconds(20)
        return clipboard
    }

    private func putOriginal(on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("원래 글", forType: .string)
        first.setData(Data([1, 2, 3]), forType: customType)
        let second = NSPasteboardItem()
        second.setString("둘째 항목", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
    }

    private func assertOriginal(on pasteboard: NSPasteboard, file: StaticString = #filePath, line: UInt = #line) {
        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2, file: file, line: line)
        XCTAssertEqual(items.first?.string(forType: .string), "원래 글", file: file, line: line)
        XCTAssertEqual(items.first?.data(forType: customType), Data([1, 2, 3]), file: file, line: line)
        XCTAssertEqual(items.last?.string(forType: .string), "둘째 항목", file: file, line: line)
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.transientType) ?? true, file: file, line: line)
    }

    func testMarksTextTransientWhenItWillBeRestored() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(DictationClipboard.transientType))
        XCTAssertTrue(types.contains(DictationClipboard.autoGeneratedType))
    }

    func testRestoresEveryOriginalItemAfterPaste() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        await clipboard.restoreTask?.value
        assertOriginal(on: pasteboard)
    }

    func testLeavesWhatWasCopiedMeanwhile() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        // 되돌리기 전에 사용자가 다른 것을 복사했다
        pasteboard.clearContents()
        pasteboard.setString("새로 복사한 글", forType: .string)
        await clipboard.restoreTask?.value
        XCTAssertEqual(pasteboard.string(forType: .string), "새로 복사한 글")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testKeepsTextWhenReadingIsNotAllowed() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard, readable: false)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.transientType) ?? true)
        clipboard.scheduleRestore()
        XCTAssertNil(clipboard.restoreTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
    }

    /// macOS 15.4부터: 한 번도 읽으려 한 적이 없거나(목록에도 없음) 매번 묻게 되어 있으면 떠 두지 않는다
    func testKeepsTextUnlessReadingIsAlwaysAllowed() async {
        for access in [DictationClipboardAccess.notAsked, .asks, .denied] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            putOriginal(on: pasteboard)
            let clipboard = DictationClipboard(pasteboard: pasteboard)
            clipboard.accessProvider = { access }
            XCTAssertFalse(clipboard.mayReadContents)
            XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
            clipboard.scheduleRestore()
            XCTAssertNil(clipboard.restoreTask, "\(access)")
            XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        }
        let allowed = DictationClipboard(pasteboard: makePasteboard())
        defer { allowed.pasteboard.releaseGlobally() }
        allowed.accessProvider = { .allowed }
        XCTAssertTrue(allowed.mayReadContents)
    }

    /// 암호 관리 앱이 복사한 것은 되돌리지 않는다 (되돌리면 스스로 지우지 못한다)
    func testDoesNotRestoreSecrets() async {
        for marker in [DictationClipboard.concealedType, DictationClipboard.transientType] {
            let pasteboard = makePasteboard()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("비밀번호", forType: .string)
            item.setData(Data(), forType: marker)
            XCTAssertTrue(pasteboard.writeObjects([item]))
            let clipboard = makeClipboard(pasteboard)
            XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
            clipboard.scheduleRestore()
            XCTAssertNil(clipboard.restoreTask)
            XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        }
    }

    /// 글 · 서식과 그림 · PDF가 섞인 것(Office · iWork 개체)은 만드는 데 오래 걸려서 떠 두지 않는다. 너무 큰 것도
    func testDoesNotSnapshotRichMixesOrLargeContents() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("표", forType: .string)
        item.setData(Data("{\\rtf1 표}".utf8), forType: .rtf)
        item.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        XCTAssertNil(clipboard.restoreTask)

        putOriginal(on: pasteboard)
        XCTAssertNil(clipboard.snapshot(maximumBytes: 8))
        XCTAssertNotNil(clipboard.snapshot())
        XCTAssertTrue(DictationClipboard.isRestorable(types: [.string, .rtf]))
        XCTAssertFalse(DictationClipboard.isRestorable(types: [.init("com.apple.pasteboard.promised-file-url")]))
    }

    /// 그림 · PDF 형식은 가려 뜬다: 그림만 있으면 하나만, 파일 복사면 Finder 아이콘을 빼고, 섞인 것은 뜨지 않는다
    func testSnapshotTypesPickImagesCarefully() {
        let icns = NSPasteboard.PasteboardType("com.apple.icns")
        let source = DictationClipboard.sourceType
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.string, .rtf]), [.string, .rtf])
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.png]), [.png])
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.tiff, .png]), [.png])
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.tiff, .init("NeXT TIFF v4.0 pasteboard type")]), [.tiff])
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.png, source]), [.png, source])
        XCTAssertEqual(DictationClipboard.snapshotTypes(of: [.fileURL, icns, .string]), [.fileURL, .string])
        XCTAssertNil(DictationClipboard.snapshotTypes(of: [.string, .rtf, .tiff]))
        XCTAssertNil(DictationClipboard.snapshotTypes(of: [.string, .pdf]))
        XCTAssertTrue(DictationClipboard.isVisual(icns))
        XCTAssertTrue(DictationClipboard.isVisual(.init("Apple PDF pasteboard type")))
        XCTAssertFalse(DictationClipboard.isVisual(.fileURL))
    }

    /// 화면 캡처(그림만)는 그대로 되돌린다
    func testRestoresScreenshot() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        XCTAssertTrue(clipboard.willRestore)
        clipboard.scheduleRestore()
        await clipboard.restoreTask?.value
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    /// Finder에서 복사한 파일은 파일 주소로 되돌린다 (Finder가 붙인 아이콘은 빼고)
    func testRestoresFileCopyWithoutIcon() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let icns = NSPasteboard.PasteboardType("com.apple.icns")
        let item = NSPasteboardItem()
        item.setString("file:///tmp/report.txt", forType: .fileURL)
        item.setString("report.txt", forType: .string)
        item.setData(Data([0x69, 0x63, 0x6E, 0x73]), forType: icns)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        await clipboard.restoreTask?.value
        let restored = pasteboard.pasteboardItems?.first
        XCTAssertEqual(restored?.string(forType: .fileURL), "file:///tmp/report.txt")
        XCTAssertEqual(restored?.string(forType: .string), "report.txt")
        XCTAssertFalse(restored?.types.contains(icns) ?? true)
    }

    /// 앱이 바쁘거나 글 칸이 아니라 되돌리지 않을 글은 처음부터 보통 항목으로 쓴다 (클립보드 관리 앱이 기록하게)
    func testKeptTextIsNotMarkedTransient() {
        var settings = DictationSettings()
        settings.restoresClipboard = true
        XCTAssertTrue(DictationTextInserter.restoresClipboard(settings: settings, focus: DictationFocusedElement()))
        XCTAssertFalse(DictationTextInserter.restoresClipboard(settings: settings,
                                                               focus: DictationFocusedElement(isSlow: true)))
        XCTAssertFalse(DictationTextInserter.restoresClipboard(settings: settings,
                                                               focus: DictationFocusedElement(acceptsText: false)))
        settings.restoresClipboard = false
        XCTAssertFalse(DictationTextInserter.restoresClipboard(settings: settings, focus: DictationFocusedElement()))

        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: false))
        XCTAssertFalse(clipboard.willRestore)
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.transientType) ?? true)
    }

    /// macOS 15.4~15는 읽어도 묻지 않아 .default가 그대로다 (그때는 읽어도 된다). macOS 26부터는 아직 묻지 않은 것
    func testAccessBehaviorMapping() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("macOS 15.4 전에는 묻지 않는다") }
        XCTAssertEqual(DictationClipboard.access(behavior: .default, alertsOnRead: true), .notAsked)
        XCTAssertEqual(DictationClipboard.access(behavior: .default, alertsOnRead: false), .allowed)
        XCTAssertEqual(DictationClipboard.access(behavior: .alwaysAllow, alertsOnRead: true), .allowed)
        XCTAssertEqual(DictationClipboard.access(behavior: .alwaysDeny, alertsOnRead: false), .denied)
        XCTAssertEqual(DictationClipboard.access(behavior: .ask, alertsOnRead: true), .asks)
    }

    /// 암호 칸에 말한 글: 클립보드 관리 앱이 기록하지 않게 표시하고 되돌리지 않는다
    func testConcealedCopyIsMarked() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeToKeep("말한 비밀번호", concealed: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "말한 비밀번호")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(DictationClipboard.concealedType))
        XCTAssertFalse(types.contains(DictationClipboard.transientType))
        XCTAssertNil(clipboard.restoreTask)
        XCTAssertTrue(clipboard.writeToKeep("보통 글"))
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.concealedType) ?? true)
    }

    func testKeepsTextWhenRestoringIsOff() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: false))
        clipboard.scheduleRestore()
        XCTAssertNil(clipboard.restoreTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.transientType) ?? true)
    }

    func testBackToBackPastesRestoreTheFirstOriginal() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        clipboard.restoreDelay = .seconds(30)
        XCTAssertTrue(clipboard.writeForPaste("첫째", restoring: true))
        clipboard.scheduleRestore()
        // 되돌리기 전에 다음 받아쓰기가 온다. "첫째"를 원래 내용으로 떠 두면 안 된다
        clipboard.restoreDelay = .milliseconds(20)
        XCTAssertTrue(clipboard.writeForPaste("둘째", restoring: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "둘째")
        clipboard.scheduleRestore()
        await clipboard.restoreTask?.value
        assertOriginal(on: pasteboard)
    }

    func testKeptTextDropsPendingRestore() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let clipboard = makeClipboard(pasteboard)
        clipboard.restoreDelay = .seconds(30)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        XCTAssertTrue(clipboard.writeToKeep("남길 글"))
        XCTAssertNil(clipboard.restoreTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "남길 글")
        XCTAssertFalse(pasteboard.types?.contains(DictationClipboard.transientType) ?? true)
        clipboard.scheduleRestore()
        XCTAssertNil(clipboard.restoreTask)
    }

    func testEmptyClipboardIsRestoredEmpty() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let clipboard = makeClipboard(pasteboard)
        XCTAssertTrue(clipboard.writeForPaste("받아쓴 글", restoring: true))
        clipboard.scheduleRestore()
        await clipboard.restoreTask?.value
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
    }

    func testSnapshotKeepsEveryType() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let snapshot = try XCTUnwrap(makeClipboard(pasteboard).snapshot())
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.items[0].contains(.init(type: customType, data: Data([1, 2, 3]))))
        XCTAssertTrue(snapshot.items[0].contains { $0.type == .string })
    }

    func testInserterLeavesTextOnClipboardWhenAskedTo() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        putOriginal(on: pasteboard)
        let inserter = DictationTextInserter(pasteboard: pasteboard)
        var settings = DictationSettings()
        settings.pasteMethod = .clipboardOnly
        let result = await inserter.insert("받아쓴 글", settings: settings, ownPanelIsKey: false)
        // 이 맥에서 보안 입력이 켜져 있으면 이유와 함께 클립보드에만 넣는다. 어느 쪽이든 글은 남는다
        switch result {
        case .inserted(.clipboardOnly), .copiedOnly: break
        default: XCTFail("\(result)")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "받아쓴 글")
        XCTAssertNil(inserter.clipboard.restoreTask)
        let empty = await inserter.insert("", settings: settings, ownPanelIsKey: false)
        XCTAssertEqual(empty, .failed("입력할 텍스트 없음"))
    }
}

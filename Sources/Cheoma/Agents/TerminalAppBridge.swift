import AppKit

/// Terminal.app 탭 하나
struct TerminalAppTab: Hashable, Sendable {
    var tty: String
    /// Terminal 창 ID (AppleScript `id of window`)
    var windowID: Int
    /// 창 안에서 탭 순서 (1부터)
    var tabIndex: Int
    var title: String?
    var isBusy: Bool
    /// 탭에서 도는 프로세스 이름들 (AppleScript `processes of tab`)
    var processes: [String]
}

/// Terminal.app이 처음 Apple Event를 받을 때 macOS가 묻는 "자동화" 권한
enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    /// 아직 묻지 않음
    case notDetermined
    /// Terminal이 꺼져 있어서 알 수 없음
    case targetNotRunning
}

/// Terminal.app 연동 (AppleScript).
/// NSAppleScript는 메인 스레드에서만 써야 해서, 백그라운드 큐에서 부르는 이 연동은 /usr/bin/osascript를 따로 띄운다.
/// osascript가 보내는 Apple Event도 macOS는 띄운 앱(Cheoma)이 보낸 것으로 보고 Cheoma의 자동화 권한을 쓴다.
/// Terminal이 꺼져 있으면 `tell application`이 Terminal을 켜 버리므로, 새 창을 여는 openTab 말고는 먼저 켜져 있는지 본다
final class TerminalAppBridge: TerminalBridge, Sendable {
    static let shared = TerminalAppBridge()
    static let bundleIdentifier = "com.apple.Terminal"

    /// osascript 하나를 기다리는 시간. Terminal이 바쁘거나 멈췄을 때 연동 큐가 오래 막히지 않게
    private static let timeout: TimeInterval = 3

    /// Terminal.app이 켜져 있는지 (Apple Event 없이)
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// 자동화 권한 상태. askIfNeeded가 true면 아직 안 물었을 때 macOS가 사용자에게 묻는다 (답할 때까지 막힌다)
    func permission(askIfNeeded: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
        guard let address = target.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askIfNeeded)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied                // -1743
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined  // -1744
        case OSStatus(procNotFound): return .targetNotRunning               // -600
        default: return .notDetermined
        }
    }

    /// 모든 창의 탭 목록
    func tabs() throws -> [TerminalAppTab] {
        try requireRunning()
        return TerminalAppScript.parseTabs(try run(TerminalAppScript.tabs()))
    }

    /// 새 창을 열고 폴더에서 명령을 실행한다 (Terminal의 AppleScript에는 새 탭 명령이 없다). 새 에이전트 실행, tmux 세션 열기에 쓴다.
    /// Terminal이 꺼져 있으면 켠다
    func openTab(command: String, in folder: String?) throws {
        // Terminal을 켜는 데 3초보다 오래 걸릴 수 있다
        _ = try run(TerminalAppScript.openWindow(command: TerminalAppScript.shellCommand(command, in: folder)), timeout: 10)
    }

    func capture(_ location: TerminalLocation) throws -> TerminalScreen {
        let tty = try Self.tty(of: location)
        try requireRunning()
        let output = try run(TerminalAppScript.capture(tty: tty))
        return TerminalScreen(text: TerminalAppScript.screenText(output), capturedAt: Date())
    }

    /// 그 탭에 `do script`로 글자를 친다. do script는 늘 Return까지 누르므로 pressEnter와 상관없이 Enter가 같이 간다.
    /// 여러 줄은 한 줄로 합친다 (줄바꿈이 중간에 Enter로 들어가지 않게)
    func send(text: String, pressEnter: Bool, to location: TerminalLocation) throws {
        let tty = try Self.tty(of: location)
        try requireRunning()
        _ = try run(TerminalAppScript.send(text: text, tty: tty))
    }

    func send(key: TerminalKey, to location: TerminalLocation) throws {
        throw AgentBridgeError(message: "Terminal 탭에는 특수 키를 보낼 수 없어요. tmux 세션에서는 돼요")
    }

    /// 그 탭을 고르고 창을 맨 앞으로 가져온 뒤 Terminal을 앞으로 띄운다
    func reveal(_ location: TerminalLocation) throws {
        let tty = try Self.tty(of: location)
        try requireRunning()
        _ = try run(TerminalAppScript.reveal(tty: tty))
    }

    // MARK: - 실행

    private func requireRunning() throws {
        guard isRunning else { throw AgentBridgeError(message: TerminalAppScript.Message.notRunning) }
    }

    private static func tty(of location: TerminalLocation) throws -> String {
        guard case .terminalApp(let tty) = location else {
            throw AgentBridgeError(message: "Terminal 탭이 아니에요")
        }
        return tty
    }

    /// 스크립트를 osascript로 돌리고 결과 글자(마지막 줄바꿈 제외)를 돌려준다
    private func run(_ script: String, timeout: TimeInterval = TerminalAppBridge.timeout) throws -> String {
        let result: AgentCommandRunner.Result
        do {
            // 스크립트는 표준 입력으로 넘긴다 (인자 길이 제한, 따옴표 문제 없이)
            result = try AgentCommandRunner.run("/usr/bin/osascript", [], input: script, timeout: timeout)
        } catch {
            throw AgentBridgeError(message: "osascript를 실행하지 못했어요: \(error.localizedDescription)")
        }
        if result.timedOut { throw AgentBridgeError(message: TerminalAppScript.Message.timeout) }
        guard result.status == 0 else {
            AppLog.write("Terminal 연동 실패: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            throw AgentBridgeError(message: TerminalAppScript.message(forError: result.error))
        }
        var output = result.output
        if output.hasSuffix("\n") { output.removeLast() }
        return try TerminalAppScript.checkSentinel(output)
    }
}

/// Terminal에 보낼 AppleScript 만들기와 결과 읽기. Apple Event 없이 확인할 수 있게 순수 함수로 뺐다 (`--agents --selftest`)
enum TerminalAppScript {
    enum Message {
        static let denied = "Terminal을 제어할 권한이 없어요. 시스템 설정 › 개인정보 보호 및 보안 › 자동화에서 Cheoma의 Terminal을 켜 주세요"
        static let notRunning = "Terminal이 꺼져 있어요"
        static let tabMissing = "그 Terminal 탭을 찾지 못했어요"
        static let timeout = "Terminal이 응답하지 않아요"
    }

    /// 스크립트가 결과 앞에 붙이는 표시. 탭을 못 찾았거나 Terminal이 꺼져 있으면 오류 대신 이 글자를 돌려준다
    static let okMark = "CHEOMA_OK:"
    static let noTabMark = "CHEOMA_NO_TAB"
    static let notRunningMark = "CHEOMA_NOT_RUNNING"

    /// 탭 목록에서 칸 · 줄 · 프로세스 이름을 나누는 글자 (탭 제목이나 프로세스 이름에 나올 일이 없는 제어 문자)
    static let unitSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"
    static let groupSeparator: Character = "\u{1D}"

    /// AppleScript 문자열 안에 넣을 수 있게 \ 와 " 를 이스케이프한다 (따옴표는 붙이지 않는다)
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// do script로 보낼 한 줄. 줄바꿈은 공백으로 바꾼다 (Terminal은 줄바꿈마다 Enter를 친다)
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// 폴더로 옮긴 뒤 명령을 실행하는 셸 명령
    static func shellCommand(_ command: String, in folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return command }
        return "cd \(AgentCommandRunner.shellQuoted(folder)) && \(command)"
    }

    // 모든 스크립트는 Terminal이 꺼져 있으면 켜지 않고 표시만 돌려준다 (`is running`은 Apple Event를 보내지 않는다).
    // 창 목록은 id로 다시 찾는다: 창 순서(index)는 앞으로 나온 창에 따라 바뀌어서 도는 사이에 엇갈릴 수 있다
    private static let prologue = """
    if application id "com.apple.Terminal" is not running then return "\(notRunningMark)"
    """

    /// tty가 같은 탭을 찾아 `body`를 실행한다. body 안에서 그 탭은 `tab i of w`
    private static func findTab(tty: String, body: String) -> String {
        """
        \(prologue)
        set targetTTY to "\(escaped(tty))"
        tell application id "com.apple.Terminal"
        \tset windowIDs to id of every window
        \trepeat with k from 1 to count of windowIDs
        \t\tset w to window id (item k of windowIDs)
        \t\tset tabCount to 0
        \t\ttry
        \t\t\tset tabCount to count of tabs of w
        \t\tend try
        \t\trepeat with i from 1 to tabCount
        \t\t\tif (tty of tab i of w) is targetTTY then
        \(body.split(separator: "\n", omittingEmptySubsequences: false).map { "\t\t\t\t" + $0 }.joined(separator: "\n"))
        \t\t\tend if
        \t\tend repeat
        \tend repeat
        end tell
        return "\(noTabMark)"
        """
    }

    /// 모든 탭: 창 ID · 탭 순서 · tty · busy · 제목 · 프로세스(그룹 구분자로 이음)
    static func tabs() -> String {
        """
        \(prologue)
        set us to character id 31
        set rs to character id 30
        set gs to character id 29
        set out to ""
        tell application id "com.apple.Terminal"
        \tset windowIDs to id of every window
        \trepeat with k from 1 to count of windowIDs
        \t\tset wid to item k of windowIDs
        \t\tset w to window id wid
        \t\tset tabCount to 0
        \t\ttry
        \t\t\tset tabCount to count of tabs of w
        \t\tend try
        \t\trepeat with i from 1 to tabCount
        \t\t\tset t to tab i of w
        \t\t\tset ttyText to ""
        \t\t\ttry
        \t\t\t\tset ttyText to (tty of t) as text
        \t\t\tend try
        \t\t\tset busyText to "false"
        \t\t\ttry
        \t\t\t\tif busy of t then set busyText to "true"
        \t\t\tend try
        \t\t\tset titleText to ""
        \t\t\ttry
        \t\t\t\tset titleValue to custom title of t
        \t\t\t\tif titleValue is not missing value then set titleText to titleValue as text
        \t\t\tend try
        \t\t\tset processText to ""
        \t\t\ttry
        \t\t\t\tset processList to processes of t
        \t\t\t\tset AppleScript's text item delimiters to gs
        \t\t\t\tset processText to processList as text
        \t\t\t\tset AppleScript's text item delimiters to ""
        \t\t\tend try
        \t\t\tset out to out & (wid as text) & us & (i as text) & us & ttyText & us & busyText & us & titleText & us & processText & rs
        \t\tend repeat
        \tend repeat
        end tell
        return "\(okMark)" & out
        """
    }

    /// 그 탭에 보이는 글자
    static func capture(tty: String) -> String {
        findTab(tty: tty, body: "return \"\(okMark)\" & (contents of tab i of w)")
    }

    /// 그 탭에 글자를 치고 Return을 누른다 (do script는 늘 Return까지 친다)
    static func send(text: String, tty: String) -> String {
        findTab(tty: tty, body: """
        do script "\(escaped(singleLine(text)))" in tab i of w
        return "\(okMark)"
        """)
    }

    /// 탭을 고르고, 창을 내리지 않았으면 올리고, 맨 앞으로 가져와 Terminal을 띄운다
    static func reveal(tty: String) -> String {
        findTab(tty: tty, body: """
        try
        \tset miniaturized of w to false
        end try
        set selected of tab i of w to true
        set index of w to 1
        activate
        return "\(okMark)"
        """)
    }

    /// 새 창에서 명령 실행. Terminal이 꺼져 있었다면 켜질 때 생기는 첫 창을 쓴다 (do script가 창을 하나 더 만들지 않게)
    static func openWindow(command: String) -> String {
        """
        set shellCommand to "\(escaped(singleLine(command)))"
        set wasRunning to application id "com.apple.Terminal" is running
        tell application id "com.apple.Terminal"
        \tif wasRunning then
        \t\tdo script shellCommand
        \telse
        \t\tlaunch
        \t\trepeat 30 times
        \t\t\tif (count of windows) > 0 then exit repeat
        \t\t\tdelay 0.1
        \t\tend repeat
        \t\tif (count of windows) > 0 then
        \t\t\tdo script shellCommand in window 1
        \t\telse
        \t\t\tdo script shellCommand
        \t\tend if
        \tend if
        \tactivate
        end tell
        return "\(okMark)"
        """
    }

    // MARK: - 결과 읽기

    /// 스크립트가 돌려준 표시를 보고 오류로 바꾸거나 표시를 뗀 결과를 돌려준다
    static func checkSentinel(_ output: String) throws -> String {
        if output == notRunningMark { throw AgentBridgeError(message: Message.notRunning) }
        if output == noTabMark { throw AgentBridgeError(message: Message.tabMissing) }
        guard output.hasPrefix(okMark) else {
            throw AgentBridgeError(message: "Terminal에서 알 수 없는 답이 왔어요")
        }
        return String(output.dropFirst(okMark.count))
    }

    static func parseTabs(_ output: String) -> [TerminalAppTab] {
        output.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: unitSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let windowID = Int(fields[0]), let tabIndex = Int(fields[1]), !fields[2].isEmpty else {
                return nil
            }
            let title = fields[4].trimmingCharacters(in: .whitespaces)
            return TerminalAppTab(
                tty: fields[2], windowID: windowID, tabIndex: tabIndex,
                title: title.isEmpty ? nil : title,
                isBusy: fields[3] == "true",
                processes: fields[5].split(separator: groupSeparator).map(String.init))
        }
    }

    /// Terminal의 contents: 줄 끝을 \n으로 맞추고 아래쪽 빈 줄을 지운다
    static func screenText(_ contents: String) -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return AgentCommandRunner.trimmingTrailingBlankLines(normalized)
    }

    /// osascript 오류 출력("… (-1743)")을 화면에 보여줄 말로 바꾼다
    static func message(forError error: String) -> String {
        switch errorCode(in: error) {
        case -1743: Message.denied
        case -1744: Message.denied  // 아직 안 물어봤는데 묻지 않고 보낸 경우. 권한 버튼으로 물어야 한다
        case -600, -609: Message.notRunning
        case -1728, -1719: Message.tabMissing
        case -1712: Message.timeout
        default: "Terminal 연동에 실패했어요" + (errorCode(in: error).map { " (\($0))" } ?? "")
        }
    }

    /// "execution error: Not authorized to send Apple events to Terminal. (-1743)" → -1743
    static func errorCode(in error: String) -> Int? {
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        return Int(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
    }
}

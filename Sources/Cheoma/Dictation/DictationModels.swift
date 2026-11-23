import AVFoundation
import Foundation

// 받아쓰기: 단축키를 누르고 말하면 글로 옮겨 지금 쓰는 앱에 붙여 넣는다.
// 이 파일은 부품(엔진 · 마이크 · 단축키 · 붙여넣기 · 노치 표시)이 서로 주고받는 약속이다.

// MARK: - 설정

/// 받아쓰기 설정. UserDefaults의 "dictation." 키에 저장한다
struct DictationSettings: Equatable, Sendable {
    var isEnabled = false
    var hotKey: DictationHotKey = .rightOption
    /// 두 번 빠르게 누르면 손을 떼도 계속 듣는다. 한 번 더 누르면 멈춘다
    var allowsHandsFree = true
    var engine: DictationEngineKind = .preferred
    /// 말하는 언어 ("ko-KR")
    var localeIdentifier = "ko-KR"
    /// 블루투스 헤드셋이 기본 입력이어도 내장 마이크를 쓴다 (헤드셋 소리가 나빠지지 않게)
    var prefersBuiltInMicrophone = true
    var pasteMethod: DictationPasteMethod = .automatic
    /// 붙여 넣은 뒤 원래 클립보드를 되돌린다
    var restoresClipboard = true
    /// 용어집 원문. 한 줄에 하나: "도커 → Docker"(바꾸기) 또는 "Docker"(엔진에 알려 줄 낱말)
    var glossaryText = ""
    /// whisper 모델 파일 경로. 비우면 알려진 곳에서 찾는다
    var whisperModelPath = ""

    static let defaultsPrefix = "dictation."

    static func load(from defaults: UserDefaults = .standard) -> DictationSettings {
        var settings = DictationSettings()
        let key = { (name: String) in defaultsPrefix + name }
        if defaults.object(forKey: key("enabled")) != nil { settings.isEnabled = defaults.bool(forKey: key("enabled")) }
        if let raw = defaults.string(forKey: key("hotKey")), let value = DictationHotKey(rawValue: raw) { settings.hotKey = value }
        if defaults.object(forKey: key("handsFree")) != nil { settings.allowsHandsFree = defaults.bool(forKey: key("handsFree")) }
        if let raw = defaults.string(forKey: key("engine")), let value = DictationEngineKind(rawValue: raw) { settings.engine = value }
        if let value = defaults.string(forKey: key("locale")), !value.isEmpty { settings.localeIdentifier = value }
        if defaults.object(forKey: key("builtInMic")) != nil {
            settings.prefersBuiltInMicrophone = defaults.bool(forKey: key("builtInMic"))
        }
        if let raw = defaults.string(forKey: key("pasteMethod")), let value = DictationPasteMethod(rawValue: raw) {
            settings.pasteMethod = value
        }
        if defaults.object(forKey: key("restoreClipboard")) != nil {
            settings.restoresClipboard = defaults.bool(forKey: key("restoreClipboard"))
        }
        settings.glossaryText = defaults.string(forKey: key("glossary")) ?? ""
        settings.whisperModelPath = defaults.string(forKey: key("whisperModel")) ?? ""
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        let key = { (name: String) in Self.defaultsPrefix + name }
        defaults.set(isEnabled, forKey: key("enabled"))
        defaults.set(hotKey.rawValue, forKey: key("hotKey"))
        defaults.set(allowsHandsFree, forKey: key("handsFree"))
        defaults.set(engine.rawValue, forKey: key("engine"))
        defaults.set(localeIdentifier, forKey: key("locale"))
        defaults.set(prefersBuiltInMicrophone, forKey: key("builtInMic"))
        defaults.set(pasteMethod.rawValue, forKey: key("pasteMethod"))
        defaults.set(restoresClipboard, forKey: key("restoreClipboard"))
        defaults.set(glossaryText, forKey: key("glossary"))
        defaults.set(whisperModelPath, forKey: key("whisperModel"))
    }
}

/// 누르고 있는 동안 듣는 키. 수식키 하나라서 다른 단축키와 덜 겹친다
enum DictationHotKey: String, CaseIterable, Sendable {
    case rightOption, rightCommand, fn

    /// flagsChanged 이벤트의 keyCode (kVK_RightOption, kVK_RightCommand, kVK_Function)
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        }
    }

    var title: String {
        switch self {
        case .rightOption: "오른쪽 ⌥"
        case .rightCommand: "오른쪽 ⌘"
        case .fn: "fn (지구본)"
        }
    }
}

enum DictationEngineKind: String, CaseIterable, Sendable {
    /// Apple 음성 인식 (macOS 26 SpeechAnalyzer). 이 맥 안에서 돌고, 내려받을 것이 거의 없다
    case apple
    /// whisper.cpp (whisper-cli · whisper-server). 더 정확하지만 모델 파일이 있어야 한다
    case whisper

    /// 처음 쓸 엔진. Apple 음성 인식이 없는 macOS 26 전에는 whisper
    static var preferred: DictationEngineKind {
        if #available(macOS 26.0, *) { return .apple }
        return .whisper
    }

    var title: String {
        switch self {
        case .apple: "Apple 음성 인식"
        case .whisper: "Whisper"
        }
    }
}

enum DictationPasteMethod: String, CaseIterable, Sendable {
    /// ⌘V를 보낸다. Chromium · Electron 앱은 메뉴의 붙여넣기를 누른다 (그 앱들은 보낸 ⌘V를 가끔 놓친다)
    case automatic
    /// 늘 메뉴 막대의 붙여넣기(⌘V 항목)를 손쉬운 사용 API로 누른다. 켜진 항목을 못 찾거나 누르지 못하면 ⌘V를 보낸다
    case menu
    /// 클립보드에만 넣는다. 붙여넣기는 직접 ⌘V
    case clipboardOnly

    var title: String {
        switch self {
        case .automatic: "자동"
        case .menu: "편집 › 붙여넣기 메뉴"
        case .clipboardOnly: "클립보드에만 복사"
        }
    }
}

// MARK: - 엔진

/// 엔진에 넘기는 값 (듣기 한 번마다)
struct DictationEngineOptions: Equatable, Sendable {
    /// "ko-KR"
    var localeIdentifier: String
    /// 엔진이 알아들으면 좋을 낱말 (용어집의 바꿀 말 + 낱말). Apple은 앞의 100개까지만 쓴다
    var vocabulary: [String]
    /// whisper 모델 파일 경로 (비우면 엔진이 찾는다)
    var whisperModelPath: String
}

/// 말소리를 글로 바꾸는 엔진 하나. 듣기 한 번 = begin → append … → finish (또는 cancel)
/// append는 오디오 스레드에서 불리므로 구현은 스레드에 안전해야 한다
protocol DictationEngine: AnyObject {
    /// 쓸 수 있는지 (언어 모델 · 도구 · 모델 파일). 설정 화면에 그대로 보여 준다
    func availability(options: DictationEngineOptions) async -> DictationAvailability
    /// 모델을 미리 올려 둔다. 받아쓰기를 켤 때 · 엔진을 바꿀 때 부른다. 실패해도 begin에서 다시 해 본다
    func prepare(options: DictationEngineOptions) async
    /// 듣기를 시작한다. format은 마이크 버퍼의 형식이다.
    /// 바뀌어 가는 중간 글(지금까지 들은 전체)은 onPartial로 알린다 (메인 스레드가 아닐 수 있다)
    func begin(format: AVAudioFormat, options: DictationEngineOptions,
               onPartial: @escaping @Sendable (String) -> Void) async throws
    /// 마이크 버퍼 하나. 오디오 스레드에서 불린다 (막지 말 것)
    func append(_ buffer: AVAudioPCMBuffer)
    /// 들은 것을 마무리하고 최종 글을 돌려준다 (용어집은 아직 적용하지 않은 글)
    func finish() async throws -> String
    /// 듣기를 버린다. 결과는 알리지 않는다
    func cancel()
}

enum DictationAvailability: Equatable, Sendable {
    case ready
    /// 언어 모델을 내려받으면 쓸 수 있다 (Apple)
    case needsDownload
    /// 쓸 수 없다. 이유를 화면에 그대로 보여 준다
    case unavailable(String)
}

/// 화면에 짧게 보여 줄 오류
enum DictationError: Error, Equatable {
    case microphoneDenied
    case microphoneUnavailable(String)
    case engineUnavailable(String)
    case nothingHeard
    case insertFailed(String)

    var message: String {
        switch self {
        case .microphoneDenied: "마이크 권한 없음"
        case .microphoneUnavailable(let reason): "마이크를 열 수 없음: \(reason)"
        case .engineUnavailable(let reason): reason
        case .nothingHeard: "인식된 말 없음"
        case .insertFailed(let reason): "붙여넣기 실패: \(reason)"
        }
    }

    /// 노치 귀에 들어가는 짧은 글 (13자 안쪽). 다 적은 글(message)은 기록에 남긴다
    var headline: String {
        switch self {
        case .microphoneDenied: return "마이크 권한 없음"
        case .nothingHeard: return message
        case .microphoneUnavailable(let reason):
            let known = [("변경되었", "마이크 변경됨"), ("끊어졌", "마이크 연결 끊김"), ("소리가 들어오지", "마이크 소리 없음"),
                         ("권한", "마이크 권한 필요"), ("입력 장치", "입력 장치 없음"),
                         ("형식", "입력 형식 오류"), ("응답", "마이크 응답 없음")]
            return known.first { reason.contains($0.0) }?.1 ?? "마이크를 열 수 없음"
        case .engineUnavailable(let reason):
            let known = [("macOS 26", "macOS 26 필요"), ("whisper-cli가 없", "whisper-cli 없음"),
                         ("모델 파일", "모델 파일 없음"), ("시간 초과", "시간 초과"),
                         ("whisper-cli 실패", "whisper 실패"), ("whisper-cli를 실행", "whisper 실패"),
                         ("지원하지 않", "지원하지 않는 언어"), ("중단되었", "음성 인식 중단됨"),
                         ("준비하지 못했", "음성 인식 시작 실패"), ("시작하지 못했", "음성 인식 시작 실패"),
                         ("사용할 수 없", "이 Mac에서 사용 불가"),
                         ("변환하지 못했", "오디오 변환 실패"), ("저장하지 못했", "녹음 저장 실패"),
                         ("오디오 형식", "오디오 형식 오류")]
            if let headline = known.first(where: { reason.contains($0.0) })?.1 { return headline }
            // 모르는 엔진 오류는 말이 불분명했다고 하지 않는다 (같은 말을 또렷하게 다시 해도 소용없다)
            return reason.count <= 13 ? reason : "받아쓰기 실패"
        case .insertFailed: return "붙여넣기 실패"
        }
    }
}

// MARK: - 마이크

/// 마이크. 키를 누르는 동안만 연다
protocol DictationAudioSource: AnyObject {
    /// 마이크 버퍼. 오디오 스레드에서 불린다
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// 소리 크기 0…1. 메인 스레드에서 초당 20번쯤
    var onLevel: ((Float) -> Void)? { get set }
    /// 듣는 도중 마이크가 바뀌거나 빠졌다. 마이크를 이미 닫은 뒤에 메인 스레드에서 부른다
    var onInterrupted: ((DictationError) -> Void)? { get set }
    /// 마이크를 연다. 돌려준 형식으로 onBuffer가 온다
    func start(prefersBuiltInMicrophone: Bool) throws -> AVAudioFormat
    func stop()
    /// 지금 열면 블루투스 헤드셋 마이크가 열리는지 (열면 헤드셋이 통화 음질로 바뀐다). 장치를 열지 않고 본다
    func opensBluetoothInput(prefersBuiltInMicrophone: Bool) -> Bool
}

extension DictationAudioSource {
    func opensBluetoothInput(prefersBuiltInMicrophone: Bool) -> Bool { false }
}

// MARK: - 단축키

/// 단축키 상태 기계가 내는 일
enum PushToTalkEvent: Equatable, Sendable {
    /// 키가 눌렸다. 첫 음절을 놓치지 않도록 마이크를 미리 열어도 된다 (아직 화면에는 안 보인다)
    case armed
    /// 정말 듣기 시작 (누른 채 기다렸거나, 두 번 눌러 손을 떼도 듣는 상태)
    case began(handsFree: Bool)
    /// 듣기를 마치고 글로 옮겨 붙여 넣는다
    case ended
    /// 듣기를 버린다 (짧게 눌렀다 뗌, 다른 키와 같이 누름, Esc)
    case cancelled
}

// MARK: - 붙여넣기

/// 글을 넣은 방법
enum DictationInsertionRoute: Equatable, Sendable {
    /// Cheoma 노치의 입력란 (에이전트 답 입력 중)
    case ownPanel
    /// 클립보드 + ⌘V
    case commandV
    /// 클립보드 + 메뉴 막대의 붙여넣기 (손쉬운 사용 API)
    case menuPaste
    /// 클립보드에만 넣었다
    case clipboardOnly
}

enum DictationInsertionResult: Equatable, Sendable {
    case inserted(DictationInsertionRoute)
    /// 붙여 넣지 않고 클립보드에만 넣었다 (보안 입력 중 · 글 칸이 아님 · 설정)
    case copiedOnly(reason: String)
    case failed(String)
}

/// 클립보드 내용을 읽어도 되는지 (macOS 15.4부터 시스템 설정 › 개인정보 보호 및 보안 › 다른 앱에서 붙여넣기).
/// 원래 클립보드를 되돌리려면 읽어야 한다
enum DictationClipboardAccess: Equatable, Sendable {
    /// 늘 읽어도 된다 (허용, 또는 macOS 15.4 전)
    case allowed
    /// 한 번도 읽으려 한 적이 없다. 시스템 설정 목록에도 아직 없다
    case notAsked
    /// 읽을 때마다 묻는다
    case asks
    /// 막아 두었다
    case denied
}

// MARK: - 노치 표시

/// 노치 양옆 귀에 보여 줄 받아쓰기 상태
struct DictationIndicator: Equatable {
    enum Stage: Equatable {
        case listening
        /// 키를 뗐고 글로 옮기는 중
        case transcribing
        /// 붙여 넣었다 (잠깐 보여 주고 사라진다)
        case inserted(String)
        case failed(String)
    }

    var stage: Stage
    /// 소리 크기 0…1
    var level: Float = 0
    /// 지금까지 들은 글 (귀가 좁아서 끝부분만 보인다)
    var text: String = ""
    /// 두 번 눌러 손을 떼도 듣는 중
    var handsFree = false
}

import AppKit
import AVFoundation
import SwiftUI

// MARK: - 받아쓰기

/// 설정 창 › 받아쓰기: 단축키 · 엔진 · 붙여넣기 · 용어집 · 권한, 그리고 직접 말해 볼 칸
struct DictationSettingsTab: View {
    @ObservedObject var dictation: DictationController
    @State private var tryText = ""
    /// 지구본 키를 누르면 macOS가 하는 일 (시스템 설정에서 바꾸고 돌아오면 다시 읽는다)
    @State private var globeKeyUsage = DictationSystemSettings.globeKeyUsage

    private var settings: Binding<DictationSettings> { $dictation.settings }

    var body: some View {
        Form {
            Section {
                Toggle("받아쓰기 사용", isOn: settings.isEnabled)
                Picker("단축키", selection: settings.hotKey) {
                    ForEach(DictationHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if dictation.settings.hotKey == .fn,
                   let note = DictationSystemSettings.globeKeyNote(usage: globeKeyUsage,
                                                                   allowsHandsFree: dictation.settings.allowsHandsFree) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("키보드 설정…") { DictationSystemSettings.open(.keyboard) }
                    }
                }
                Toggle("두 번 눌러 계속 듣기", isOn: settings.allowsHandsFree)
            } header: {
                Text("받아쓰기")
            } footer: {
                Text("단축키를 누른 채로 말하고 놓으면 입력됩니다. Esc를 누르면 취소됩니다.")
            }

            Section {
                Picker("엔진", selection: settings.engine) {
                    ForEach(DictationEngineKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("상태") { availabilityRow }
                if dictation.settings.engine == .whisper {
                    LabeledContent("모델 파일") {
                        HStack {
                            TextField("모델 파일", text: settings.whisperModelPath, prompt: Text("자동 (~/models)"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Button("선택…") { chooseWhisperModel() }
                        }
                    }
                }
                Picker("언어", selection: settings.localeIdentifier) {
                    ForEach(languageOptions, id: \.identifier) { Text($0.title).tag($0.identifier) }
                }
                Toggle("블루투스 헤드셋 연결 시 내장 마이크 사용", isOn: settings.prefersBuiltInMicrophone)
            } header: {
                Text("음성 인식")
            } footer: {
                Text(engineFooter)
            }

            Section {
                Picker("붙여넣기 방법", selection: settings.pasteMethod) {
                    ForEach(DictationPasteMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("붙여넣은 후 클립보드 복원", isOn: settings.restoresClipboard)
                if dictation.settings.restoresClipboard, let note = clipboardAccessNote {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(dictation.clipboardAccess == .notAsked ? "허용…" : "시스템 설정 열기…") {
                            dictation.requestClipboardAccess()
                        }
                    }
                }
            } header: {
                Text("붙여넣기")
            } footer: {
                Text("암호 필드와 보안 입력 중에는 클립보드에만 복사합니다.")
            }

            Section {
                TextEditor(text: settings.glossaryText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if dictation.settings.glossaryText.isEmpty {
                            Text("도커 → Docker\n깃허브, 깃헙 → GitHub\nSwiftData")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("용어집")
            } footer: {
                Text("한 줄에 하나씩 ‘들린 말 → 바꿀 말’ 또는 단어를 입력합니다. #으로 시작하는 줄은 무시합니다.")
            }

            Section {
                LabeledContent("마이크") { microphoneRow }
                LabeledContent("손쉬운 사용") { accessibilityRow }
            } header: {
                Text("권한")
            } footer: {
                Text("Cheoma가 이미 켜져 있는데 ‘필요함’으로 표시되면 목록에서 제거한 후 다시 추가하십시오.")
            }

            Section {
                TextField("테스트", text: $tryText,
                          prompt: Text(dictation.settings.isEnabled ? "클릭한 후 단축키를 누른 채로 말하기"
                                                                    : "받아쓰기 꺼짐"))
                    .disabled(!dictation.settings.isEnabled)
            } header: {
                Text("테스트")
            } footer: {
                // 이 칸은 Cheoma 안이라 권한 없이도 된다. 다른 앱에서도 되는 것은 아니다
                if dictation.settings.isEnabled, !dictation.isAccessibilityTrusted {
                    HStack(alignment: .firstTextBaseline) {
                        Text("다른 앱에 입력하려면 손쉬운 사용 권한이 필요합니다.")
                        Spacer()
                        Button("허용…") { dictation.requestAccessibilityAccess() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            dictation.refreshStatus()
            globeKeyUsage = DictationSystemSettings.globeKeyUsage
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            globeKeyUsage = DictationSystemSettings.globeKeyUsage
        }
    }

    /// 원래 클립보드로 되돌릴 수 없는 까닭과 고치는 법. 되돌릴 수 있으면 nil
    private var clipboardAccessNote: String? {
        switch dictation.clipboardAccess {
        case .allowed:
            nil
        case .notAsked:
            "클립보드 읽기 권한이 없어 복원하지 않습니다. 허용을 클릭한 후 시스템 설정 › 다른 앱에서 붙여넣기에서 Cheoma를 ‘허용’으로 설정하고 Cheoma를 다시 실행하십시오."
        case .asks:
            "Cheoma가 ‘묻기’로 설정되어 있어 복원하지 않습니다. 시스템 설정 › 다른 앱에서 붙여넣기에서 ‘허용’으로 설정한 후 Cheoma를 다시 실행하십시오."
        case .denied:
            "클립보드 읽기가 차단되어 있어 복원하지 않습니다. 시스템 설정 › 다른 앱에서 붙여넣기에서 ‘허용’으로 설정한 후 Cheoma를 다시 실행하십시오."
        }
    }

    /// 목록에 없는 언어를 저장해 두었으면 그것도 고를 수 있게 둔다
    private var languageOptions: [DictationController.Language] {
        var options = DictationController.languages
        let current = dictation.settings.localeIdentifier
        if !options.contains(where: { $0.identifier == current }) {
            options.append(DictationController.Language(identifier: current, title: current))
        }
        return options
    }

    private var engineFooter: String {
        switch dictation.settings.engine {
        case .apple:
            "기기에서 처리하며, 말하는 동안 노치에 결과가 표시됩니다."
        case .whisper:
            "whisper.cpp로 기기에서 처리합니다. 한영 혼용 인식이 더 정확하며, 키를 놓은 후 변환합니다."
        }
    }

    // MARK: 상태 줄

    @ViewBuilder
    private var availabilityRow: some View {
        if let progress = dictation.downloadProgress {
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 120)
                Text("다운로드 중 \(Int((progress * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            switch dictation.availability {
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("확인 중…").foregroundStyle(.secondary)
                }
            case .ready:
                Label("사용 가능", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsDownload:
                HStack {
                    Text(dictation.downloadError ?? "언어 모델 필요").foregroundStyle(.secondary)
                    Button("다운로드") { dictation.downloadAppleModel() }
                }
            case .unavailable(let reason):
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var microphoneRow: some View {
        switch dictation.microphoneStatus {
        case .authorized:
            Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDetermined:
            Button("허용…") { dictation.requestMicrophoneAccess() }
        default:
            HStack {
                Text("거부됨").foregroundStyle(.secondary)
                Button("시스템 설정 열기…") { DictationSystemSettings.open(.microphone) }
            }
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        if dictation.isAccessibilityTrusted {
            Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            HStack {
                Text("필요함").foregroundStyle(.secondary)
                // 시스템이 묻는 창을 띄워 목록에 Cheoma를 올리고 설정을 연다 (처음 설치했을 때 목록에 없으면 직접 넣어야 한다)
                Button("허용…") { dictation.requestAccessibilityAccess() }
            }
        }
    }

    // MARK: whisper 모델 고르기

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.title = "Whisper 모델 선택"
        panel.message = "ggml-*.bin 모델 파일"
        panel.prompt = "선택"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let current = dictation.settings.whisperModelPath
        let folder = current.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models", isDirectory: true)
            : URL(fileURLWithPath: (current as NSString).expandingTildeInPath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dictation.settings.whisperModelPath = AgentsStyle.abbreviated(url.path)
    }
}

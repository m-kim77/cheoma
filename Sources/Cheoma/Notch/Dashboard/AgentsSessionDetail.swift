import AppKit
import SwiftUI

/// 에이전트 탭 오른쪽: 고른 세션의 화면 미리보기, 화면의 선택지, 답 입력, 특수 키
struct AgentsSessionDetail: View {
    let session: AgentSession
    let store: AgentStore
    let model: NotchModel
    /// "다른 계정으로" 단추를 눌러 이어서 하기 단추들을 펼쳤다
    @State private var showsResume = false
    @AppStorage(AgentsScreenTextSize.defaultsKey) private var screenTextSize = AgentsScreenTextSize.fit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let target = resumeTarget, showsResume || session.state == .exited {
                // 아직 도는 세션은 같은 계정으로 하나 더 띄울 까닭이 없으니 다른 계정만
                AgentsResumeOptions(target: target, currentAccount: session.account, includesCurrent: session.state == .exited,
                                    store: store) { showsResume = false }
            }
            AgentScreenPreview(screen: session.screen, placeholder: placeholder, textSize: screenTextSize)
                .equatable()
                .frame(minHeight: 54, maxHeight: .infinity)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if session.screen != nil {
                        AgentsScreenTextSizeButtons(size: $screenTextSize)
                            .padding(5)
                    }
                }
            if let choices = session.analysis?.choices, !choices.isEmpty, session.location.canReply {
                choiceList(choices)
            }
            if session.location.canReply {
                replyRow
            } else {
                Text("이 세션은 터미널에 연결되지 않아 보기만 할 수 있어요")
                    .agentsFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentsStyle.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: session.id) { _, _ in showsResume = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentMark(kind: session.kind, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.kind.displayName) · \(session.projectName)")
                    .agentsFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .agentsFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // 한도가 찬 계정의 대화를 다른 계정으로 옮겨 이어서 하기 (끝난 세션은 이어서 하기 단추가 늘 보인다)
            if resumeTarget != nil, session.kind == .claude, session.state != .exited, store.usage.claude.count > 1 {
                AgentsCapsuleButton(title: "다른 계정으로", symbol: "arrow.triangle.swap") { showsResume.toggle() }
                    .help("이 대화를 다른 Claude 계정으로 이어서 해요")
            }
            if session.location.canReply {
                AgentsCapsuleButton(title: "터미널로 가기", symbol: "arrow.up.forward.app") {
                    store.reveal(session.id)
                }
                .help(session.location.tty.map { "이 세션의 터미널을 앞으로 가져와요 (\($0))" } ?? "이 세션의 터미널을 앞으로 가져와요")
            }
            if session.isLaunchedByCheoma {
                AgentsCapsuleButton(title: "끝내기", symbol: "stop.fill", tint: .red) {
                    store.stop(session.id)
                }
                .help("Cheoma가 띄운 tmux 세션을 끝내요")
            }
        }
    }

    private var resumeTarget: AgentResume.Target? {
        AgentsResumeOptions.target(session, store: store)
    }

    private var placeholder: String {
        if let summary = session.analysis?.summary { return summary }
        return session.location.canReply ? "화면을 읽는 중…" : "이 세션의 화면은 읽을 수 없어요"
    }

    private func choiceList(_ choices: [AgentChoice]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(choices, id: \.self) { choice in
                Button { store.choose(choice, in: session.id) } label: {
                    HStack(spacing: 7) {
                        Text(choice.key.isEmpty ? "›" : choice.key)
                            .agentsFont(size: 9.5, weight: .bold, design: .monospaced)
                            .foregroundStyle(choice.isHighlighted ? Color.black : Color.white.opacity(0.75))
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, choice.key.count > 1 ? 3 : 0)
                            .background(choice.isHighlighted ? Color.orange : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(choice.label)
                            .agentsFont(size: 10.5, weight: choice.isHighlighted ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .agentsFrame(height: 22)
                    .background(choice.isHighlighted ? Color.orange.opacity(0.2) : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(choice.label)
            }
        }
    }

    private var replyRow: some View {
        HStack(spacing: 6) {
            AgentReplyField(sessionID: session.id, store: store, model: model)
                .id(session.id)
            if session.location.canSendKeys {
                HStack(spacing: 3) {
                    keyButton("esc", key: .escape, help: "Esc")
                    keyButton(symbol: "arrow.up", key: .up, help: "위 화살표")
                    keyButton(symbol: "arrow.down", key: .down, help: "아래 화살표")
                    keyButton(symbol: "return", key: .enter, help: "Enter")
                    keyButton("⌃C", key: .ctrlC, help: "Ctrl-C (멈추기)")
                }
            } else if case .terminalApp = session.location {
                Text("Terminal은 늘\nEnter까지 보내요")
                    .agentsFont(size: 9)
                    .foregroundStyle(.tertiary)
                    .lineSpacing(0)
                    .fixedSize()
            }
        }
    }

    private func keyButton(_ title: String? = nil, symbol: String? = nil, key: TerminalKey, help: String) -> some View {
        Button { store.send(key: key, to: session.id) } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).agentsFont(size: 9.5, weight: .bold)
                } else {
                    Text(title ?? "").agentsFont(size: 9.5, weight: .semibold)
                }
            }
            .agentsFrame(width: 27, height: 24)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 터미널 화면 미리보기. 맨 아래(최근 줄)에 맞춰 그리고 위로 넘치는 줄은 잘린다.
/// 화면이 바뀔 때만 다시 그리도록 Equatable (답 입력 중 글자마다 큰 글자 덩어리를 다시 그리지 않게)
struct AgentScreenPreview: View, Equatable {
    let screen: TerminalScreen?
    let placeholder: String
    /// 글자 크기 (pt). `AgentsScreenTextSize.fit`이면 가장 긴 줄이 들어가게 맞춘다
    let textSize: Double
    @Environment(\.agentsScale) private var scale

    // 바뀌었는지는 화면 글자와 글자 크기로만 본다 (탭 글자 배율이 바뀌면 환경 값이 바뀌어 다시 그려진다)
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.screen == rhs.screen && lhs.placeholder == rhs.placeholder && lhs.textSize == rhs.textSize
    }

    private static let inset = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

    var body: some View {
        if let screen, let prepared = Prepared(screen.text) {
            GeometryReader { geo in
                let width = max(geo.size.width - Self.inset.leading - Self.inset.trailing, 1)
                let height = max(geo.size.height - Self.inset.top - Self.inset.bottom, 1)
                let fits = textSize == AgentsScreenTextSize.fit
                Text(prepared.attributed)
                    .font(.system(size: fits ? Self.fontSize(width: width, columns: prepared.columns, scale: scale) : textSize,
                                  design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    // 맞춤은 줄을 그대로 두고, 크기를 고르면 폭을 넘는 줄을 다음 줄로 넘긴다
                    .fixedSize(horizontal: fits, vertical: true)
                    .frame(width: fits ? nil : width, alignment: .leading)
                    .frame(width: width, height: height, alignment: .bottomLeading)
                    .clipped()
                    // clipped()는 그림만 자르고 누르는 자리는 그대로라, 위로 넘친 긴 화면이 위쪽 버튼(터미널로 가기 · 새 에이전트 · 톱니 · 탭)을 덮어 클릭을 먹었다
                    .allowsHitTesting(false)
                    .padding(Self.inset)
            }
            .accessibilityLabel("터미널 화면")
            .accessibilityValue(ANSIText.plain(screen.text))
        } else {
            Text(placeholder)
                .agentsFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 가장 긴 줄이 폭에 들어가도록 10pt에서 8pt까지 줄인다. 그보다 길면 오른쪽이 잘린다
    private static func fontSize(width: CGFloat, columns: CGFloat, scale: CGFloat) -> CGFloat {
        guard columns > 0 else { return 10 * scale }
        // SF Mono 글자 폭은 글자 크기의 0.618배 (넉넉히 0.625로 잡는다). 가장 큰 글자는 글자 크기 배율을 따른다
        return min(max(width / (columns * 0.625), 8), 10 * scale)
    }

    private struct Prepared {
        let attributed: AttributedString
        /// 가장 긴 줄의 폭 (영문 글자 하나 = 1)
        let columns: CGFloat

        /// 아래쪽 빈 줄은 뺀다 (터미널은 프롬프트 아래가 비어 있는 경우가 많다)
        init?(_ text: String) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            while let last = lines.last, ANSIText.plain(String(last)).trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            guard !lines.isEmpty else { return nil }
            columns = lines.map { Self.displayWidth(ANSIText.plain(String($0))) }.max() ?? 0
            attributed = ANSIText.attributed(lines.joined(separator: "\n"))
        }

        /// 한글 같은 넓은 글자는 SF Mono에서 영문의 1.4배 폭으로 그려진다 (터미널처럼 2칸이 아니다)
        private static func displayWidth(_ line: String) -> CGFloat {
            var width: CGFloat = 0
            for scalar in line.trimmingTrailingWhitespace.unicodeScalars {
                switch scalar.value {
                case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
                     0x1F300...0x1F64F, 0x1F900...0x1F9FF:
                    width += 1.4
                default:
                    width += 1
                }
            }
            return width
        }
    }
}

/// 터미널 미리보기 글자 크기를 한 단계씩 바꾼다 (미리보기 오른쪽 위)
struct AgentsScreenTextSizeButtons: View {
    @Binding var size: Double

    var body: some View {
        let steps = AgentsScreenTextSize.steps
        let index = steps.firstIndex(of: size) ?? 0
        HStack(spacing: 1) {
            step("minus", label: "터미널 글자 작게", enabled: index > 0) { size = steps[index - 1] }
            Text(AgentsScreenTextSize.title(size))
                .agentsFont(size: 9, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            step("plus", label: "터미널 글자 크게", enabled: index < steps.count - 1) { size = steps[index + 1] }
        }
        .padding(.horizontal, 3)
        // 미리보기 글자 위에 떠 있어서 거의 불투명하게
        .background(Color(white: 0.1).opacity(0.95), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .help("터미널 화면 글자 크기 · 맞춤은 가장 긴 줄이 들어가게 줄여요")
    }

    private func step(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .agentsFont(size: 8, weight: .bold)
                .agentsFrame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 0.9 : 0.3)
        .accessibilityLabel(label)
    }
}

private extension String {
    var trimmingTrailingWhitespace: Substring {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return self[..<end]
    }
}

/// 고른 세션에 보낼 답. 누르면 노치 창이 키 창이 되어 (다른 앱은 그대로 앞에 둔 채) 글자를 받는다.
/// 입력하는 동안에는 마우스가 노치 밖으로 나가도 닫히지 않는다
struct AgentReplyField: View {
    let sessionID: AgentSession.ID
    let store: AgentStore
    let model: NotchModel
    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// `--render`용: ImageRenderer는 AppKit 글자 칸을 그리지 못해서 같은 모양의 글자로 대신 그린다
    static var drawsPlaceholderOnly = false

    var body: some View {
        if Self.drawsPlaceholderOnly {
            Text("답 입력…")
                .agentsFont(size: 11.5)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .agentsFrame(height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            field
        }
    }

    private var field: some View {
        TextField("답 입력…", text: $text)
            .textFieldStyle(.plain)
            .agentsFont(size: 11.5)
            .focused($isFocused)
            .onSubmit(submit)
            .onKeyPress(.escape) {
                endEditing()
                return .handled
            }
            .padding(.horizontal, 9)
            .agentsFrame(height: 24)
            .background(.white.opacity(isFocused ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.28 : 0), lineWidth: 1)
            }
            .overlay {
                // 노치 창은 평소 키 창이 아니라서 글자 칸을 눌러도 입력이 안 된다. 누르면 먼저 키 창으로 만들고 포커스를 준다
                if !isFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: beginEditing)
                }
            }
            .onChange(of: isFocused) { _, focused in
                model.keepsOpen = focused
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                // 다른 앱을 누르는 등으로 키 창이 아니게 되면 입력도 끝낸다
                guard note.object is OverlayPanel, isFocused else { return }
                isFocused = false
                model.keepsOpen = false
            }
            .onDisappear {
                if isFocused { OverlayPanel.releaseKeyFocus() }
                model.keepsOpen = false
            }
    }

    private func beginEditing() {
        OverlayPanel.requestKeyFocus()
        // 키 창이 된 다음 차례에 포커스를 줘야 글자 칸이 첫 응답자가 된다
        DispatchQueue.main.async { isFocused = true }
        // 키 창이 늦게 되면 첫 포커스가 안 잡혀서, 그 사이 친 글자가 쓰던 앱(터미널)으로 간다. 잠깐 뒤 한 번 더 해 본다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !isFocused else { return }
            OverlayPanel.requestKeyFocus()
            isFocused = true
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.send(text: text, to: sessionID)
        text = ""
        endEditing()
    }

    private func endEditing() {
        isFocused = false
        model.keepsOpen = false
        // 키보드를 원래 앱으로 돌려준다
        OverlayPanel.releaseKeyFocus()
    }
}

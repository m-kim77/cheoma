import Foundation

// 용어집. 엔진이 한글로 받아 적은 개발 용어를 원래 글자로 바꾸고("도커를" → "Docker를"),
// 엔진에 미리 알려 줄 낱말을 모은다.
//
// 사용자가 쓰는 글 (설정의 용어집 칸, 한 줄에 하나):
//   도커 → Docker        바꾸기 ("->"나 "="도 된다)
//   깃허브, 깃헙 → GitHub  들린 말 여러 개를 쉼표로
//   SwiftData            엔진에 알려 줄 낱말만
//   # 메모               무시한다

struct DictationGlossary: Equatable, Sendable {
    /// 바꾸기 하나. spoken이 들리면 written으로 쓴다
    struct Replacement: Equatable, Sendable {
        let spoken: String
        let written: String

        init(_ spoken: String, _ written: String) {
            self.spoken = spoken
            self.written = written
        }
    }

    /// 용어집 글의 한 줄
    enum Line: Equatable, Sendable {
        case replacement(Replacement)
        /// 바꾸지 않고 엔진에 알려 주기만 할 낱말
        case term(String)
    }

    /// 바꿀 것. 사용자 것 먼저, 그다음 사용자가 덮어쓰지 않은 기본 것
    let replacements: [Replacement]
    /// 엔진에 알려 줄 낱말 (바꿀 말과 낱말). 사용자 것 먼저, 대소문자만 다른 것은 하나로
    let vocabulary: [String]
    /// 들린 말이 긴 것부터 (같은 길이면 사용자 것 먼저)
    private let patterns: [Pattern]

    init(userText: String, includesBuiltIn: Bool = true) {
        self.init(lines: Self.parse(userText), builtIn: includesBuiltIn ? Self.builtIn : [])
    }

    /// 같은 들린 말이 여러 번 있으면 앞의 것을 쓴다. 사용자 것은 기본 것을 덮어쓴다 ("도커 → 도커"로 기본 바꾸기를 끈다).
    /// 띄어쓰기만 다르게 덮어써도 기본 것의 띄어쓰기로 들린 말까지 사용자 것으로 바꾼다
    init(lines: [Line], builtIn: [Replacement]) {
        var userByKey: [String: Replacement] = [:]
        var user: [Replacement] = []
        for case .replacement(let replacement) in lines where userByKey[Self.key(replacement.spoken)] == nil {
            userByKey[Self.key(replacement.spoken)] = replacement
            user.append(replacement)
        }
        var carried: [Replacement] = []
        var kept: [Replacement] = []
        var seen = Set(userByKey.keys)
        for replacement in builtIn {
            let key = Self.key(replacement.spoken)
            if let override = userByKey[key] {
                if override.spoken != replacement.spoken { carried.append(Replacement(replacement.spoken, override.written)) }
            } else if seen.insert(key).inserted {
                kept.append(replacement)
            }
        }
        replacements = user + carried + kept

        var words: [String] = []
        var seenWords = Set<String>()
        func add(_ word: String) {
            if !word.isEmpty, seenWords.insert(word.lowercased()).inserted { words.append(word) }
        }
        for line in lines {
            switch line {
            case .replacement(let replacement): add(replacement.written)
            case .term(let term): add(term)
            }
        }
        kept.forEach { add($0.written) }
        vocabulary = words

        patterns = replacements.enumerated()
            .map { Pattern($0.element, order: $0.offset) }
            .filter { !$0.units.isEmpty }
            .sorted { ($0.length, -$0.order) > ($1.length, -$1.order) }
    }

    // MARK: 읽기

    /// 한 줄에 하나. 빈 줄과 #으로 시작하는 줄은 건너뛴다. 쓸 말이 빈 바꾸기("도커 →")는 버린다
    static func parse(_ text: String) -> [Line] {
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (left, right) = split(line) else {
                lines += commaList(line).map(Line.term)
                continue
            }
            let written = normalizedSpaces(right)
            guard !written.isEmpty else { continue }
            let spokenForms = commaList(left)
            if spokenForms.isEmpty {
                lines.append(.term(written))
            } else {
                lines += spokenForms.map { .replacement(Replacement($0, written)) }
            }
        }
        return lines
    }

    private static let separators = ["→", "->", "=>", "⇒", "="]

    /// 가장 앞에 나오는 구분 기호로 나눈다 (같은 자리면 긴 것: "=>"가 "="보다 먼저)
    private static func split(_ line: String) -> (String, String)? {
        let found = separators.compactMap { separator in line.range(of: separator).map { (separator, $0) } }
        guard let (_, range) = found.min(by: { a, b in
            a.1.lowerBound != b.1.lowerBound ? a.1.lowerBound < b.1.lowerBound : a.0.count > b.0.count
        }) else { return nil }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    private static func commaList(_ text: String) -> [String] {
        text.split(separator: ",").map { normalizedSpaces(String($0)) }.filter { !$0.isEmpty }
    }

    private static func normalizedSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 덮어쓰기를 가르는 열쇠. 띄어쓰기와 대소문자는 보지 않는다 ("클로드코드" = "클로드 코드")
    private static func key(_ spoken: String) -> String {
        spoken.filter { !$0.isWhitespace }.lowercased()
    }

    // MARK: 바꾸기

    /// 들린 말을 쓸 말로 바꾼다. 긴 들린 말부터 바꾸고, 이미 바꾼 자리는 다시 보지 않는다.
    /// 뒤에 붙은 조사는 그대로 둔다("도커를" → "Docker를"). 라틴 낱말 안에서는 바꾸지 않고("git"은 "github" 안에서 그대로),
    /// 한글 낱말 가운데서 시작하는 것도 바꾸지 않는다("일러스트"의 "러스트").
    /// 한글로 끝나는 들린 말 뒤에 한글이 이어지면 조사 · 어미일 때만 바꾼다("고랭지", "러스트벨트"는 그대로).
    /// 마지막에 라틴 낱말 뒤에 떨어진 조사를 붙이고("GitHub 에" → "GitHub에"), 겹친 띄어쓰기를 하나로 줄이고 앞뒤 공백을 지운다
    func apply(to text: String) -> String {
        let characters = Array(text)
        var taken = [Bool](repeating: false, count: characters.count)
        var found: [(start: Int, end: Int, written: String)] = []
        for pattern in patterns {
            var start = 0
            while start < characters.count {
                if !taken[start], let (end, replaces) = pattern.match(in: characters, at: start),
                   !taken[start..<end].contains(true) {
                    // 뒤에 다른 한글이 붙어 바꾸지 않는 자리도 차지해 둔다 (더 짧은 말이 그 안에서 반만 바꾸지 않게: "클로드 코드…")
                    if replaces { found.append((start, end, pattern.written)) }
                    for index in start..<end { taken[index] = true }
                    start = end
                } else {
                    start += 1
                }
            }
        }
        var result = ""
        var index = 0
        for match in found.sorted(by: { $0.start < $1.start }) {
            result += String(characters[index..<match.start])
            result += match.written
            index = match.end
        }
        result += String(characters[index...])
        return Self.tidy(result)
    }

    /// 라틴 낱말(숫자 포함) 뒤에 한 칸 떨어진 조사를 붙인다. 따로 쓰일 수도 있는 말(이 · 가 · 와 · 나 · 만 · 하고 · 보다)은 두고,
    /// 조사 뒤에 한글이 이어지면 다른 낱말이라 두며, 한글 뒤는 손대지 않는다 (사과 를 → 그대로)
    static func attachingParticles(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return particleExpression.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    /// 띄어쓰기를 정리한다
    static func tidy(_ text: String) -> String {
        let attached = attachingParticles(text)
        let collapsed = attached.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let particleExpression = try! NSRegularExpression(
        pattern: "(?<=[A-Za-z0-9])[ \\t]+(에서는|에서도|으로는|으로도|에게는|까지는|부터는|에서|에게|으로|이랑|처럼|까지|부터|에는|에도|로는|로도"
            + "|를|을|는|은|에|로|과|랑|의|도)(?![가-힣ㄱ-ㅎㅏ-ㅣ])")

    // MARK: 기본 용어집

    /// 개발 용어를 한글로 받아 적은 것 중 다른 뜻으로 읽힐 걱정이 없는 것만 넣는다.
    /// 쓸 말은 들린 말과 읽는 소리가 같아야 뒤의 조사가 맞는다 (그래서 고랭 → Go가 아니라 Golang).
    /// 넣지 않은 것과 까닭:
    /// - 깃(깃발 · 깃털 · 옷깃), 노드(그래프의 노드), 푸시(푸시업 · 푸시 알림), 고(가다), 커서(마우스 커서),
    ///   크롬(크롬 도금), 사파리, 비트(Vite · 비트), 빔(Vim · 빔), 제이슨(JSON · 사람 이름), 장고(장구), 다트, 플라스크
    /// - 커밋 · 브랜치 · 머지 · 리베이스 · 리눅스 · 노션 · 슬랙처럼 한국어 글에서 한글로 흔히 쓰는 말
    /// - 올라마(Ollama): "올라 마…"처럼 말 가운데 나올 수 있다
    /// 자바는 "자바라"와 겹치지만 드물고(라는 조사와 같아 못 가린다), 러스트는 "일러스트" · "러스트벨트" 안에서는 앞뒤 글자 규칙 때문에 바꾸지 않는다
    /// 들린 말 안의 띄어쓰기는 붙여 써도 맞는다 ("클로드 코드"는 "클로드코드"도 바꾼다)
    static let builtIn: [Replacement] = [
        // 코드 에이전트 · AI
        Replacement("클로드 코드", "Claude Code"),
        Replacement("클로드", "Claude"),
        Replacement("코덱스", "Codex"),
        Replacement("앤트로픽", "Anthropic"),
        Replacement("오픈 에이아이", "OpenAI"),
        Replacement("오픈 AI", "OpenAI"),
        Replacement("챗 지피티", "ChatGPT"),
        Replacement("챗 GPT", "ChatGPT"),
        Replacement("제미나이", "Gemini"),
        Replacement("코파일럿", "Copilot"),
        Replacement("허깅 페이스", "Hugging Face"),
        Replacement("엠씨피", "MCP"),
        Replacement("엘엘엠", "LLM"),
        Replacement("에이아이", "AI"),
        // 저장소 · 협업
        Replacement("깃 허브", "GitHub"),
        Replacement("깃헙", "GitHub"),
        Replacement("깃 랩", "GitLab"),
        Replacement("풀 리퀘스트", "pull request"),
        // 터미널 · 도구
        Replacement("티먹스", "tmux"),
        Replacement("홈브루", "Homebrew"),
        Replacement("엔피엠", "npm"),
        Replacement("에스에스에이치", "SSH"),
        Replacement("아이텀", "iTerm"),
        Replacement("고스티", "Ghostty"),
        Replacement("네오빔", "Neovim"),
        Replacement("엑스코드", "Xcode"),
        Replacement("브이에스 코드", "VS Code"),
        Replacement("비에스 코드", "VS Code"),
        Replacement("비주얼 스튜디오 코드", "Visual Studio Code"),
        Replacement("인텔리제이", "IntelliJ"),
        Replacement("젯브레인스", "JetBrains"),
        Replacement("안드로이드 스튜디오", "Android Studio"),
        // 언어
        Replacement("스위프트 유아이", "SwiftUI"),
        Replacement("스위프트 UI", "SwiftUI"),
        Replacement("스위프트", "Swift"),
        Replacement("타입 스크립트", "TypeScript"),
        Replacement("자바 스크립트", "JavaScript"),
        Replacement("자바", "Java"),
        Replacement("파이썬", "Python"),
        Replacement("파이선", "Python"),
        Replacement("러스트", "Rust"),
        Replacement("코틀린", "Kotlin"),
        Replacement("고랭", "Golang"),
        Replacement("어싱크", "async"),
        Replacement("에이싱크", "async"),
        Replacement("어웨이트", "await"),
        // 프레임워크 · 서비스
        Replacement("리액트 네이티브", "React Native"),
        Replacement("리액트", "React"),
        Replacement("넥스트 제이에스", "Next.js"),
        Replacement("넥스트 JS", "Next.js"),
        Replacement("노드 제이에스", "Node.js"),
        Replacement("노드 JS", "Node.js"),
        Replacement("뷰 제이에스", "Vue.js"),
        Replacement("스벨트", "Svelte"),
        Replacement("플러터", "Flutter"),
        Replacement("일렉트론", "Electron"),
        Replacement("크로미움", "Chromium"),
        Replacement("테일윈드", "Tailwind"),
        Replacement("웹팩", "webpack"),
        Replacement("그래프 큐엘", "GraphQL"),
        Replacement("파이어베이스", "Firebase"),
        Replacement("수파베이스", "Supabase"),
        Replacement("버셀", "Vercel"),
        // 인프라 · 데이터베이스
        Replacement("도커 컴포즈", "Docker Compose"),
        Replacement("도커파일", "Dockerfile"),
        Replacement("도커", "Docker"),
        Replacement("쿠버네티스", "Kubernetes"),
        Replacement("쿠베르네티스", "Kubernetes"),
        Replacement("테라폼", "Terraform"),
        Replacement("엔진엑스", "nginx"),
        Replacement("레디스", "Redis"),
        Replacement("몽고 디비", "MongoDB"),
        Replacement("포스트그레스 큐엘", "PostgreSQL"),
        Replacement("포스트그레스", "Postgres"),
        Replacement("마이 에스큐엘", "MySQL"),
        Replacement("에스큐엘", "SQL"),
        // 운영체제 · 약어
        Replacement("맥 오에스", "macOS"),
        Replacement("맥 OS", "macOS"),
        Replacement("아이오에스", "iOS"),
        Replacement("에이피아이", "API"),
        Replacement("에스디케이", "SDK"),
        Replacement("씨엘아이", "CLI"),
        Replacement("유알엘", "URL"),
        Replacement("지피유", "GPU"),
        Replacement("씨피유", "CPU"),
    ]
}

// MARK: - 맞추기

private extension DictationGlossary {
    /// 들린 말 하나를 글자 차례로 풀어 둔 것
    struct Pattern: Equatable, Sendable {
        enum Unit: Equatable, Sendable {
            case character(Character)
            /// 낱말 사이. 한글 쪽은 붙여 써도 되고, 라틴 낱말 둘 사이는 한 칸 이상 띄어야 한다
            case gap(required: Bool)
        }

        let units: [Unit]
        let written: String
        /// 띄어쓰기를 뺀 글자 수 (긴 것부터 바꾼다)
        let length: Int
        let order: Int
        let startsLatin: Bool
        let startsHangul: Bool
        let endsLatin: Bool
        let endsHangul: Bool

        init(_ replacement: Replacement, order: Int) {
            let words = replacement.spoken.split(whereSeparator: \.isWhitespace).map(Array.init)
            var units: [Unit] = []
            for (index, word) in words.enumerated() {
                if index > 0, let last = words[index - 1].last, let first = word.first {
                    units.append(.gap(required: last.isLatinWordCharacter && first.isLatinWordCharacter))
                }
                units += word.map(Unit.character)
            }
            self.units = units
            written = replacement.written
            length = words.reduce(0) { $0 + $1.count }
            self.order = order
            let first = words.first?.first
            let last = words.last?.last
            startsLatin = first?.isLatinWordCharacter ?? false
            startsHangul = first?.isHangul ?? false
            endsLatin = last?.isLatinWordCharacter ?? false
            endsHangul = last?.isHangul ?? false
        }

        /// 한글 들린 말 뒤에 바로 붙어도 되는 조사 · 어미 (이것 말고 한글이 이어지면 더 긴 다른 낱말이다)
        static let endings: [[Character]] = [
            "에서는", "에서도", "으로는", "으로도", "에게는", "까지는", "부터는", "이라는", "이에요", "입니다", "이라고",
            "에서", "에게", "한테", "으로", "이랑", "처럼", "까지", "부터", "에는", "에도", "로는", "로도", "하고", "보다",
            "라는", "라고", "이라", "이고", "이나", "이든", "예요", "이죠", "인데", "같은", "같이", "마다", "만큼", "밖에", "지만",
            "를", "을", "는", "은", "이", "가", "에", "로", "의", "도", "와", "과", "랑", "만", "라", "인", "나", "든",
            "께", "쯤", "들", "용", "죠", "요",
            // 받침 없는 낱말 뒤에서 '이다'가 빠진 꼴 (도커야 · 클로드 코드니까 · 러스트였어 · 도커잖아). '지'는 고랭지 때문에 넣지 않는다
            "니까", "잖", "거든", "보단", "조차", "마저", "야", "면", "였", "여", "네", "냐", "고", "다", "란", "엔", "래", "뿐",
        ].map(Array.init)

        static func startsWithEnding(_ text: [Character], at index: Int) -> Bool {
            endings.contains { ending in
                index + ending.count <= text.count && Array(text[index..<index + ending.count]) == ending
            }
        }

        /// start에서 맞으면 끝 위치와 바꿀지를 돌려준다. 라틴 글자는 대소문자를 보지 않는다.
        /// 글자는 다 맞는데 뒤에 조사가 아닌 한글이 붙었으면 바꾸지 않는다 (replaces가 false)
        func match(in text: [Character], at start: Int) -> (end: Int, replaces: Bool)? {
            if start > 0 {
                let before = text[start - 1]
                if startsLatin && before.isLatinWordCharacter { return nil }
                if startsHangul && before.isHangul { return nil }
            }
            var index = start
            for unit in units {
                switch unit {
                case .character(let expected):
                    guard index < text.count, text[index].matches(expected) else { return nil }
                    index += 1
                case .gap(let required):
                    let gapStart = index
                    while index < text.count, text[index] == " " || text[index] == "\t" { index += 1 }
                    if required && index == gapStart { return nil }
                }
            }
            if endsLatin, index < text.count, text[index].isLatinWordCharacter { return nil }
            if endsHangul, index < text.count, text[index].isHangul, !Self.startsWithEnding(text, at: index) {
                return (index, false)
            }
            return (index, true)
        }
    }
}

private extension Character {
    /// 라틴 낱말을 이루는 글자 (영문 · 숫자 · 악센트 붙은 라틴 글자)
    var isLatinWordCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        if scalar.isASCII { return isLetter || isNumber }
        return (0x00C0...0x024F).contains(scalar.value) && isLetter
    }

    /// 한글 음절과 자모
    var isHangul: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
    }

    func matches(_ other: Character) -> Bool {
        self == other || (isLatinWordCharacter && lowercased() == other.lowercased())
    }
}

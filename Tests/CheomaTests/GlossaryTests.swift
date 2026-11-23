import XCTest
@testable import Cheoma

final class GlossaryTests: XCTestCase {
    private func userOnly(_ text: String) -> DictationGlossary {
        DictationGlossary(userText: text, includesBuiltIn: false)
    }

    // MARK: 읽기

    func testParsesArrowsEqualsAndTerms() {
        let lines = DictationGlossary.parse("""
        도커 → Docker
        쿠버 -> Kubernetes
        티먹스 = tmux
        제이슨 => JSON
        SwiftData
        """)
        XCTAssertEqual(lines, [
            .replacement(.init("도커", "Docker")),
            .replacement(.init("쿠버", "Kubernetes")),
            .replacement(.init("티먹스", "tmux")),
            .replacement(.init("제이슨", "JSON")),
            .term("SwiftData"),
        ])
    }

    func testSkipsBlankAndCommentLinesAndTrimsSpaces() {
        let lines = DictationGlossary.parse("""

           # 메모 → 무시
        #도커 → Docker
          클로드   코드   →   Claude Code\t
        \t
        도커 →
        → Observation
        """)
        XCTAssertEqual(lines, [
            .replacement(.init("클로드 코드", "Claude Code")),
            .term("Observation"),
        ])
    }

    func testCommaSeparatedForms() {
        let lines = DictationGlossary.parse("깃허브, 깃헙 → GitHub\nSwiftData, Observation")
        XCTAssertEqual(lines, [
            .replacement(.init("깃허브", "GitHub")),
            .replacement(.init("깃헙", "GitHub")),
            .term("SwiftData"),
            .term("Observation"),
        ])
    }

    func testEarliestSeparatorWins() {
        XCTAssertEqual(DictationGlossary.parse("a = b -> c"), [.replacement(.init("a", "b -> c"))])
        XCTAssertEqual(DictationGlossary.parse("에이 => B"), [.replacement(.init("에이", "B"))])
    }

    // MARK: 합치기

    func testUserEntriesOverrideBuiltIn() {
        let glossary = DictationGlossary(userText: "도커 → docker")
        XCTAssertEqual(glossary.apply(to: "도커를 띄워요"), "docker를 띄워요")
        XCTAssertEqual(glossary.replacements.filter { $0.spoken == "도커" }, [.init("도커", "docker")])
        XCTAssertEqual(glossary.replacements.first, .init("도커", "docker"))
    }

    func testOverrideIgnoresSpacingAndCanTurnOffBuiltIn() {
        let glossary = DictationGlossary(userText: "클로드코드 → 클로드 코드\n도커 → 도커")
        XCTAssertEqual(glossary.apply(to: "클로드 코드로 도커를 띄워요"), "클로드 코드로 도커를 띄워요")
        XCTAssertFalse(glossary.replacements.contains(.init("클로드 코드", "Claude Code")))
    }

    func testFirstOfDuplicateUserEntriesWins() {
        let glossary = userOnly("도커 → Docker\n도커 → DOCKER")
        XCTAssertEqual(glossary.replacements, [.init("도커", "Docker")])
    }

    func testBuiltInCanBeLeftOut() {
        XCTAssertEqual(userOnly("").apply(to: "도커를 띄워요"), "도커를 띄워요")
        XCTAssertEqual(DictationGlossary(userText: "").apply(to: "도커를 띄워요"), "Docker를 띄워요")
    }

    // MARK: 바꾸기

    func testParticlesStayAttached() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "도커를 쓰고 깃허브에 올려요"), "Docker를 쓰고 GitHub에 올려요")
        XCTAssertEqual(glossary.apply(to: "클로드 코드랑 코덱스로 티먹스 세션을 띄워요"),
                       "Claude Code랑 Codex로 tmux 세션을 띄워요")
        XCTAssertEqual(glossary.apply(to: "쿠버네티스는 어려워요"), "Kubernetes는 어려워요")
    }

    func testLongestSpokenFormFirst() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "클로드 코드와 클로드"), "Claude Code와 Claude")
        XCTAssertEqual(glossary.apply(to: "리액트 네이티브랑 리액트"), "React Native랑 React")
        XCTAssertEqual(glossary.apply(to: "자바 스크립트 말고 자바"), "JavaScript 말고 Java")
        XCTAssertEqual(glossary.apply(to: "스위프트 유아이로 짰어요"), "SwiftUI로 짰어요")
    }

    func testLongerFormWinsEvenWhenItStartsLater() {
        let glossary = userOnly("가 나 → X\n나 다라 → Y")
        XCTAssertEqual(glossary.apply(to: "가 나 다라"), "가 Y")
    }

    func testReplacedTextIsNotMatchedAgain() {
        let glossary = userOnly("도커 → 도커 컨테이너\n컨테이너 → container")
        XCTAssertEqual(glossary.apply(to: "도커"), "도커 컨테이너")
    }

    func testSpacingInsideSpokenFormIsOptional() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "클로드코드를 켜요"), "Claude Code를 켜요")
        XCTAssertEqual(glossary.apply(to: "타입스크립트와 타입 스크립트"), "TypeScript와 TypeScript")
        XCTAssertEqual(glossary.apply(to: "깃허브 깃 허브"), "GitHub GitHub")
        XCTAssertEqual(glossary.apply(to: "넥스트JS로"), "Next.js로")
    }

    func testNeverReplacesInsideLatinWords() {
        let glossary = userOnly("git → Git\nreact native → React Native")
        XCTAssertEqual(glossary.apply(to: "github digit git gits"), "github digit Git gits")
        XCTAssertEqual(glossary.apply(to: "git을 써요"), "Git을 써요")
        XCTAssertEqual(glossary.apply(to: "reactnative react native"), "reactnative React Native")
        XCTAssertEqual(glossary.apply(to: "GIT"), "Git")
    }

    func testNeverStartsInsideKoreanWord() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "일러스트를 그려요"), "일러스트를 그려요")
        XCTAssertEqual(glossary.apply(to: "러스트를 배워요"), "Rust를 배워요")
        XCTAssertEqual(glossary.apply(to: "(러스트)"), "(Rust)")
    }

    /// 한글로 끝나는 들린 말 뒤에 조사가 아닌 한글이 이어지면 더 긴 다른 낱말이다
    func testNeverEndsInsideKoreanWord() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "고랭지 배추가 비싸요"), "고랭지 배추가 비싸요")
        XCTAssertEqual(glossary.apply(to: "러스트벨트"), "러스트벨트")
        XCTAssertEqual(glossary.apply(to: "도커를 쓰고 고랭으로 짜요"), "Docker를 쓰고 Golang으로 짜요")
        XCTAssertEqual(glossary.apply(to: "자바스크립트로 해요"), "JavaScript로 해요")
        XCTAssertEqual(glossary.apply(to: "클로드한테 물어보고 도커에서는 안 돼요"), "Claude한테 물어보고 Docker에서는 안 돼요")
        XCTAssertEqual(glossary.apply(to: "파이썬이에요. 러스트지만"), "Python이에요. Rust지만")
    }

    /// 받침 없는 낱말 뒤에서 '이다'가 빠진 꼴도 조사처럼 본다. 긴 말이 끝에서 막히면 짧은 말이 그 안에서 반만 바꾸지 않는다
    func testCopulaEndingsAndNoHalfConversion() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "클로드 코드니까 테스트부터 돌려 줘"), "Claude Code니까 테스트부터 돌려 줘")
        XCTAssertEqual(glossary.apply(to: "클로드 코드야"), "Claude Code야")
        XCTAssertEqual(glossary.apply(to: "클로드 코드면 돼"), "Claude Code면 돼")
        XCTAssertEqual(glossary.apply(to: "클로드 코드였어"), "Claude Code였어")
        XCTAssertEqual(glossary.apply(to: "이건 리액트야"), "이건 React야")
        XCTAssertEqual(glossary.apply(to: "도커면 돼요"), "Docker면 돼요")
        XCTAssertEqual(glossary.apply(to: "그거 도커잖아"), "그거 Docker잖아")
        XCTAssertEqual(glossary.apply(to: "클로드야, 테스트 돌려줘"), "Claude야, 테스트 돌려줘")
        XCTAssertEqual(glossary.apply(to: "스위프트 유아이야"), "SwiftUI야")
        XCTAssertEqual(glossary.apply(to: "리액트 네이티브면"), "React Native면")
        // 긴 말 뒤에 다른 낱말이 붙어 바꾸지 않으면 그 안의 짧은 말도 그대로 둔다 ("Docker 컴포즈파일"이 되지 않게)
        XCTAssertEqual(glossary.apply(to: "도커 컴포즈파일"), "도커 컴포즈파일")
        XCTAssertEqual(glossary.apply(to: "고랭지"), "고랭지")
    }

    func testBuiltInSkipsAmbiguousShortWords() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "깃발을 들고 노드를 푸시업"), "깃발을 들고 노드를 푸시업")
        let spoken = Set(DictationGlossary.builtIn.map(\.spoken))
        for word in ["깃", "노드", "푸시", "고", "커서", "커밋", "제이슨"] {
            XCTAssertFalse(spoken.contains(word), word)
        }
    }

    func testBuiltInHasNoDuplicateSpokenForms() {
        let keys = DictationGlossary.builtIn.map { $0.spoken.filter { !$0.isWhitespace }.lowercased() }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertTrue(DictationGlossary.builtIn.allSatisfy { !$0.spoken.isEmpty && !$0.written.isEmpty })
    }

    func testCollapsesSpacesAndTrims() {
        let glossary = DictationGlossary(userText: "")
        XCTAssertEqual(glossary.apply(to: "  도커   를   띄워요 \n"), "Docker를 띄워요")
        XCTAssertEqual(glossary.apply(to: "첫 줄\n둘째  줄"), "첫 줄\n둘째 줄")
    }

    func testAttachesDetachedParticlesOnlyAfterLatin() {
        XCTAssertEqual(DictationGlossary.attachingParticles("GitHub 에 올리고 Docker 를 띄워요"), "GitHub에 올리고 Docker를 띄워요")
        XCTAssertEqual(DictationGlossary.attachingParticles("Python 3 으로는 안 돼요"), "Python 3으로는 안 돼요")
        // 따로 쓰는 말일 수 있는 것과 한글 뒤는 그대로
        XCTAssertEqual(DictationGlossary.attachingParticles("Docker 이 컨테이너"), "Docker 이 컨테이너")
        XCTAssertEqual(DictationGlossary.attachingParticles("GPU 만 개"), "GPU 만 개")
        XCTAssertEqual(DictationGlossary.attachingParticles("사과 를 먹어요"), "사과 를 먹어요")
        // 조사 뒤에 한글이 이어지면 다른 낱말
        XCTAssertEqual(DictationGlossary.attachingParticles("API 에어컨"), "API 에어컨")
        XCTAssertEqual(DictationGlossary.attachingParticles("API 도로"), "API 도로")
    }

    // MARK: 엔진에 알려 줄 낱말

    func testVocabularyPutsUserFirstWithoutDuplicates() {
        let glossary = DictationGlossary(userText: "깃허브 → GitHub\nSwiftData\n도커 → Docker\ndocker")
        XCTAssertEqual(Array(glossary.vocabulary.prefix(3)), ["GitHub", "SwiftData", "Docker"])
        let lowered = glossary.vocabulary.map { $0.lowercased() }
        XCTAssertEqual(lowered.count, Set(lowered).count)
        XCTAssertTrue(glossary.vocabulary.contains("Kubernetes"))
        XCTAssertTrue(glossary.vocabulary.contains("Claude Code"))
        XCTAssertLessThan(glossary.vocabulary.firstIndex(of: "Docker")!, glossary.vocabulary.firstIndex(of: "Kubernetes")!)
    }

    func testVocabularyOfUserOnlyGlossary() {
        XCTAssertEqual(userOnly("Observation\n티먹스 → tmux\nobservation").vocabulary, ["Observation", "tmux"])
        XCTAssertEqual(userOnly("").vocabulary, [])
    }
}

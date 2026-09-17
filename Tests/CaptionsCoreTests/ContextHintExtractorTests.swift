import Testing
@testable import CaptionsCore

/// `ContextHintExtractor`는 순수 상태 기계다 — Speech 프레임워크·파이프라인과 무관하게
/// 이 파일에서 규칙만 검증한다. 파이프라인 배선(final에서만 반영, 세션별 라우팅)은
/// `PipelineControllerTests.swift`의 컨텍스트 힌트 섹션이 다룬다.

@Test func 영어_고유명사는_대문자_시작_단어로_추출된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("I met Claude and Anthropic yesterday.", language: .english)
    #expect(Set(extractor.terms(for: .english)) == ["Claude", "Anthropic"])
}

@Test func 영어_불용어는_대문자로_시작해도_제외된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("The meeting starts now. This is fine.", language: .english)
    #expect(extractor.terms(for: .english).isEmpty)
}

@Test func 한국어는_두_번_이상_반복돼야_채택된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("발표 팀이 모였습니다.", language: .korean) // "발표" 2음절 — 길이만으로는 미채택
    #expect(!extractor.terms(for: .korean).contains("발표")) // 아직 한 번뿐이라 미채택

    extractor.ingestFinal("오늘도 발표 회의입니다.", language: .korean)
    #expect(extractor.terms(for: .korean).contains("발표")) // 두 번째 등장 — 채택
}

@Test func 한국어_긴_단어는_한_번만_나와도_채택된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("아나필락시스 반응이 있었습니다.", language: .korean) // 6음절, 1회
    #expect(extractor.terms(for: .korean).contains("아나필락시스"))
}

@Test func 한국어_불용어와_짧은_토큰은_제외된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("그런데 그냥 좋아요 좋아요", language: .korean)
    let terms = extractor.terms(for: .korean)
    #expect(!terms.contains("그런데"))
    #expect(!terms.contains("그냥"))
}

@Test func 한국어와_영어는_서로_다른_세트로_분리된다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("Anthropic is great.", language: .english)
    extractor.ingestFinal("로보틱어스 대표 로보틱어스", language: .korean)
    #expect(extractor.terms(for: .english) == ["Anthropic"])
    #expect(extractor.terms(for: .korean) == ["로보틱어스"])
}

@Test func 상한을_넘는_용어는_잘린다() {
    var extractor = ContextHintExtractor()
    // 순수 한글 음절 2글자로 된, 서로 다른 가짜 단어 50개를 만든다(토큰에 숫자가 섞이면
    // 한글 전용 검사에서 후보로도 안 잡힌다 — 유니코드 스칼라 산술로 직접 만든다).
    for index in 0..<50 {
        let first = Character(Unicode.Scalar(0xAC00 + UInt32(index))!)
        let second = Character(Unicode.Scalar(0xAC00 + UInt32(index) + 1000)!)
        let word = String([first, second])
        // 두 번씩 먹여 한국어 채택 조건(반복 ≥2)을 만족시킨다.
        extractor.ingestFinal("\(word) \(word)", language: .korean)
    }
    #expect(extractor.terms(for: .korean).count == ContextHintExtractor.maxTerms)
}

@Test func 최근_최신_용어가_먼저_온다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("아나필락시스 첫번째", language: .korean)
    extractor.ingestFinal("두번째반응 두번째반응", language: .korean)
    let terms = extractor.terms(for: .korean)
    // 가장 최근에 언급된 용어가 앞선다.
    #expect(terms.first == "두번째반응")
}

@Test func reset은_누적된_용어를_모두_지운다() {
    var extractor = ContextHintExtractor()
    extractor.ingestFinal("Anthropic Claude", language: .english)
    extractor.reset()
    #expect(extractor.terms(for: .english).isEmpty)
}

@Test func partial용_별도_경로는_없다_final만_먹이는_계약을_호출자가_지킨다() {
    // 추출기 자체는 partial/final을 구분하지 않는다 — "final만 먹인다"는 계약은
    // 호출자(SpeechPipeline.consume)가 지킨다. 여기서는 먹인 그대로 반영됨만 확인한다.
    var extractor = ContextHintExtractor()
    let changed = extractor.ingestFinal("Claude", language: .english)
    #expect(changed)
    #expect(extractor.terms(for: .english) == ["Claude"])
}

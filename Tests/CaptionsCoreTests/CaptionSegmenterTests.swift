import CoreGraphics
import Testing
@testable import CaptionsCore

/// `CaptionSegmenter`는 한 발화의 누적 텍스트를 문장 단위 줄로 쪼갠다(스펙 §1, §2, §3).
/// 이 파일은 그 순수 함수 하나만 본다 — `CaptionState` 통합(줄 ID 배정, 번역 라우팅)은
/// `CaptionStateTests.swift`의 "세그멘테이션" 섹션에서 다룬다.

@Test func 문장부호로_끝나는_두_문장은_두_구간으로_나뉜다() {
    let segments = CaptionSegmenter.segment(
        "안녕하세요 오늘 회의를 시작하겠습니다. 첫 번째 안건은 일정 조정입니다.", isFinal: true)
    #expect(segments.map(\.text) == [
        "안녕하세요 오늘 회의를 시작하겠습니다.",
        "첫 번째 안건은 일정 조정입니다.",
    ])
    #expect(segments.allSatisfy { $0.isComplete }) // 문장부호로 끝났다 — final 여부와 무관하게 완결
}

@Test func 전각_문장부호도_문장_경계로_인식한다() {
    let segments = CaptionSegmenter.segment("안녕하세요。오늘 날씨가 좋네요？정말 좋아요！", isFinal: true)
    #expect(segments.map(\.text) == ["안녕하세요。", "오늘 날씨가 좋네요？", "정말 좋아요！"])
}

@Test func 문장부호_없는_마지막_조각은_isFinal일_때만_완결이다() {
    let stillSpeaking = CaptionSegmenter.segment("아직 끝나지 않은 말", isFinal: false)
    #expect(stillSpeaking.count == 1)
    #expect(!stillSpeaking[0].isComplete)

    let doneSpeaking = CaptionSegmenter.segment("아직 끝나지 않은 말", isFinal: true)
    #expect(doneSpeaking.count == 1)
    #expect(doneSpeaking[0].isComplete) // 문장부호가 없어도 발화 자체가 끝났으니 완결
}

@Test func 안전망은_마지막_단어_경계에서_끊는다() {
    // cap(48자) 근처에서 "dog" 뒤 공백까지가 45자, 그 다음 안전망이 발동해 끊는다.
    let segments = CaptionSegmenter.segment(
        "The quick brown fox jumps over the lazy dog while everyone watches quietly",
        isFinal: false)
    #expect(segments.count == 2)
    #expect(segments[0].text == "The quick brown fox jumps over the lazy dog")
    #expect(segments[0].isComplete)
    #expect(!segments[0].text.hasSuffix(" "))       // 공백을 달고 잘리지 않는다
    #expect(!segments[0].text.contains("do "))      // 단어 중간("dog")을 끊지 않았다
    #expect(segments[1].text == "while everyone watches quietly")
    #expect(!segments[1].isComplete)
}

@Test func 공백_없는_긴_덩어리는_중간에서_억지로_끊지_않는다() {
    // 단어 경계가 전혀 없으면(공백 없는 한 토큰) cap을 넘어도 그대로 키운다 —
    // 스펙 §2: "단어 경계가 없으면 글자 수로 자른다"가 아니라 "가능하면" 경계에서
    // 자르라는 요구이고, 여기서는 글자 수 강제 절단 대신 계속 키우는 쪽을 택했다
    // (강제로 자르면 자모/단어를 반으로 쪼갤 위험이 있고, 실제 발화에 공백 없이
    // 48자를 넘는 한 덩어리가 나올 일은 거의 없다).
    let oneLongToken = String(repeating: "가", count: 50)
    let segments = CaptionSegmenter.segment(oneLongToken, isFinal: false)
    #expect(segments.count == 1)
    #expect(segments[0].text == oneLongToken)
    #expect(!segments[0].isComplete)
}

@Test func 빈_텍스트는_빈_배열이다() {
    #expect(CaptionSegmenter.segment("", isFinal: true).isEmpty)
    #expect(CaptionSegmenter.segment("   ", isFinal: true).isEmpty)
}

@Test func 짧은_한_문장은_쪼개지지_않는다() {
    let segments = CaptionSegmenter.segment("안녕하세요", isFinal: true)
    #expect(segments.count == 1)
    #expect(segments[0].text == "안녕하세요")
    #expect(segments[0].isComplete)
}

// 세그멘테이션이 상태 없이 매번 전체 텍스트를 처음부터 다시 훑는다는 설계의 핵심
// 전제: 텍스트가 뒤로 자라도 이미 확정한 앞쪽 경계는 그대로 재현돼야 한다.
// `CaptionState`가 revision마다 같은 세그먼트 인덱스를 같은 문장에 대응시킬 수
// 있는 건 이 안정성 덕분이다.
@Test func 텍스트가_자라도_이미_확정된_구간은_그대로_재현된다() {
    let first = CaptionSegmenter.segment("첫 문장입니다. 아직 끝나지 않은 두", isFinal: false)
    #expect(first.count == 2)
    #expect(first[0] == CaptionSegmenter.Segment(text: "첫 문장입니다.", isComplete: true))

    let grown = CaptionSegmenter.segment("첫 문장입니다. 아직 끝나지 않은 두 번째 문장입니다.", isFinal: false)
    #expect(grown.count == 2)
    #expect(grown[0] == first[0]) // 이미 완결된 앞 문장은 텍스트·완결 여부 모두 그대로다
    #expect(grown[1].text == "아직 끝나지 않은 두 번째 문장입니다.")
    #expect(grown[1].isComplete)
}

// MARK: - recommendedCap — 안전망 상한을 패널 폭·글자 크기에서 실측으로 도출한다
//
// "여전히 문장이 길어. 폭을 키우고 싶어"의 핵심: 폭 컨트롤만 추가하고 안전망이 상수
// 그대로면 넓어진 패널엔 빈 공간만 남고 줄 길이는 그대로다. 이 세 테스트가 그 연결을
// 고정한다 — 폭이 커지면 상한도 커지고, 글자가 커지면 상한은 작아지고, 극단값에서도
// 바닥/천장을 벗어나지 않는다.

@Test func 넓은_패널일수록_안전망_상한이_커진다() {
    let narrow = CaptionSegmenter.recommendedCap(panelWidth: 560, fontSize: 20)
    let wide = CaptionSegmenter.recommendedCap(panelWidth: 1200, fontSize: 20)
    #expect(wide > narrow)
}

@Test func 글자가_클수록_같은_폭에서_안전망_상한이_작아진다() {
    let smallFont = CaptionSegmenter.recommendedCap(panelWidth: 700, fontSize: 14)
    let bigFont = CaptionSegmenter.recommendedCap(panelWidth: 700, fontSize: 40)
    #expect(smallFont > bigFont)
}

@Test func 안전망_상한은_바닥_밑으로_내려가지_않는다() {
    // 극단적으로 좁은 폭 + 큰 글자: 실측 그대로면 한 줄에 글자 한두 개도 안 들어갈 수
    // 있다 — 그러면 매 줄이 단어 하나조차 못 담는다. capFloor가 막는다.
    let cap = CaptionSegmenter.recommendedCap(panelWidth: 1, fontSize: 200)
    #expect(cap >= CaptionSegmenter.capFloor)
}

@Test func 안전망_상한은_천장_위로_넘치지_않는다() {
    // 극단적으로 넓은 폭 + 작은 글자: 실측 그대로면 안전망이 사실상 무제한이 된다 —
    // capCeiling이 막는다.
    let cap = CaptionSegmenter.recommendedCap(panelWidth: 100_000, fontSize: 1)
    #expect(cap <= CaptionSegmenter.capCeiling)
}

@Test func 기본_패널_폭과_글자_크기의_상한은_합리적인_범위_안이다() {
    // 기존 상수(48)를 그대로 재현하진 않지만(실측이 더 정확하다), 같은 자릿수여야
    // 한다 — 터무니없이 크거나 작으면 실측 자체가 잘못됐다는 신호다.
    let cap = CaptionSegmenter.recommendedCap(panelWidth: PanelFrame.defaultWidth, fontSize: 20)
    #expect((30...80).contains(cap))
}

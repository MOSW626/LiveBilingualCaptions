import Testing
import Foundation
@testable import CaptionsCore

/// 자막은 한 줄짜리 현재 상태가 아니라 최근 발화의 목록이다.
/// 새 발화가 와도 화면을 비우지 않는다 — 비우는 건 침묵이 이어졌을 때뿐이다.

@Test @MainActor func 같은_발화_ID는_갱신하고_새_ID는_덧붙인다() {
    let state = CaptionState()
    let first = UUID()
    state.upsert(id: first, original: "안녕", isFinal: false, sourceLanguageID: "ko-KR")
    state.upsert(id: first, original: "안녕하세요", isFinal: true, sourceLanguageID: "ko-KR")
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
    #expect(state.entries[0].isFinal)

    state.upsert(id: UUID(), original: "반갑습니다", isFinal: false, sourceLanguageID: "ko-KR")
    #expect(state.entries.count == 2)
    #expect(state.entries[0].original == "안녕하세요") // 이전 발화가 남아 있다
    #expect(state.entries[1].original == "반갑습니다")
}

@Test @MainActor func 갱신은_이미_붙은_번역을_지우지_않는다() {
    let state = CaptionState()
    let id = UUID()
    state.upsert(id: id, original: "안녕", isFinal: false, sourceLanguageID: "ko-KR")
    state.setTranslation("Hi", for: id)
    state.upsert(id: id, original: "안녕하세요", isFinal: true, sourceLanguageID: "ko-KR")
    #expect(state.entries[0].translated == "Hi")
}

@Test @MainActor func 번역은_자기_발화_줄에만_반영된다() {
    let state = CaptionState()
    let first = UUID()
    let second = UUID()
    state.upsert(id: first, original: "안녕하세요", isFinal: true, sourceLanguageID: "ko-KR")
    state.upsert(id: second, original: "반갑습니다", isFinal: true, sourceLanguageID: "ko-KR")

    // 늦게 도착한 첫 발화의 번역. 최신 줄이 아니라 첫 줄에 붙어야 한다.
    state.setTranslation("Hello", for: first)
    #expect(state.entries[0].translated == "Hello")
    #expect(state.entries[1].translated == "")

    state.setTranslation("Nice to meet you", for: second)
    #expect(state.entries[0].translated == "Hello")
    #expect(state.entries[1].translated == "Nice to meet you")
}

@Test @MainActor func 한도를_넘으면_가장_오래된_발화부터_버린다() {
    let state = CaptionState()
    state.historyCount = 2
    let ids = (0..<4).map { _ in UUID() }
    for (i, id) in ids.enumerated() {
        state.upsert(id: id, original: "발화 \(i)", isFinal: true, sourceLanguageID: "ko-KR")
    }
    #expect(state.entries.map(\.original) == ["발화 2", "발화 3"])
}

@Test @MainActor func 한도가_0이하여도_최신_한_줄은_남는다() {
    let state = CaptionState()
    state.historyCount = 0
    state.upsert(id: UUID(), original: "하나", isFinal: true, sourceLanguageID: "ko-KR")
    state.upsert(id: UUID(), original: "둘", isFinal: true, sourceLanguageID: "ko-KR")
    #expect(state.entries.map(\.original) == ["둘"])
}

@Test @MainActor func 사라진_발화의_늦은_번역은_아무것도_하지_않는다() {
    let state = CaptionState()
    state.historyCount = 1
    let evicted = UUID()
    state.upsert(id: evicted, original: "밀려난 발화", isFinal: true, sourceLanguageID: "ko-KR")
    state.upsert(id: UUID(), original: "최신 발화", isFinal: true, sourceLanguageID: "ko-KR")

    state.setTranslation("gone", for: evicted) // 크래시가 아니라 무시여야 한다
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "최신 발화")
    #expect(state.entries[0].translated == "")

    state.clear()
    state.setTranslation("gone", for: evicted)
    #expect(state.isEmpty)
}

@Test @MainActor func 지우기는_목록을_비운다() {
    let state = CaptionState()
    state.upsert(id: UUID(), original: "안녕", isFinal: true, sourceLanguageID: "ko-KR")
    #expect(!state.isEmpty)
    state.clear()
    #expect(state.isEmpty)
    #expect(state.entries.isEmpty)
}

@Test @MainActor func 기본_보관_개수는_설정_기본값과_같다() {
    #expect(CaptionState().historyCount == Settings.defaultCaptionHistoryCount)
}

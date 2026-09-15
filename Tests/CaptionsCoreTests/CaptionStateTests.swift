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

@Test @MainActor func 저장된_보관_개수가_기본값이_아니어도_그대로_따른다() {
    let name = "test.captionstate.history"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    var stored = Settings.default
    stored.captionHistoryCount = 5
    stored.save(to: defaults)
    #expect(stored.captionHistoryCount != Settings.defaultCaptionHistoryCount)

    let state = CaptionState()
    state.historyCount = Settings.load(from: defaults).captionHistoryCount
    for i in 0..<8 {
        state.upsert(id: UUID(), original: "발화 \(i)", isFinal: true, sourceLanguageID: "ko-KR")
    }
    #expect(state.entries.count == 5)
    #expect(state.entries.first?.original == "발화 3")
}

// MARK: - 이벤트 경로: 사용자 불만("바로바로 사라지니까 읽을 시간도 없네")의 회귀 테스트
//
// 위의 테스트들은 upsert/setTranslation 을 직접 부르므로, show() 가 발화마다 clear() 를
// 부르도록 되돌아가도 전부 통과한다. 아래 테스트들은 **전사 이벤트**를 먹이는 경로를
// 통째로 지나므로, 어떤 입력도 목록을 비우지 못한다는 걸 실제로 고정한다.

private func event(_ utteranceID: Int, _ text: String, isFinal: Bool = true,
                   revision: Int = 0) -> TranscriptEvent {
    TranscriptEvent(utteranceID: utteranceID, revision: revision, sourceLanguage: .korean,
                    transcript: isFinal ? .final(text) : .partial(text))
}

@Test @MainActor func 연달아_말해도_이전_발화가_남는다() {
    let state = CaptionState()
    state.historyCount = 3
    for i in 0..<3 {
        _ = state.apply(event(i, "발화 \(i)"))
        #expect(!state.isEmpty) // 어느 시점에도 화면이 비지 않는다
    }
    #expect(state.entries.map(\.original) == ["발화 0", "발화 1", "발화 2"])
}

@Test @MainActor func 어떤_이벤트_순서도_목록을_비우지_않는다() {
    let state = CaptionState()
    state.historyCount = 3
    let events = [
        event(0, "첫", isFinal: false), event(0, "첫 문장"),
        event(1, "둘", isFinal: false), event(1, "두 번째 문장"),
        event(0, "첫 문장입니다", revision: 2),   // 옛 구간의 뒤늦은 final
        event(2, "세 번째", isFinal: false)
    ]
    for e in events {
        _ = state.apply(e)
        #expect(!state.isEmpty)
    }
    #expect(state.entries.count == 3)
    #expect(state.entries.map(\.original) == ["첫 문장입니다", "두 번째 문장", "세 번째"])
}

@Test @MainActor func 같은_발화의_갱신은_줄을_늘리지_않는다() {
    let state = CaptionState()
    let first = state.apply(event(7, "안녕", isFinal: false))
    let second = state.apply(event(7, "안녕하세요", revision: 1))
    #expect(first == second) // 같은 발화 = 같은 줄 = 같은 번역 대상
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
    #expect(state.entries[0].isFinal)
}

@Test @MainActor func 옛_발화의_뒤늦은_갱신은_새_줄을_만들지_않는다() {
    let state = CaptionState()
    state.historyCount = 3
    let old = state.apply(event(0, "첫", isFinal: false))
    _ = state.apply(event(1, "둘", isFinal: false))
    let late = state.apply(event(0, "첫 문장입니다", revision: 1))

    #expect(late == old)             // 원래 받은 줄로 되돌아간다
    #expect(state.entries.count == 2) // 맨 아래에 중복으로 끼어들지 않는다
    #expect(state.entries[0].original == "첫 문장입니다")
    #expect(state.entries[1].original == "둘") // 진행 중이던 발화는 쪼개지지 않는다
}

@Test @MainActor func 이미_밀려난_발화의_갱신은_무시한다() {
    let state = CaptionState()
    state.historyCount = 1
    _ = state.apply(event(0, "밀려날 발화"))
    _ = state.apply(event(1, "최신 발화"))

    #expect(state.apply(event(0, "밀려난 발화의 확정본", revision: 1)) == nil)
    #expect(state.entries.map(\.original) == ["최신 발화"])
}

@Test @MainActor func 지우기_뒤에는_같은_발화도_새_줄에서_시작한다() {
    let state = CaptionState()
    let before = state.apply(event(3, "안녕", isFinal: false))
    state.clear()
    let after = state.apply(event(3, "안녕하세요"))
    #expect(before != after)
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
}

@Test @MainActor func 장부만_비우면_화면의_자막은_남는다() {
    let state = CaptionState()
    _ = state.apply(event(0, "정지 전에 말한 것"))
    state.resetLedger()
    #expect(state.entries.map(\.original) == ["정지 전에 말한 것"]) // 읽던 줄을 뺏지 않는다
}

@Test @MainActor func 발화_ID_장부는_무한히_자라지_않는다() {
    let state = CaptionState()
    state.historyCount = 2
    for i in 0..<200 { _ = state.apply(event(i, "발화 \(i)")) }
    #expect(state.entries.count == 2)
    // 아주 오래된 발화는 장부에서도 사라졌으므로 조용히 무시된다.
    #expect(state.apply(event(0, "태초의 발화", revision: 1)) == nil)
    #expect(state.entries.map(\.original) == ["발화 198", "발화 199"])
}

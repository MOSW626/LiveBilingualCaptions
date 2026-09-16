import Testing
import Foundation
@testable import CaptionsCore

/// 자막은 한 줄짜리 현재 상태가 아니라 최근 발화의 목록이다.
/// 새 발화가 와도 화면을 비우지 않는다 — 비우는 건 침묵이 이어졌을 때뿐이다.

@Test @MainActor func 같은_발화_ID는_갱신하고_새_ID는_덧붙인다() {
    let state = CaptionState()
    let first = UUID()
    state.upsert(id: first, original: "안녕", isFinal: false)
    state.upsert(id: first, original: "안녕하세요", isFinal: true)
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
    #expect(state.entries[0].isFinal)

    state.upsert(id: UUID(), original: "반갑습니다", isFinal: false)
    #expect(state.entries.count == 2)
    #expect(state.entries[0].original == "안녕하세요") // 이전 발화가 남아 있다
    #expect(state.entries[1].original == "반갑습니다")
}

@Test @MainActor func 갱신은_이미_붙은_번역을_지우지_않는다() {
    let state = CaptionState()
    let id = UUID()
    state.upsert(id: id, original: "안녕", isFinal: false)
    state.setTranslation("Hi", for: id)
    state.upsert(id: id, original: "안녕하세요", isFinal: true)
    #expect(state.entries[0].translated == "Hi")
}

@Test @MainActor func 번역은_자기_발화_줄에만_반영된다() {
    let state = CaptionState()
    let first = UUID()
    let second = UUID()
    state.upsert(id: first, original: "안녕하세요", isFinal: true)
    state.upsert(id: second, original: "반갑습니다", isFinal: true)

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
        state.upsert(id: id, original: "발화 \(i)", isFinal: true)
    }
    #expect(state.entries.map(\.original) == ["발화 2", "발화 3"])
}

@Test @MainActor func 한도가_0이하여도_최신_한_줄은_남는다() {
    let state = CaptionState()
    state.historyCount = 0
    state.upsert(id: UUID(), original: "하나", isFinal: true)
    state.upsert(id: UUID(), original: "둘", isFinal: true)
    #expect(state.entries.map(\.original) == ["둘"])
}

@Test @MainActor func 사라진_발화의_늦은_번역은_아무것도_하지_않는다() {
    let state = CaptionState()
    state.historyCount = 1
    let evicted = UUID()
    state.upsert(id: evicted, original: "밀려난 발화", isFinal: true)
    state.upsert(id: UUID(), original: "최신 발화", isFinal: true)

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
    state.upsert(id: UUID(), original: "안녕", isFinal: true)
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
        state.upsert(id: UUID(), original: "발화 \(i)", isFinal: true)
    }
    #expect(state.entries.count == 5)
    #expect(state.entries.first?.original == "발화 3")
}

// MARK: - 이벤트 경로: 사용자 불만("바로바로 사라지니까 읽을 시간도 없네")의 회귀 테스트
//
// 위의 테스트들은 upsert/setTranslation 을 직접 부르므로, show() 가 발화마다 clear() 를
// 부르도록 되돌아가도 전부 통과한다. 아래 테스트들은 **전사 이벤트**를 먹이는 경로를
// 통째로 지나므로, 어떤 입력도 목록을 비우지 못한다는 걸 실제로 고정한다.

private func event(_ utteranceID: Int, _ text: String, isFinal: Bool = true) -> TranscriptEvent {
    TranscriptEvent(utteranceID: utteranceID, sourceLanguage: .korean,
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
        event(0, "첫 문장입니다"),   // 옛 구간의 뒤늦은 final
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
    let first = state.apply(event(7, "안녕", isFinal: false)).first?.id
    let second = state.apply(event(7, "안녕하세요")).first?.id
    #expect(first == second) // 같은 발화 = 같은 줄 = 같은 번역 대상
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
    #expect(state.entries[0].isFinal)
}

@Test @MainActor func 옛_발화의_뒤늦은_갱신은_새_줄을_만들지_않는다() {
    let state = CaptionState()
    state.historyCount = 3
    let old = state.apply(event(0, "첫", isFinal: false)).first?.id
    _ = state.apply(event(1, "둘", isFinal: false))
    let late = state.apply(event(0, "첫 문장입니다")).first?.id

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

    #expect(state.apply(event(0, "밀려난 발화의 확정본")).isEmpty)
    #expect(state.entries.map(\.original) == ["최신 발화"])
}

@Test @MainActor func 지우기_뒤에는_같은_발화도_새_줄에서_시작한다() {
    let state = CaptionState()
    let before = state.apply(event(3, "안녕", isFinal: false)).first?.id
    state.clear()
    let after = state.apply(event(3, "안녕하세요")).first?.id
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
    #expect(state.apply(event(0, "태초의 발화")).isEmpty)
    #expect(state.entries.map(\.original) == ["발화 198", "발화 199"])
}

// MARK: - runID 스코핑 — 언어 hot swap이 런타임에 실패해 새 Run이 조용히 열리는 경우의 회귀 테스트
//
// AppDelegate는 설정값만 보고 "hot swap"을 판정하므로, SpeechPipeline.switchLanguage가
// 런타임에 실패해(지원 안 되는 locale, 호환 안 되는 오디오 포맷) PipelineController가
// 조용히 stop 후 새 Run으로 재시작해도 미리 알 수 없다. 새 Run의 utteranceID는 1부터
// 다시 시작하므로, 장부가 utteranceID만 본다면 새 Run의 첫 발화가 옛 Run이 남긴 같은
// 번호의 줄을 덮어써 버린다(내용이 다른 발화가 같은 줄로 섞이는 조용한 오염).
// (runID, utteranceID) 쌍으로 키를 잡으면 이 충돌이 원천적으로 불가능해진다.

@Test @MainActor func 다른_Run의_같은_발화_ID는_다른_줄이_된다() {
    let state = CaptionState()
    let runA = state.apply(event(1, "런 A의 발화"), runID: 1).first?.id
    let runB = state.apply(event(1, "런 B의 발화"), runID: 2).first?.id // 같은 utteranceID, 다른 Run

    #expect(runA != nil)
    #expect(runB != nil)
    #expect(runA != runB)             // 별개의 줄이어야 한다 — 런 A의 줄을 훔치지 않는다
    #expect(state.entries.count == 2) // 런 A의 줄을 덮어쓰지 않는다
    #expect(state.entries[0].original == "런 A의 발화")
    #expect(state.entries[1].original == "런 B의 발화")
}

@Test @MainActor func 같은_Run_안에서는_같은_발화_ID가_한_줄을_갱신한다() {
    let state = CaptionState()
    let first = state.apply(event(1, "안녕", isFinal: false), runID: 5).first?.id
    let second = state.apply(event(1, "안녕하세요"), runID: 5).first?.id
    #expect(first == second) // 같은 Run + 같은 발화 = 같은 줄 = 같은 번역 대상
    #expect(state.entries.count == 1)
    #expect(state.entries[0].original == "안녕하세요")
    #expect(state.entries[0].isFinal)
}

// MARK: - 세그멘테이션 — 발화 하나가 문장 여러 개로 쪼개지는 경로(스펙 §1~§4)
//
// 측정된 사실: 전사기는 한국어 final을 문장마다 쪼개 주지 않는다(세 문장이어도 final은
// 하나). 그 final 하나를 그대로 한 줄에 얹으면 문장이 뭉친 거대한 한 줄이 되고, 머리·꼬리
// 트렁케이션 두 겹이 문장 가운데를 씹어먹는다(사용자 스크린샷). CaptionState.apply는 이제
// CaptionSegmenter로 문장 경계를 찾아 문장마다 독립된 줄·UUID를 만든다.

@Test @MainActor func 문장부호가_있으면_한_final이_여러_줄로_쪼개진다() {
    let state = CaptionState()
    let updates = state.apply(event(0, "안녕하세요 오늘 회의를 시작하겠습니다. 첫 번째 안건은 일정 조정입니다."))

    #expect(updates.count == 2)
    #expect(updates.allSatisfy { $0.transcript.isFinal }) // 문장부호로 끝났으니 둘 다 확정
    #expect(Set(updates.map(\.id)).count == 2)             // 줄마다 다른 UUID — 번역도 따로 붙는다

    #expect(state.entries.count == 2)
    #expect(state.entries[0].original == "안녕하세요 오늘 회의를 시작하겠습니다.")
    #expect(state.entries[1].original == "첫 번째 안건은 일정 조정입니다.")
    #expect(state.entries.allSatisfy { $0.isFinal })
}

@Test @MainActor func 세_문장짜리_단일_final도_세_줄이_된다() {
    // 스펙이 측정한 그 상황: 한국어는 세 문장을 말해도 final이 하나만 온다.
    let state = CaptionState()
    let updates = state.apply(event(0, "좋아요. 그럼 시작하겠습니다. 오늘 안건은 세 가지입니다."))
    #expect(updates.count == 3)
    #expect(state.entries.map(\.original) == ["좋아요.", "그럼 시작하겠습니다.", "오늘 안건은 세 가지입니다."])
}

@Test @MainActor func 문장부호_없이_길어지는_partial은_안전망이_중간에_끊고_계속_이어간다() {
    let state = CaptionState()
    // 문장부호 없이 계속 자라는 partial. 48자 안전망을 넘기면 마지막 단어 경계
    // ("말하는" 뒤 공백)에서 끊겨 앞부분(45자)이 확정되고, 나머지("중입니다", 4자)는
    // 새 줄에서 계속 자란다 — 단어 중간이 아니라 공백에서 끊겼다는 걸 텍스트로 확인한다.
    let growing = "이것은 문장부호가 전혀 없이 아주 길게 이어지는 발화의 예시 텍스트를 계속 말하는 중입니다"
    let firstCall = state.apply(event(0, growing, isFinal: false))
    #expect(firstCall.count == 2)                 // 안전망이 이미 한 번 끊었다
    #expect(firstCall[0].transcript.isFinal)       // 끊긴 앞부분은 확정으로 다룬다
    #expect(firstCall[0].transcript.text == "이것은 문장부호가 전혀 없이 아주 길게 이어지는 발화의 예시 텍스트를 계속 말하는")
    #expect(!firstCall[0].transcript.text.hasSuffix(" "))   // 꼬리에 공백을 달고 잘리지 않는다
    #expect(!firstCall[1].transcript.isFinal)      // 나머지는 계속 자라는 partial
    #expect(firstCall[1].transcript.text == "중입니다")
    let firstRowID = firstCall[0].id
    let secondRowID = firstCall[1].id

    // 뒤이어 도착한 갱신(같은 utteranceID, 더 길어진 누적 텍스트) — 이미 확정된 앞
    // 문장은 같은 줄·같은 id를 그대로 유지하고(재조합해도 문장 경계가 흔들리면 안
    // 된다), 뒤 조각만 계속 같은 줄에서 자란다.
    let more = growing + " 그리고 계속됩니다"
    let secondCall = state.apply(event(0, more, isFinal: false))
    #expect(secondCall.count == 2)
    #expect(secondCall[0].id == firstRowID)   // 이미 확정된 줄은 같은 id
    #expect(secondCall[1].id == secondRowID)  // 자라던 뒷줄도 같은 id
    #expect(secondCall[1].transcript.text == "중입니다 그리고 계속됩니다")
    #expect(state.entries.count == 2)
}

@Test @MainActor func 세그먼트마다_다른_id라_번역도_문장마다_따로_붙는다() {
    let state = CaptionState()
    let updates = state.apply(event(0, "첫 문장입니다. 둘째 문장입니다."))
    #expect(updates.count == 2)

    var translated: [UUID: String] = [:]
    for update in updates {
        translated[update.id] = "번역:\(update.transcript.text)"
    }
    for update in updates {
        state.setTranslation(translated[update.id]!, for: update.id)
    }
    #expect(state.entries[0].translated == "번역:첫 문장입니다.")
    #expect(state.entries[1].translated == "번역:둘째 문장입니다.")
}

// `segmentCap`을 낮추면(좁은 패널·큰 글자를 흉내) 같은 문장부호 없는 텍스트가 더
// 일찍 끊겨야 한다 — 폭 컨트롤이 실제로 세그멘테이션에 연결돼 있다는 배선 확인.
@Test @MainActor func segmentCap을_낮추면_더_일찍_끊긴다() {
    let text = "이것은 문장부호가 전혀 없이 아주 길게 이어지는 발화의 예시 텍스트입니다"
    let state = CaptionState()
    state.segmentCap = 8
    let updates = state.apply(event(0, text, isFinal: false))
    #expect(updates.count > 1)
    #expect(updates[0].transcript.text.count <= 8)
}

import Testing
import Foundation
@testable import CaptionsCore

private actor SpyRefiner: TranslationRefiner {
    private var calls: [String] = []
    func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        calls.append(source)
        return draft + " (보정됨)"
    }
    func recorded() -> [String] { calls }
}

/// 매 호출의 `context` 배열을 순서대로 기록한다 — 문맥 창이 제대로 좁혀·채워지는지 보려고.
private actor ContextSpyRefiner: TranslationRefiner {
    private var contexts: [[String]] = []
    func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        contexts.append(context)
        return draft + " (보정됨)"
    }
    func recordedContexts() -> [[String]] { contexts }
}

/// 언어팩과 무관하게 항상 같은 값을 주는 가짜 번역기.
private let fakeTranslate: TranslateFunction = { text, _, _ in "[번역] " + text }

@Test @MainActor func 보정기는_확정_전사에만_호출된다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    await translator.handle(.partial("안녕"), from: .korean)
    await translator.handle(.partial("안녕하세"), from: .korean)
    #expect(await spy.recorded().isEmpty, "부분 전사에는 보정기가 붙으면 안 된다")

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(await spy.recorded() == ["안녕하세요"])
}

@Test @MainActor func 보정기가_없으면_번역문이_그대로_나온다() async {
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = nil
    var received: [(String, Bool)] = []
    translator.onTranslation = { text, refined, _ in received.append((text, refined)) }

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(received.count == 1)
    #expect(received[0].0 == "[번역] 안녕하세요")
    #expect(received[0].1 == false)
}

@Test @MainActor func 보정되면_두_번째_방출이_refined_true() async {
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = SpyRefiner()
    var received: [(String, Bool)] = []
    translator.onTranslation = { text, refined, _ in received.append((text, refined)) }

    await translator.handle(.final("안녕하세요"), from: .korean)
    #expect(received.count == 2)
    #expect(received[0] == ("[번역] 안녕하세요", false))
    #expect(received[1] == ("[번역] 안녕하세요 (보정됨)", true))
}

@Test @MainActor func 같은_발화의_중복_final은_한_번만_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    let captionID = UUID()
    await translator.handle(.final("같은 문장"), from: .korean, captionID: captionID)
    await translator.handle(.final("같은 문장"), from: .korean, captionID: captionID)
    #expect(await spy.recorded().count == 1)
}

@Test @MainActor func reset하면_같은_문장을_다시_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    let captionID = UUID()
    await translator.handle(.final("문장"), from: .korean, captionID: captionID)
    translator.reset()
    await translator.handle(.final("문장"), from: .korean, captionID: captionID)
    #expect(await spy.recorded().count == 2)
}

@Test @MainActor func 같은_문장도_다른_발화면_각각_보정한다() async {
    let spy = SpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy
    await translator.handle(.final("네"), from: .korean, captionID: UUID())
    await translator.handle(.final("네"), from: .korean, captionID: UUID())
    #expect(await spy.recorded().count == 2)
}

// MARK: - 문맥 창: 원문·채택된 번역 쌍을 순서대로, 상한 안에서, 같은 언어만

@Test @MainActor func 보정기는_직전_원문과_채택된_번역을_쌍으로_순서대로_받는다() async {
    let spy = ContextSpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    await translator.handle(.final("첫 문장"), from: .korean)
    await translator.handle(.final("둘째 문장"), from: .korean)

    let contexts = await spy.recordedContexts()
    #expect(contexts.count == 2)
    #expect(contexts[0].isEmpty, "첫 문장에는 앞선 문맥이 없어야 한다")
    #expect(contexts[1] == ["원문: 첫 문장\n번역: [번역] 첫 문장 (보정됨)"],
            "둘째 문장의 문맥에는 첫 문장의 '채택된'(보정된) 번역이 담겨야 한다")
}

@Test @MainActor func 문맥_창은_상한을_넘지_않는다() async {
    let spy = ContextSpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    let total = Translator.contextWindowSize + 5
    for i in 0..<total {
        await translator.handle(.final("문장\(i)"), from: .korean)
    }

    let contexts = await spy.recordedContexts()
    #expect(contexts.last?.count == Translator.contextWindowSize)
    // 가장 오래된 문장은 창에서 밀려나 더는 보이지 않는다.
    #expect(contexts.last?.contains { $0.contains("문장0\n") } == false)
}

@Test @MainActor func reset하면_문맥_창도_비워진다() async {
    let spy = ContextSpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    await translator.handle(.final("문장"), from: .korean)
    translator.reset() // refiner 프로퍼티는 그대로 두고 줄·문맥만 비운다
    await translator.handle(.final("다음 문장"), from: .korean)

    let contexts = await spy.recordedContexts()
    #expect(contexts.last?.isEmpty == true)
}

@Test @MainActor func 문맥은_같은_원문_언어의_문장만_포함한다() async {
    let spy = ContextSpyRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = spy

    await translator.handle(.final("한국어 문장"), from: .korean)
    await translator.handle(.final("English sentence"), from: .english)
    await translator.handle(.final("두 번째 한국어 문장"), from: .korean)

    let contexts = await spy.recordedContexts()
    #expect(contexts[2].count == 1, "영어 문장은 한국어 원문의 문맥에 섞이면 안 된다")
    #expect(contexts[2][0].contains("한국어 문장"))
}

// MARK: - Step 5a: 응답 순서 회귀 테스트
//
// 실제 TranslationSession·LLM 응답은 요청한 순서대로 돌아온다는 보장이 없다.
// 아래 가짜들은 호출을 순번으로 등록해 두고 테스트가 원하는 순서로 "늦게" 풀어준다.
// 전부 MainActor에 고정해서 테스트 코드와 같은 실행 맥락에서 돌아가게 했다 — 그래야
// "지금 몇 번째 호출이 게이트 안에서 멈춰 있는지"를 경쟁 없이 알 수 있다.
// Swift의 협조적 취소를 검사 대상으로 삼지 않으려고 취소는 의도적으로 무시한다
// (resume을 받을 때까지 그냥 계속 대기한다) — 지켜야 할 가드는 Translator의 세대 검사다.

@MainActor
private final class CallGate<Value: Sendable>: @unchecked Sendable {
    private var waiters: [CheckedContinuation<Value, Never>?] = []
    private var pendingIDs: [Int] = []
    private var idWaiter: CheckedContinuation<Int, Never>?

    /// 가짜 translate/refine 안에서 호출한다: 순번을 등록하고 resume(_:with:)가 올 때까지 대기한다.
    func call() async -> Value {
        let id = waiters.count
        waiters.append(nil)
        if let idWaiter {
            self.idWaiter = nil
            idWaiter.resume(returning: id)
        } else {
            pendingIDs.append(id)
        }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    /// 다음 호출이 게이트 안에서 실제로 대기를 시작할 때까지 기다렸다가 그 순번을 돌려준다.
    /// 테스트가 이걸 부르기 전에 호출이 이미 등록돼 있어도, 나중에 등록돼도 둘 다 안전하다.
    func nextCallStarted() async -> Int {
        if !pendingIDs.isEmpty { return pendingIDs.removeFirst() }
        return await withCheckedContinuation { idWaiter = $0 }
    }

    /// 지정한 순번의 호출을 테스트가 원하는 순서·값으로 재개한다.
    func resume(_ id: Int, with value: Value) {
        guard id < waiters.count, let continuation = waiters[id] else { return }
        waiters[id] = nil
        continuation.resume(returning: value)
    }
}

@MainActor
private final class GatedRefiner: TranslationRefiner, @unchecked Sendable {
    let gate = CallGate<String>()
    func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        await gate.call()
    }
}

/// 튜플은 Array 비교에 쓸 수 없어서(Equatable 미준수) onTranslation 로그를 담는 작은 값 타입을 쓴다.
private struct Emission: Equatable {
    let text: String
    let refined: Bool
    let captionID: UUID
}

/// 1. 한 줄 안에서 partial 요청 → final 요청 → final 응답 → partial의 늦은 응답.
///    늦게 온 partial 응답은 버려진다.
///
///    **같은 captionID를 쓴다.** 예전에는 서로 다른 ID로 이 시나리오를 썼는데, 자막이
///    한 줄뿐이라 "새 발화 = 이전 것 무효"가 성립하던 시절의 전제였다. 지금은 두 ID면
///    두 줄이고 둘 다 화면에 있으므로 둘 다 번역돼야 한다(아래
///    `다른_줄의_제출은_서로의_번역을_취소하지_않는다`가 그 경우를 고정한다).
///    여기서 지킬 규칙은 "**같은 줄의** 낡은 제출은 버린다"는 것이다.
@Test @MainActor func 회귀_partial_다음_final이_오면_늦게_도착한_partial_응답은_버려진다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let line = UUID()
    let taskA = translator.submit(.partial("A문장"), from: .korean, captionID: line)
    let callA = await gate.nextCallStarted() // 220ms 디바운스가 끝나고 translate 안에서 대기 중

    let taskB = translator.submit(.final("A문장입니다"), from: .korean, captionID: line)
    let callB = await gate.nextCallStarted()

    gate.resume(callB, with: "[번역] A문장입니다")
    await taskB?.value

    gate.resume(callA, with: "[번역] A문장") // 먼저 요청됐지만 응답은 final보다 늦게 도착한다
    await taskA?.value

    #expect(received == [Emission(text: "[번역] A문장입니다", refined: false, captionID: line)])
}

/// 2. final 초안(A) 표시 → 원문이 B로 갱신 → A의 LLM 보정 응답이 뒤늦게 도착. 버려진다.
@Test @MainActor func 회귀_보정_대기_중_원문이_갱신되면_늦은_보정_응답은_버려진다() async {
    let refiner = GatedRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = refiner
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    // 같은 줄이다. 한 줄의 원문이 갱신되는 상황을 재현해야 하므로 captionID를 공유한다.
    let line = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: line)
    let callA = await refiner.gate.nextCallStarted() // 초안은 이미 나갔고, 보정이 시작된 뒤다

    // 같은 줄의 원문이 갱신된다. 초안은 새로 나가고, 낡은 보정 요청은 무효가 된다.
    let taskB = translator.submit(.final("A문장 수정본"), from: .korean, captionID: line)
    await taskB?.value

    refiner.gate.resume(callA, with: "[번역] A문장 (보정됨)") // 낡은 원문의 뒤늦은 보정
    await taskA?.value

    #expect(received == [
        Emission(text: "[번역] A문장", refined: false, captionID: line),
        Emission(text: "[번역] A문장 수정본", refined: false, captionID: line)
    ])
}

/// 3. 번역 대기 중 reset → 그 응답은 버려진다. reset 직후 새 요청은 정상 진행되고,
///    reset 전 요청의 응답이 그 뒤에 도착해도 여전히 버려진다.
@Test @MainActor func 회귀_reset_중이던_응답과_그_직후_새_요청_중_이전_응답은_버려진다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: idA)
    let callA = await gate.nextCallStarted() // A가 번역 대기 중

    translator.reset() // 진행 중이던 A를 무효화

    let idC = UUID()
    let taskC = translator.submit(.final("C문장"), from: .korean, captionID: idC)
    let callC = await gate.nextCallStarted() // reset 직후 새 요청도 게이트에서 대기

    gate.resume(callC, with: "[번역] C문장")
    await taskC?.value

    gate.resume(callA, with: "[번역] A문장") // reset 전 요청의 늦은 응답
    await taskA?.value

    #expect(received == [Emission(text: "[번역] C문장", refined: false, captionID: idC)])
}

/// 4. 보정 대기 중 보정기를 끄거나(nil) 교체하면 didSet이 reset()을 불러
///    기존 보정 응답이 뒤늦게 와도 버려진다. 교체된 새 보정기는 정상 동작한다.
@Test @MainActor func 회귀_보정기를_끄거나_교체하면_기존_보정_응답은_버려진다() async {
    let refiner1 = GatedRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = refiner1
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: idA)
    let callA = await refiner1.gate.nextCallStarted()

    translator.refiner = nil // 보정 끄기 — didSet이 reset()을 호출한다

    refiner1.gate.resume(callA, with: "[번역] A문장 (보정됨)") // 이미 꺼진 보정기의 늦은 응답
    await taskA?.value

    let refiner2 = GatedRefiner()
    translator.refiner = refiner2 // 키 교체 — didSet이 다시 reset()을 호출한다
    let idB = UUID()
    let taskB = translator.submit(.final("B문장"), from: .korean, captionID: idB)
    let callB = await refiner2.gate.nextCallStarted()
    refiner2.gate.resume(callB, with: "[번역] B문장 (보정됨)")
    await taskB?.value

    #expect(received == [
        Emission(text: "[번역] A문장", refined: false, captionID: idA),
        Emission(text: "[번역] B문장", refined: false, captionID: idB),
        Emission(text: "[번역] B문장 (보정됨)", refined: true, captionID: idB)
    ])
}

/// 5. 같은 문자열·다른 발화 ID는 각각 보정하고, 같은 발화 ID의 중복 final은 한 번만 보정한다.
///    (순서 자체는 위 `같은_발화의_중복_final은_한_번만_보정한다`와
///    `같은_문장도_다른_발화면_각각_보정한다`가 이미 고정한다. 이 Translator는 화면에
///    한 줄만 보여주는 현재 단계에서 발화당 하나의 세대만 유지하므로, 두 발화를
///    동시에 진행시키는 건 유효한 시나리오가 아니다 — 새 발화 제출은 항상 이전 발화를
///    무효화한다. 그 "새 제출이 이전 응답을 무효화한다"는 동작은 케이스 2·4가 이미 고정한다.)

/// 6. 언어쌍 변경, 캡션 유지 시간 만료 — 둘 다 main.swift에서 동기적으로 reset()을 부른다.
///    대기 중이던 응답은 어느 트리거든 동일하게 버려진다.
@Test @MainActor func 회귀_언어쌍_변경이나_보관_시간_만료_후_늦은_응답은_버려진다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("문장"), from: .korean, captionID: idA)
    let callA = await gate.nextCallStarted()

    // main.swift는 언어쌍이 바뀌거나(자동 감지로 대상이 바뀔 때 포함) 캡션 유지 시간이
    // 만료되면 이 지점에서 동기적으로 reset()을 부른다.
    translator.preferredTargetID = CaptionLanguage.english.id
    translator.reset() // 언어쌍 변경 시점
    gate.resume(callA, with: "[번역] 문장") // 이미 무효화된 요청의 늦은 응답
    await taskA?.value
    #expect(received.isEmpty)

    let idB = UUID()
    let taskB = translator.submit(.final("문장2"), from: .korean, captionID: idB)
    let callB = await gate.nextCallStarted()
    translator.reset() // 캡션 유지 시간 만료 시점 (main.swift의 clearWork)
    gate.resume(callB, with: "[번역] 문장2")
    await taskB?.value

    #expect(received.isEmpty)
}


// MARK: - FIX 7: 취소는 줄 단위다
//
// 예전 Translator는 pending/generation을 전역으로 하나씩만 들고 있어서, 어떤 줄의
// 제출이든 다른 줄의 진행 중 번역을 취소했다. 자막 목록이 옛 발화의 뒤늦은 final을
// 다시 제출하게 되면서(CaptionState.apply) 이게 실제 결함이 됐다: 사용자가 방금 말한
// 줄의 번역이 날아가고, 말을 멈추면 되살릴 다음 이벤트도 없다.

/// (a) 두 줄이 동시에 진행 중이어도 각자 자기 번역을 받는다.
@Test @MainActor func 다른_줄의_제출은_서로의_번역을_취소하지_않는다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: idA)
    let callA = await gate.nextCallStarted()

    let idB = UUID()   // A가 아직 게이트에서 대기 중인데 다른 줄이 제출된다
    let taskB = translator.submit(.final("B문장"), from: .korean, captionID: idB)
    let callB = await gate.nextCallStarted()

    gate.resume(callA, with: "[번역] A문장")
    gate.resume(callB, with: "[번역] B문장")
    await taskA?.value
    await taskB?.value

    #expect(received.count == 2)
    #expect(received.contains(Emission(text: "[번역] A문장", refined: false, captionID: idA)))
    #expect(received.contains(Emission(text: "[번역] B문장", refined: false, captionID: idB)))
}

/// (b) **이 라운드의 회귀 테스트.** 사용자가 방금 말한 줄(B)이 번역 대기 중일 때
///     옛 줄(A)의 뒤늦은 final이 다시 제출된다. 그 뒤 B의 번역이 도착한다.
///
///     테스트는 여기서 끝난다 — 뒤따르는 이벤트가 없다. 화자가 문장을 끝내고 쉬는
///     바로 그 상황이고, 예전 구조라면 B는 영영 번역 없이 남았다.
@Test @MainActor func 옛_줄의_뒤늦은_제출이_방금_말한_줄의_번역을_날리지_않는다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let older = UUID()
    let newest = UUID()

    // 사용자가 방금 말한 줄이 번역 대기 중이다.
    let newestTask = translator.submit(.final("방금 말한 문장"), from: .korean, captionID: newest)
    let newestCall = await gate.nextCallStarted()

    // 그 사이 옛 구간의 final이 뒤늦게 도착해 다시 제출된다(CaptionState.apply 경로).
    let olderTask = translator.submit(.final("옛 문장 확정본"), from: .korean, captionID: older)
    let olderCall = await gate.nextCallStarted()

    gate.resume(newestCall, with: "[번역] 방금 말한 문장")
    await newestTask?.value

    #expect(received.contains(Emission(text: "[번역] 방금 말한 문장", refined: false, captionID: newest)),
            "옛 줄의 제출이 방금 말한 줄의 번역을 취소했다 — 화자가 멈추면 되살릴 이벤트가 없다")

    gate.resume(olderCall, with: "[번역] 옛 문장 확정본")
    await olderTask?.value
    #expect(received.contains(Emission(text: "[번역] 옛 문장 확정본", refined: false, captionID: older)))
}

/// (c) reset()은 여전히 전부 취소한다 — 여러 줄이 떠 있어도 하나도 나가지 않는다.
@Test @MainActor func reset은_진행_중인_모든_줄을_취소한다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: idA)
    let callA = await gate.nextCallStarted()
    let idB = UUID()
    let taskB = translator.submit(.final("B문장"), from: .korean, captionID: idB)
    let callB = await gate.nextCallStarted()

    translator.reset() // 언어쌍 변경·보정기 교체 — 화면의 모든 번역이 무의미해진다

    gate.resume(callA, with: "[번역] A문장")
    gate.resume(callB, with: "[번역] B문장")
    await taskA?.value
    await taskB?.value

    #expect(received.isEmpty)
}

/// (d) 줄 상한을 넘으면 밀려난 줄만 취소되고 나머지는 멀쩡하다.
@Test @MainActor func 줄_상한을_넘으면_밀려난_줄만_취소된다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let limit = Translator.lineLimit
    var ids: [UUID] = []
    var tasks: [Task<Void, Never>?] = []
    var calls: [Int] = []
    for i in 0...limit { // 상한 + 1 줄 → 가장 오래된 줄이 밀려난다
        let id = UUID()
        ids.append(id)
        tasks.append(translator.submit(.final("문장\(i)"), from: .korean, captionID: id))
        calls.append(await gate.nextCallStarted())
    }
    for (i, call) in calls.enumerated() { gate.resume(call, with: "[번역] 문장\(i)") }
    for task in tasks { await task?.value }

    #expect(received.count == limit)
    #expect(!received.contains { $0.captionID == ids[0] }) // 밀려난 줄은 나가지 않는다
    // 방출 "순서"는 게이트를 한꺼번에 풀 때 보장되지 않는다 — 고정할 값은 집합이다.
    #expect(Set(received.map(\.captionID)) == Set(ids.dropFirst()))
}

/// 실측(2026-09~10 자막 로그): 한→영 줄의 "번역"이 원문 한국어와 똑같이 찍혔다.
/// Apple 번역은 그 문장들을 정상 번역하므로, 보정기가 원문 언어로 되돌려 쓴 것이다.
private actor SourceLanguageEchoRefiner: TranslationRefiner {
    func refine(_ draft: String, source: String, context: [String]) async throws -> String {
        source
    }
}

@Test @MainActor func 회귀_보정기가_원문_언어로_답하면_기계_번역을_유지한다() async {
    let translator = Translator(table: .default, translate: { _, _, _ in "And now I don't remember." })
    translator.refiner = SourceLanguageEchoRefiner()
    var received: [(String, Bool)] = []
    translator.onTranslation = { text, refined, _ in received.append((text, refined)) }

    await translator.handle(.final("그리고 이젠 기억이 안 나요."), from: .korean)
    #expect(received.count == 1, "원문 언어로 돌아온 보정은 화면에 반영하면 안 된다")
    #expect(received.first?.0 == "And now I don't remember.")
}

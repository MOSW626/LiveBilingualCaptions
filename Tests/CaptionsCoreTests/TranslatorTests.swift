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

/// 1. partial 요청 → final 요청 → final 응답 → partial의 늦은 응답. 늦게 온 partial 응답은 버려진다.
@Test @MainActor func 회귀_partial_다음_final이_오면_늦게_도착한_partial_응답은_버려진다() async {
    let gate = CallGate<String?>()
    let translator = Translator(table: .default, translate: { text, _, _ in await gate.call() })
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.partial("A문장"), from: .korean, captionID: idA)
    let callA = await gate.nextCallStarted() // A의 220ms 디바운스가 끝나고 translate 안에서 대기 중

    let idB = UUID()
    let taskB = translator.submit(.final("B문장"), from: .korean, captionID: idB)
    let callB = await gate.nextCallStarted()

    gate.resume(callB, with: "[번역] B문장")
    await taskB?.value

    gate.resume(callA, with: "[번역] A문장") // A가 먼저 요청됐지만 응답은 B보다 늦게 도착한다
    await taskA?.value

    #expect(received == [Emission(text: "[번역] B문장", refined: false, captionID: idB)])
}

/// 2. final 초안(A) 표시 → 원문이 B로 갱신 → A의 LLM 보정 응답이 뒤늦게 도착. 버려진다.
@Test @MainActor func 회귀_보정_대기_중_원문이_갱신되면_늦은_보정_응답은_버려진다() async {
    let refiner = GatedRefiner()
    let translator = Translator(table: .default, translate: fakeTranslate)
    translator.refiner = refiner
    var received: [Emission] = []
    translator.onTranslation = { text, refined, id in received.append(Emission(text: text, refined: refined, captionID: id)) }

    let idA = UUID()
    let taskA = translator.submit(.final("A문장"), from: .korean, captionID: idA)
    let callA = await refiner.gate.nextCallStarted() // A의 초안은 이미 나갔고, 보정이 시작된 뒤다

    let idB = UUID()
    let taskB = translator.submit(.final("B문장"), from: .korean, captionID: idB)
    let callB = await refiner.gate.nextCallStarted()

    refiner.gate.resume(callB, with: "[번역] B문장 (보정됨)")
    await taskB?.value

    refiner.gate.resume(callA, with: "[번역] A문장 (보정됨)")
    await taskA?.value

    #expect(received == [
        Emission(text: "[번역] A문장", refined: false, captionID: idA),
        Emission(text: "[번역] B문장", refined: false, captionID: idB),
        Emission(text: "[번역] B문장 (보정됨)", refined: true, captionID: idB)
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

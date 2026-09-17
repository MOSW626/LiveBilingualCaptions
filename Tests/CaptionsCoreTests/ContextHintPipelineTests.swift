import AVFoundation
import Testing
@testable import CaptionsCore

/// `SpeechPipeline`이 확정된 전사로 `ContextHintExtractor`를 먹이고, 세션의 `setContext`를
/// 부르는 배선을 검증한다. 추출 규칙 자체(반복·길이 판정)는 `ContextHintExtractorTests`가
/// 이미 다루므로, 여기서는 "final에서만, 맞는 세션에" 반영되는지만 본다. `Harness`·가짜
/// 세션은 `PipelineControllerTests.swift`의 것을 그대로 쓴다(같은 테스트 타깃).
///
/// 순서 보장: `consume`은 스트림을 한 조각씩 순서대로 처리하고, 매 final마다
/// `await session.setContext(...)`까지 끝낸 뒤에야 다음 조각으로 넘어간다. 그래서 "뒤이어
/// 오는 무해한 final의 transcript 이벤트"를 기다리면(sentinel), 그 앞 final의 컨텍스트
/// 반영이 이미 끝났다고 보장할 수 있다 — sleep 없이 결정적으로.

@Test @MainActor func final에서_반복된_한국어_용어로_setContext가_불린다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    session.emit("발표 관련 공지", isFinal: true, start: 0, end: 1)
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "발표 관련 공지" }; return false }

    session.emit("발표 자료 공유", isFinal: true, start: 1.5, end: 2.5) // "발표" 두 번째 등장 — 이제 채택 조건 충족
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "발표 자료 공유" }; return false }

    // sentinel: 이 final의 transcript 이벤트가 보이면 앞선 final의 setContext 반영도 끝난 뒤다.
    session.emit("확인 완료", isFinal: true, start: 3, end: 3.5)
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "확인 완료" }; return false }

    let calls = session.state.wrapped.contextCalls
    #expect(!calls.isEmpty)
    #expect(calls.contains { $0.contains("발표") })
}

@Test @MainActor func partial은_setContext를_부르지_않는다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    // 4음절 이상이라 final이었다면 한 번만 나와도 채택될 용어를 partial로 흘려본다.
    session.emit("긴급공지사항 발생", isFinal: false, start: 0, end: 1)
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return !e.isFinal && e.text == "긴급공지사항 발생" }; return false }

    // sentinel final — 이게 보이면 위 partial 처리(+ 혹시 모를 컨텍스트 반영)는 이미 끝난 뒤다.
    session.emit("확인 완료", isFinal: true, start: 1.5, end: 2)
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "확인 완료" }; return false }

    let calls = session.state.wrapped.contextCalls
    #expect(!calls.contains { $0.contains("긴급공지사항") }) // partial의 용어는 절대 반영되지 않는다
}

@Test @MainActor func 자동_모드에서는_각_언어가_자기_세션에만_반영된다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig) // 주 언어 한국어, 부 언어 영어
    await harness.waitUntilListening()

    let sessions = harness.engine.sessions.wrapped
    #expect(sessions.count == 2)
    let koreanSession = sessions[0] // primary(한국어)가 먼저 만들어진다
    let englishSession = sessions[1]

    // `DualArbitrator`는 짝이 안 맞는(시간이 먼 ) final을 "다음 final이 도착하는 순간"
    // 곧바로 채택해 흘려보낸다(grace 타이머를 기다리지 않는다) — 그래서 각 final은 그
    // 다음 final이 와야 스트림에 실제로 나온다. 시간 구간을 충분히 벌려(tolerance 밖)
    // 서로 짝짓지 않게 한다.
    koreanSession.emit("로보틱스 로보틱스", isFinal: true, start: 0, end: 1, confidence: 0.9)
    englishSession.emit("Anthropic", isFinal: true, start: 5, end: 6, confidence: 0.9) // 위 한국어 final을 채택시킨다
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "로보틱스 로보틱스" }; return false }

    koreanSession.emit("확인", isFinal: true, start: 10, end: 10.5, confidence: 0.9) // 위 영어 final을 채택시킨다
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal && e.text == "Anthropic" }; return false }

    #expect(koreanSession.state.wrapped.contextCalls.contains { $0.contains("로보틱스") })
    #expect(englishSession.state.wrapped.contextCalls.contains { $0.contains("Anthropic") })
    // 서로 새는 게 없다 — 영어 용어가 한국어 세션에, 한국어 용어가 영어 세션에 들어가지 않는다.
    #expect(!koreanSession.state.wrapped.contextCalls.contains { $0.contains("Anthropic") })
    #expect(!englishSession.state.wrapped.contextCalls.contains { $0.contains("로보틱스") })
}

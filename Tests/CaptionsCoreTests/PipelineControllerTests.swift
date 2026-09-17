import AVFoundation
import Foundation
import Testing
@testable import CaptionsCore

// 이 파일의 테스트는 마이크·디스플레이·Speech 모델 없이 돈다.
// 가짜 소스와 가짜 Speech 세션을 쓰고, 시점은 전부 수동 재개 continuation으로 잡는다.
// sleep 으로 타이밍을 맞추지 않는다.

// MARK: - 공용 도구

/// MainActor 밖에서 만져지는 가짜의 상태를 지키는 최소 상자.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var wrapped: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// 한 번짜리 신호. 기다리는 쪽이 늦게 와도 놓치지 않는다.
@MainActor
final class Signal {
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending = false

    func fire() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pending = true
        }
    }

    func wait() async {
        if pending { pending = false; return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// 절대 안 울리는 grace 시계. `DualArbitrator`의 grace 폴백을 쓰지 않는 대부분의
/// 자동 모드 테스트는 이걸 기본으로 써서, 정상 짝맺기 경로만으로 판정이 끝나게 한다.
/// 진짜 못 끝나는 continuation을 만드는 대신 아주 긴 sleep을 쓴다 — `Task.sleep`은
/// 취소에 정상적으로 반응해서 던지므로(`DualArbitrator`가 짝을 다른 경로로 이미
/// 맺으면 grace 태스크를 취소한다), 실행 중 끝나지 않는 continuation이 안 남는다.
struct NeverGraceClock: DualArbitratorClock {
    func waitGrace() async { try? await Task.sleep(for: .seconds(86_400)) }
}

/// grace 폴백 자체를 테스트할 때 쓰는 가짜 시계 — `Signal`과 같은 fire-then-wait /
/// wait-then-fire 패턴이라 실시간 sleep 없이 결정적으로 "여유가 다 됐다"를 알린다.
/// actor라서 `DualArbitrator`(actor) 안에서도 안전하게 캡처된다.
actor ManualGraceClock: DualArbitratorClock {
    private var continuation: CheckedContinuation<Void, Never>?
    private var firedEarly = false

    func waitGrace() async {
        if firedEarly { firedEarly = false; return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            firedEarly = true
        }
    }
}

enum TestError: LocalizedError {
    case installFailed
    case startFailed
    case reserveFailed

    var errorDescription: String? {
        switch self {
        case .installFailed: "모델 설치 실패"
        case .startFailed: "분석 시작 실패"
        case .reserveFailed: "예약 실패"
        }
    }
}

nonisolated(unsafe) let analysisFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
nonisolated(unsafe) let micFormat48kStereo = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
nonisolated(unsafe) let micFormat44kMono = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

func sine(_ format: AVAudioFormat, frames: AVAudioFrameCount, startFrame: Int = 0) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for index in 0..<Int(frames) {
            let t = Double(startFrame + index) / format.sampleRate
            data[index] = 0.5 * Float(sin(2 * Double.pi * 220 * t))
        }
    }
    return buffer
}

func int16Samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
    let data = buffer.int16ChannelData![0]
    return (0..<Int(buffer.frameLength)).map { data[$0] }
}

// MARK: - 가짜 오디오 소스

@MainActor
final class FakeAudioSource: AudioSource {
    let format: AVAudioFormat
    var startError: (any Error)?
    /// true면 start가 `release()` 또는 취소 전까지 매달린다.
    var blocksUntilReleased = false

    let startSuspended = Signal()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var pending: CheckedContinuation<Void, any Error>?

    init(format: AVAudioFormat = micFormat48kStereo) { self.format = format }

    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        startCount += 1
        self.sink = sink
        if let startError { throw startError }
        if blocksUntilReleased {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    pending = continuation
                    startSuspended.fire()
                }
            } onCancel: {
                // 취소 핸들러가 대기를 푼다 — worker가 시작 완료만 기다리다 멈추지 않도록.
                Task { @MainActor in self.release(throwing: CancellationError()) }
            }
        }
        return format
    }

    func stop() async {
        stopCount += 1
        sink = nil
    }

    func release(throwing error: (any Error)? = nil) {
        guard let pending else { return }
        self.pending = nil
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }

    /// 캡처 콜백을 흉내낸다.
    func emitAudio(frames: AVAudioFrameCount = 4800, startFrame: Int = 0, format: AVAudioFormat? = nil) {
        sink?(sine(format ?? self.format, frames: frames, startFrame: startFrame))
    }
}

// MARK: - 가짜 Speech 엔진

struct SessionPlan: Sendable {
    var installFractions: [Double] = []
    var installFails = false
    var installBlocks = false
    /// `considering:`이 있는 협상이 nil을 돌려준다.
    var consideringNegotiationFails = false
    /// `considering:` 없는 협상도 nil을 돌려준다.
    var plainNegotiationFails = false
    var startFails = false
    var drainsInput = true
    /// true면 drain 태스크가 첫 `next()` 전에 게이트에서 멈춰 소비자를 굶긴다.
    var drainWaitsForGate = false
    var setLanguageSucceeds = true
    /// 실제 세션의 계약: 모듈 교체 전에 진행 중인 발화를 확정해 내보낸다.
    var finalizesOnLanguageSwitch = false
}

final class FakeSpeechEngine: SpeechEngine, @unchecked Sendable {
    struct Behavior: Sendable {
        var supportedLocaleIDs: Set<String> = ["ko-KR", "en-US"]
        var alreadyReservedIDs: [String] = []
        var reserveThrows = false
        var reserveReturns = true
        var plan = SessionPlan()
    }

    let behavior: Locked<Behavior>
    let log = Locked<[String]>([])
    let sessions = Locked<[FakeSpeechSession]>([])
    let sessionCreated = Signal()

    init(_ behavior: Behavior = Behavior()) { self.behavior = Locked(behavior) }

    @MainActor var latestSession: FakeSpeechSession? { sessions.wrapped.last }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        let ids = behavior.wrapped.supportedLocaleIDs
        let normalized = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return ids.contains(normalized) ? Locale(identifier: normalized) : nil
    }

    func reservedLocales() async -> [Locale] {
        behavior.wrapped.alreadyReservedIDs.map { Locale(identifier: $0) }
    }

    func reserve(locale: Locale) async throws -> Bool {
        log.mutate { $0.append("reserve:\(locale.identifier)") }
        if behavior.wrapped.reserveThrows { throw TestError.reserveFailed }
        return behavior.wrapped.reserveReturns
    }

    func release(locale: Locale) async {
        log.mutate { $0.append("release:\(locale.identifier)") }
    }

    func makeSession(locale: Locale, sensitivity: DetectorSensitivity) throws -> any SpeechSession {
        let session = FakeSpeechSession(locale: locale, sensitivity: sensitivity, plan: behavior.wrapped.plan)
        sessions.mutate { $0.append(session) }
        Task { @MainActor in sessionCreated.fire() }
        return session
    }
}

final class FakeSpeechSession: SpeechSession, @unchecked Sendable {
    struct State {
        var installCalls = 0
        var installFinished = false
        var negotiationArguments: [AVAudioFormat?] = []
        var preparedFormat: AVAudioFormat?
        var receivedBuffers: [AVAudioPCMBuffer] = []
        var finishCount = 0
        var languageSwaps: [Locale] = []
        var continuation: AsyncThrowingStream<TranscriptionChunk, any Error>.Continuation?
        var inputError: (any Error)?
        /// `emit(_:)`이 다음 조각에 찍을 값. `start`가 초기값을 심고, `setLanguage`가
        /// 실제 세션처럼 교체 커밋 지점(runID)과 확정 지점(language)에서 갈아끼운다.
        var currentRunID = 0
        var currentLanguage: CaptionLanguage = .korean
    }

    let locale: Locale
    let sensitivity: DetectorSensitivity
    let plan: SessionPlan
    let state = Locked(State())
    let started = Signal()
    let inputFailed = Signal()
    let finished = Signal()
    let drainParked = Signal()
    private let drainGate = Signal()
    /// install이 붙잡아 둔 진행률 콜백. 실패 뒤에도 호출해 "태스크가 남았는지"를 본다.
    private let progressSink = Locked<(@Sendable (Double) -> Void)?>(nil)
    private let installGate = Locked<CheckedContinuation<Void, any Error>?>(nil)
    private let drain = Locked<Task<Void, Never>?>(nil)

    init(locale: Locale, sensitivity: DetectorSensitivity, plan: SessionPlan) {
        self.locale = locale
        self.sensitivity = sensitivity
        self.plan = plan
    }

    func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        state.mutate { $0.installCalls += 1 }
        progressSink.mutate { $0 = progress }
        for fraction in plan.installFractions { progress(fraction) }
        if plan.installBlocks {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    installGate.mutate { $0 = continuation }
                }
            } onCancel: {
                releaseInstall(throwing: CancellationError())
            }
        }
        if plan.installFails { throw TestError.installFailed }
        state.mutate { $0.installFinished = true }
    }

    /// 다운로드가 취소를 무시하고 "완료"되는 상황을 만든다.
    func releaseInstall(throwing error: (any Error)? = nil) {
        guard let continuation = installGate.mutate({ state -> CheckedContinuation<Void, any Error>? in
            defer { state = nil }
            return state
        }) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// 실행이 끝난 뒤에도 진행률을 흘려 본다. 진행률 태스크가 정리됐다면 아무 일도 없다.
    func reportProgressAgain(_ fraction: Double) {
        progressSink.wrapped?(fraction)
    }

    func releaseDrain() { Task { @MainActor in drainGate.fire() } }

    func bestAudioFormat(considering natural: AVAudioFormat?) async -> AVAudioFormat? {
        state.mutate { $0.negotiationArguments.append(natural) }
        if natural != nil { return plan.consideringNegotiationFails ? nil : analysisFormat }
        return plan.plainNegotiationFails ? nil : analysisFormat
    }

    func start(format: AVAudioFormat, input: AudioInputQueue, runID: Int, language: CaptionLanguage) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error> {
        if plan.startFails { throw TestError.startFailed }
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, any Error>.makeStream()
        state.mutate {
            $0.preparedFormat = format
            $0.continuation = continuation
            $0.currentRunID = runID
            $0.currentLanguage = language
        }
        if plan.drainsInput {
            let waitsForGate = plan.drainWaitsForGate
            let task = Task { [state, inputFailed, drainGate, drainParked] in
                do {
                    if waitsForGate {
                        await drainParked.fire()
                        await drainGate.wait()
                    }
                    for try await buffer in input {
                        state.mutate { $0.receivedBuffers.append(buffer) }
                    }
                } catch {
                    state.mutate { $0.inputError = error }
                    continuation.finish(throwing: error)
                    await inputFailed.fire()
                }
            }
            drain.mutate { $0 = task }
        }
        Task { @MainActor in started.fire() }
        return stream
    }

    func setLanguage(_ locale: Locale, runID: Int, language: CaptionLanguage) async throws -> Bool {
        state.mutate { $0.languageSwaps.append(locale) }
        guard plan.setLanguageSucceeds else { return false }
        // 실제 세션과 같은 순서: 커밋 지점에서 runID부터 올린다 — 구제된 final도 새
        // runID를 달고 나가야 controller 필터를 통과한다. language는 아직 옛 값이다.
        state.mutate { $0.currentRunID = runID }
        // 실제 세션은 교체 전에 finalize 해서 진행 중이던 발화를 확정해 내보낸다.
        if plan.finalizesOnLanguageSwitch {
            emit("전환 직전 문장", isFinal: true, start: 0, end: 1.2)
        }
        state.mutate { $0.currentLanguage = language }
        return true
    }

    func finish() async {
        drain.mutate { $0?.cancel(); $0 = nil }
        state.mutate {
            $0.finishCount += 1
            $0.continuation?.finish()
            $0.continuation = nil
        }
        await finished.fire()
    }

    /// 분석기가 결과를 내보내는 것을 흉내낸다. runID·language는 지금 세션이 찍고 있는
    /// "생산 시점" 값을 그대로 쓴다(실제 세션의 pump와 같은 계약). confidence는 자동
    /// 모드 신뢰도 비교(스펙 §2) 테스트에서만 쓴다 — 그 외엔 nil로 둬도 된다.
    func emit(_ text: String, isFinal: Bool, start: Double, end: Double, confidence: Double? = nil) {
        let snapshot = state.wrapped
        snapshot.continuation?.yield(
            TranscriptionChunk(text: text, isFinal: isFinal, start: start, end: end,
                                runID: snapshot.currentRunID, language: snapshot.currentLanguage,
                                confidence: confidence))
    }

    func emitFailure(_ error: any Error) {
        state.wrapped.continuation?.finish(throwing: error)
    }
}

// MARK: - 조립

@MainActor
struct Harness {
    let engine: FakeSpeechEngine
    let pipeline: SpeechPipeline
    let controller: PipelineController
    let events = Locked<[PipelineEvent]>([])
    let states = Locked<[PipelineController.State]>([])
    let sourceBox = Locked<FakeAudioSource?>(nil)
    let sources = Locked<[FakeAudioSource]>([])
    let eventArrived = Signal()
    let stateChanged = Signal()
    let sourceCreated = Signal()

    init(engine: FakeSpeechEngine = FakeSpeechEngine(),
         sourceFormat: AVAudioFormat = micFormat48kStereo,
         blockSourceStarts: Int = 0,
         // 기본값은 "절대 안 울리는" 시계다 — grace 폴백을 안 쓰는 테스트가 실제 시간
         // 경합으로 우연히 흔들리지 않게 한다. grace 자체를 테스트할 때만
         // `ManualGraceClock`을 넘긴다(신호로 결정적으로 통제, PipelineControllerTests
         // 안에서는 실시간 sleep을 쓰지 않는다).
         graceClock: any DualArbitratorClock = NeverGraceClock()) {
        self.engine = engine
        let box = sourceBox
        let created = sourceCreated
        let all = sources
        pipeline = SpeechPipeline(engine: engine, makeSource: { _ in
            let source = FakeAudioSource(format: sourceFormat)
            let index = all.mutate { list -> Int in
                list.append(source)
                return list.count - 1
            }
            // 앞의 N개만 start에서 매달리게 한다.
            source.blocksUntilReleased = index < blockSourceStarts
            box.mutate { $0 = source }
            created.fire()
            return source
        }, autoModeGrace: graceClock)
        controller = PipelineController(pipeline: pipeline)
        let events = self.events
        let states = self.states
        let eventArrived = self.eventArrived
        let stateChanged = self.stateChanged
        controller.onEvent = { event in
            events.mutate { $0.append(event) }
            eventArrived.fire()
        }
        controller.onState = { state in
            states.mutate { $0.append(state) }
            stateChanged.fire()
        }
    }

    var source: FakeAudioSource? { sourceBox.wrapped }

    /// controller가 `.listening`에 도달할 때까지 기다린다. 이벤트로만 진행한다.
    func waitUntilListening() async {
        while controller.state != .listening {
            await stateChanged.wait()
        }
    }

    func waitForState(_ predicate: (PipelineController.State) -> Bool) async {
        while !predicate(controller.state) {
            await stateChanged.wait()
        }
    }

    func waitForEvent(_ predicate: (PipelineEvent) -> Bool) async {
        while !events.wrapped.contains(where: predicate) {
            await eventArrived.wait()
        }
    }

    var installFractions: [Double] {
        events.wrapped.compactMap {
            if case .installing(let fraction) = $0.kind { return fraction }
            return nil
        }
    }

    var transcripts: [TranscriptEvent] {
        events.wrapped.compactMap {
            if case .transcript(let event) = $0.kind { return event }
            return nil
        }
    }
}

let koreanConfig = PipelineConfiguration(source: .microphone, language: .korean, sensitivity: .medium)
let englishConfig = PipelineConfiguration(source: .microphone, language: .english, sensitivity: .medium)
/// 자동 모드 — 한국어를 주 언어로, 영어를 부 언어로 동시에 돌린다(스펙 §2).
let autoConfig = PipelineConfiguration(source: .microphone, language: .korean, sensitivity: .medium,
                                       secondaryLanguage: .english)

// MARK: - A. 포맷 협상과 백프레셔

@Test @MainActor func 협상은_캡처_포맷을_먼저_고려한다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    let arguments = harness.engine.latestSession!.state.wrapped.negotiationArguments
    #expect(arguments.count == 1)
    #expect(arguments[0] === micFormat48kStereo)
}

@Test @MainActor func considering_협상이_실패하면_기본_오버로드로_다시_시도한다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.consideringNegotiationFails = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    let arguments = harness.engine.latestSession!.state.wrapped.negotiationArguments
    #expect(arguments.count == 2)
    #expect(arguments[1] == nil)
}

@Test @MainActor func 협상이_둘_다_실패하면_시작에_실패한다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.consideringNegotiationFails = true
    behavior.plan.plainNegotiationFails = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitForState { if case .failed = $0 { return true }; return false }

    #expect(harness.engine.latestSession!.state.wrapped.preparedFormat == nil)
}

@Test @MainActor func 분석기에는_협상된_포맷이_전달된다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    let prepared = harness.engine.latestSession!.state.wrapped.preparedFormat
    #expect(prepared === analysisFormat)
    #expect(prepared !== micFormat48kStereo)
}

@Test func 사십팔킬로_스테레오_입력이_분석_포맷으로_변환된다() async throws {
    let queue = AudioInputQueue(analysisFormat: analysisFormat)
    let chunk: AVAudioFrameCount = 4800 // 100ms * 10 = 1초
    for index in 0..<10 {
        queue.ingest(sine(micFormat48kStereo, frames: chunk, startFrame: Int(chunk) * index))
    }
    queue.finish()

    var frames = 0
    for try await buffer in queue {
        #expect(buffer.format.sampleRate == 16000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.format.commonFormat == .pcmFormatInt16)
        frames += Int(buffer.frameLength)
    }
    // 리샘플러의 프라이밍 지연 때문에 정확히 맞지는 않는다(5A 테스트와 같은 허용치).
    #expect(abs(frames - 16000) <= 320)
}

@Test func 사십사점일킬로_모노_입력이_분석_포맷으로_변환되고_경계가_이어진다() async throws {
    let queue = AudioInputQueue(analysisFormat: analysisFormat)
    let chunk: AVAudioFrameCount = 4410
    for index in 0..<4 {
        queue.ingest(sine(micFormat44kMono, frames: chunk, startFrame: Int(chunk) * index))
    }
    queue.finish()

    var samples: [Int16] = []
    for try await buffer in queue {
        #expect(buffer.format.sampleRate == 16000)
        #expect(buffer.format.channelCount == 1)
        samples.append(contentsOf: int16Samples(buffer))
    }
    // 0.4초 분량 → 16kHz 기준 6400 프레임 근처.
    #expect(abs(samples.count - 6400) <= 128)
    // 청크 경계에서 위상이 끊기면 인접 샘플 차이가 튄다. 220Hz 사인파의 한 스텝
    // 최대 변화폭은 진폭의 10% 미만이므로 그 몇 배를 넘는 점프가 없어야 한다.
    let jumps = zip(samples, samples.dropFirst()).map { abs(Int($1) - Int($0)) }
    #expect(jumps.max() ?? 0 < 6000)
}

@Test func 입력_포맷이_바뀌면_변환기를_새로_만든다() async throws {
    let queue = AudioInputQueue(analysisFormat: analysisFormat)
    queue.ingest(sine(micFormat48kStereo, frames: 4800))
    queue.ingest(sine(micFormat44kMono, frames: 4410))
    queue.finish()

    var frames = 0
    for try await buffer in queue {
        #expect(buffer.format.sampleRate == 16000)
        frames += Int(buffer.frameLength)
    }
    // 두 입력 모두 0.1초 → 합쳐서 0.2초(≈3200프레임). 포맷 변경을 무시하고 첫 변환기를
    // 계속 썼다면 두 번째 청크가 통째로 사라져 절반 근처에 머문다.
    #expect(frames > 2400)
    #expect(frames < 4000)
}

@Test func 입력_큐가_이초를_넘기면_버리지_않고_오류를_낸다() async throws {
    let queue = AudioInputQueue(analysisFormat: analysisFormat, maximumSeconds: 0.5)
    // 0.5초 상한에 1초를 밀어 넣는다.
    queue.ingest(sine(micFormat48kStereo, frames: 48000))

    var thrown: (any Error)?
    do {
        for try await _ in queue {}
    } catch {
        thrown = error
    }
    #expect(thrown as? AudioInputQueueError == .overflow)
}

@Test @MainActor func 입력_큐가_넘치면_오류를_알리고_실행을_멈춘다() async throws {
    // 소비자(분석기)를 게이트에 묶어 굶긴 채로 2초 상한을 넘겨 실제 PCM을 밀어 넣는다.
    // `AudioInputQueue`의 상한 검사를 지우면 오버플로가 나지 않아 이 테스트는 통과하지 못한다.
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.drainWaitsForGate = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    let session = harness.engine.latestSession!
    await session.drainParked.wait()

    // 실제 탭처럼 100ms 청크로 2.5초를 밀어 넣는다. 분석 포맷(16kHz)에서 약 40000프레임,
    // 상한 32000프레임(2초)을 넘는다.
    for index in 0..<25 {
        harness.source!.emitAudio(frames: 4800, startFrame: 4800 * index)
    }
    session.releaseDrain()

    await harness.waitForState { if case .failed = $0 { return true }; return false }
    #expect(harness.controller.state == .failed(AudioInputQueueError.overflow.localizedDescription))
    #expect(session.state.wrapped.inputError as? AudioInputQueueError == .overflow)
    // 조용히 버리며 계속 돌지 않는다 — 알린 뒤 정지한다.
    await session.finished.wait()
    #expect(session.state.wrapped.finishCount == 1)
    #expect(harness.source!.stopCount == 1)
}

// MARK: - B. 실행 소유권과 취소

@Test @MainActor func 시작_도중_정지하면_캡처가_켜지지_않는다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.installBlocks = true
    let engine = FakeSpeechEngine(behavior)
    let harness = Harness(engine: engine)

    harness.controller.requestStart(configuration: koreanConfig)
    await engine.sessionCreated.wait()
    let session = engine.latestSession!
    // 설치 중에 정지 요청.
    harness.controller.requestStop()
    // 다운로드가 취소를 무시하고 "성공"으로 끝난다.
    session.releaseInstall()

    await harness.waitForState { $0 == .stopped }
    #expect(harness.source == nil)                       // 소스를 만들지도 않았다
    #expect(session.state.wrapped.preparedFormat == nil) // 분석을 시작하지도 않았다
    #expect(harness.controller.state == .stopped)
}

@Test @MainActor func 소스_시작이_매달려_있어도_정지_요청이_교착되지_않는다() async {
    // source.start가 영원히 반환하지 않는 상황. worker가 시작 완료만 기다리면 여기서 멈춘다.
    let harness = Harness(blockSourceStarts: 1)
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.sourceCreated.wait()
    let source = harness.source!
    await source.startSuspended.wait()
    #expect(harness.controller.state == .starting)

    harness.controller.requestStop()
    await harness.waitForState { $0 == .stopped }

    #expect(source.stopCount == 1)
    // 캡처가 시작되지 않았으니 분석도 시작되지 않는다.
    #expect(harness.engine.latestSession!.state.wrapped.preparedFormat == nil)
    #expect(harness.engine.latestSession!.state.wrapped.finishCount == 1)
}

@Test @MainActor func 매달린_시작을_다른_요청이_밀어내도_마지막_요청만_산다() async {
    // 첫 소스만 start에서 매달린다. 그 위로 **경쟁하는 시작 요청**이 들어온다.
    let harness = Harness(blockSourceStarts: 1)
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.sourceCreated.wait()
    let hung = harness.source!
    await hung.startSuspended.wait()

    harness.controller.requestStart(configuration: englishConfig)
    await harness.waitUntilListening()

    // 마지막 요청만 산다.
    let listening = harness.events.wrapped.last { if case .listening = $0.kind { return true }; return false }
    #expect(listening?.kind == .listening(language: .english))
    #expect(harness.engine.sessions.wrapped.count == 2)
    #expect(harness.engine.sessions.wrapped[0].locale.identifier == "ko-KR")
    #expect(harness.engine.sessions.wrapped[1].locale.identifier == "en-US")
    // 매달렸던 첫 실행은 취소 핸들러로 풀려 완전히 정리됐다.
    #expect(harness.engine.sessions.wrapped[0].state.wrapped.finishCount == 1)
    #expect(harness.engine.sessions.wrapped[0].state.wrapped.preparedFormat == nil)
    #expect(hung.stopCount == 1)
    #expect(harness.sources.wrapped.count == 2)
    #expect(harness.sources.wrapped[1].stopCount == 0)
}

@Test @MainActor func 시작_실패는_실패_상태로_보고된다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.startFails = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitForState { if case .failed = $0 { return true }; return false }

    #expect(harness.controller.state == .failed(TestError.startFailed.localizedDescription))
    // 실패해도 잡았던 자원은 같은 순서로 되돌린다.
    #expect(harness.source!.stopCount == 1)
    #expect(harness.engine.latestSession!.state.wrapped.finishCount == 1)
}

@Test @MainActor func 지원하지_않는_언어는_시작에_실패한다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.supportedLocaleIDs = ["en-US"]
    let harness = Harness(engine: FakeSpeechEngine(behavior))

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitForState { if case .failed = $0 { return true }; return false }
    #expect(harness.controller.state == .failed(PipelineError.unsupportedLanguage("한국어").localizedDescription))
}

@Test @MainActor func 연속_전환에서_마지막_요청만_살아남는다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    harness.controller.requestStop()
    harness.controller.requestStart(configuration: englishConfig)
    harness.controller.requestStop()
    harness.controller.requestStart(configuration: koreanConfig)

    await harness.waitUntilListening()
    #expect(harness.controller.state == .listening)
    // 살아남은 실행은 마지막 요청의 언어다.
    let listening = harness.events.wrapped.last { if case .listening = $0.kind { return true }; return false }
    #expect(listening?.kind == .listening(language: .korean))
    // 앞선 실행들은 전부 정리됐다.
    let sessions = harness.engine.sessions.wrapped
    for session in sessions.dropLast() {
        #expect(session.state.wrapped.finishCount >= 1)
    }
}

@Test @MainActor func 이전_실행의_결과와_오류는_무시된다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let stale = harness.engine.latestSession!

    harness.controller.requestStop()
    await harness.waitForState { $0 == .stopped }

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    // 옛 실행이 뒤늦게 결과와 오류를 뱉는다.
    stale.emit("옛 결과", isFinal: true, start: 0, end: 1)
    stale.emitFailure(TestError.startFailed)

    let fresh = harness.engine.latestSession!
    fresh.emit("새 결과", isFinal: false, start: 0, end: 1)
    await harness.waitForEvent { if case .transcript = $0.kind { return true }; return false }

    #expect(harness.transcripts.map(\.text) == ["새 결과"])
    #expect(harness.controller.state == .listening)
}

@Test @MainActor func 다운로드가_실패해도_진행률_태스크가_남지_않는다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.installFractions = [0.25, 0.5]
    behavior.plan.installBlocks = true   // 진행률이 확실히 전달된 뒤에 실패시킨다
    behavior.plan.installFails = true
    let engine = FakeSpeechEngine(behavior)
    let harness = Harness(engine: engine)

    harness.controller.requestStart(configuration: koreanConfig)
    await engine.sessionCreated.wait()
    let failedSession = engine.latestSession!
    while harness.installFractions.count < 2 { await harness.eventArrived.wait() }
    #expect(harness.installFractions == [0.25, 0.5])

    failedSession.releaseInstall()
    await harness.waitForState { if case .failed = $0 { return true }; return false }
    #expect(harness.controller.state == .failed(TestError.installFailed.localizedDescription))

    // 실패한 실행의 진행률 콜백을 다시 두드린다. defer가 스트림을 닫고 reporter를
    // 취소했다면 아무 이벤트도 나오지 않는다. 남아 있다면 0.99가 흘러나온다.
    failedSession.reportProgressAgain(0.99)

    // 여기서 판정을 서두르지 않는다. 다음 실행을 끝까지(=listening) 돌려 MainActor를
    // 여러 번 넘긴 뒤에 본다 — reporter가 살아 있었다면 그 사이에 이벤트가 도착한다.
    engine.behavior.mutate { $0.plan = SessionPlan() }
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    #expect(!harness.installFractions.contains(0.99))
    #expect(harness.installFractions == [0.25, 0.5])
}

@Test @MainActor func 예약이_항상_실패해도_전사는_시작된다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.reserveThrows = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    #expect(harness.engine.log.wrapped.contains("reserve:ko-KR"))
    #expect(harness.engine.latestSession!.state.wrapped.preparedFormat === analysisFormat)
}

@Test @MainActor func 이미_예약된_locale은_다시_예약하지_않는다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.alreadyReservedIDs = ["ko-KR"]
    let harness = Harness(engine: FakeSpeechEngine(behavior))

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    harness.controller.requestStop()
    await harness.waitForState { $0 == .stopped }

    // 예약하지 않았으니 해제도 하지 않는다 — 다른 실행의 예약을 뺏지 않는다.
    #expect(harness.engine.log.wrapped.isEmpty)
}

@Test @MainActor func 이_실행이_예약한_locale은_정지할_때_해제한다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    harness.controller.requestStop()
    await harness.waitForState { $0 == .stopped }

    #expect(harness.engine.log.wrapped == ["reserve:ko-KR", "release:ko-KR"])
}

@Test @MainActor func 언어만_바뀌면_모듈만_교체하고_실행을_유지한다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent { $0.kind == .listening(language: .english) }

    #expect(harness.engine.sessions.wrapped.count == 1)      // 재시작하지 않았다
    #expect(session.state.wrapped.languageSwaps.map(\.identifier) == ["en-US"])
    #expect(session.state.wrapped.finishCount == 0)
    #expect(harness.source!.stopCount == 0)
}

@Test @MainActor func 모듈_교체가_불가능하면_재시작한다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.setLanguageSucceeds = false
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent { $0.kind == .listening(language: .english) }

    #expect(harness.engine.sessions.wrapped.count == 2)
    #expect(harness.engine.sessions.wrapped[0].state.wrapped.finishCount == 1)
}

@Test @MainActor func 민감도가_바뀌면_재시작한다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    var changed = koreanConfig
    changed.sensitivity = .high
    harness.controller.requestReconfigure(configuration: changed)
    await harness.waitForState { $0 == .starting }
    await harness.waitUntilListening()

    #expect(harness.engine.sessions.wrapped.count == 2)
    #expect(harness.engine.sessions.wrapped[1].sensitivity == .high)
}

@Test @MainActor func 시작_요청만으로는_listening_상태가_되지_않는다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.installBlocks = true
    let engine = FakeSpeechEngine(behavior)
    let harness = Harness(engine: engine)

    harness.controller.requestStart(configuration: koreanConfig)
    await engine.sessionCreated.wait()
    #expect(harness.controller.state == .starting)

    engine.latestSession!.releaseInstall()
    await harness.waitUntilListening()
}

// MARK: - C. 전사 이벤트 식별

@Test func 같은_구간의_갱신과_final은_같은_발화다() {
    var ledger = UtteranceLedger()
    let first = ledger.assign(start: 0, end: 1, isFinal: false)
    let second = ledger.assign(start: 0, end: 2, isFinal: false)
    let third = ledger.assign(start: 0, end: 2.4, isFinal: true)

    #expect(first.id == second.id)
    #expect(second.id == third.id)
    #expect(first.revision == 0)
    #expect(second.revision == 1)
    #expect(third.revision == 2)
}

@Test func 같은_문장을_다른_구간에서_두_번_말하면_다른_발화다() {
    var ledger = UtteranceLedger()
    let first = ledger.assign(start: 0, end: 1.5, isFinal: true)
    let second = ledger.assign(start: 3, end: 4.5, isFinal: true)
    #expect(first.id != second.id)
}

@Test func 확정_뒤의_같은_시작_구간은_새_발화다() {
    var ledger = UtteranceLedger()
    let first = ledger.assign(start: 0, end: 1, isFinal: true)
    let second = ledger.assign(start: 0, end: 1, isFinal: false)
    #expect(first.id != second.id)
}

@Test func 언어를_바꾸면_이전_발화에_잇지_않는다() {
    var ledger = UtteranceLedger()
    let before = ledger.assign(start: 0, end: 1, isFinal: false)
    ledger.breakUtterance()
    let after = ledger.assign(start: 0, end: 1.2, isFinal: false)
    #expect(before.id != after.id)
}

// 실사용 스크린샷 3장 전부에서 관찰된 버그의 재현: 같은 문장이 번역까지 붙은 줄과
// 번역 없는 줄, 두 줄로 겹쳐 보였다(아래쪽 — 화면에서 가장 밝은, 즉 가장 최근 줄에
// 번역이 없었다). 원인은 `assign`이 흔들림을 "최초" 시작 시각 기준으로 재는 것이었다.
// 문장부호 없이 여러 문장을 한 final로 묶어 내보내는 긴 발화(특히 한국어)는 volatile
// 조각마다 보고되는 시작 시각이 조금씩(허용치 0.2초 안쪽) 밀릴 수 있는데, 그 조각별
// 흔들림이 누적되면 최초 값과는 결국 허용치를 넘는다 — final이 자기 발화를 못 찾고
// 새 발화(새 UUID, 번역 없음)로 떨어져 나간다. 이 테스트는 조각마다 0.15초씩(허용치
// 0.2초 안쪽) 밀리지만 누적하면 최초 대비 0.3초(허용치 초과)가 되는 시퀀스로 그
// 상황을 재현한다 — 수정 전에는 마지막 줄에서 새 id가 나와 실패했다.
@Test func 서서히_흔들리는_시작_시각도_같은_발화로_남는다() {
    var ledger = UtteranceLedger()
    let a = ledger.assign(start: 0.0, end: 1.0, isFinal: false)
    let b = ledger.assign(start: 0.15, end: 2.0, isFinal: false)  // 최초 대비 0.15초 — 허용치 안
    let c = ledger.assign(start: 0.3, end: 3.0, isFinal: true)    // 최초 대비 0.3초 — 직전 대비로는 0.15초
    #expect(a.id == b.id)
    #expect(b.id == c.id) // 누적이 아니라 "직전 조각 대비" 허용치로 비교해야 한다
}

@Test @MainActor func 전사_이벤트는_실행ID_발화ID_언어를_함께_싣는다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    session.emit("안녕", isFinal: false, start: 0, end: 1)
    session.emit("안녕하세요", isFinal: true, start: 0, end: 1.4)
    await harness.waitForEvent { if case .transcript(let e) = $0.kind { return e.isFinal }; return false }

    let events = harness.transcripts
    #expect(events.count == 2)
    #expect(events[0].utteranceID == events[1].utteranceID)
    #expect(events.allSatisfy { $0.sourceLanguage == .korean })
    #expect(harness.events.wrapped.allSatisfy { $0.runID == harness.controller.currentGeneration })
}

@Test @MainActor func 교차_도착한_옛_구간의_final은_옛_줄에_붙고_최신_줄은_그대로다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    session.emit("첫 문장", isFinal: false, start: 0, end: 1)
    session.emit("두 번째 문장", isFinal: false, start: 2, end: 3)     // 다음 구간이 먼저 도착
    session.emit("첫 문장입니다", isFinal: true, start: 0, end: 1.5)   // 옛 구간의 final이 뒤늦게
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "첫 문장입니다" }
        return false
    }

    let events = harness.transcripts
    #expect(events.count == 3)
    #expect(events[0].utteranceID != events[1].utteranceID)
    #expect(events[2].utteranceID == events[0].utteranceID)  // 옛 구간의 final은 옛 발화에 붙는다

    // 최신 원문은 되돌아가지 않고, 옛 구간의 갱신에는 표시가 붙는다.
    var latest = LatestCaption()
    let updates = events.map { latest.apply($0) }
    #expect(latest.text == "두 번째 문장")
    #expect(updates.map(\.isOutdated) == [false, false, true])

    // 목록 UI 는 그 뒤늦은 final 을 버리지 않는다 — 사용자가 읽고 있는 게 그 줄이다.
    // 옛 줄이 확정본으로 갱신되고, 최신 줄은 손대지 않는다.
    let state = CaptionState()
    for event in events { _ = state.apply(event) }
    #expect(state.entries.count == 2)
    #expect(state.entries[0].original == "첫 문장입니다")
    #expect(state.entries[0].isFinal)
    #expect(state.entries[1].original == "두 번째 문장")
    #expect(!state.entries[1].isFinal)
}

@Test @MainActor func 언어_전환_뒤의_이벤트는_새_언어를_싣는다() async {
    // 하드코딩한 이벤트가 아니라 controller를 거친 실제 전환으로 확인한다.
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    session.emit("전환 전 문장", isFinal: true, start: 0, end: 1)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 전 문장" }
        return false
    }

    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent { $0.kind == .listening(language: .english) }
    #expect(harness.engine.sessions.wrapped.count == 1) // 같은 실행을 유지한 채 전환

    session.emit("after the switch", isFinal: true, start: 4, end: 5)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "after the switch" }
        return false
    }

    let events = harness.transcripts
    #expect(events.count == 2)
    // 언어는 이벤트 생성 시점 값으로 고정된다 — 전환이 과거 이벤트를 소급하지 않는다.
    #expect(events[0].sourceLanguage == .korean)
    #expect(events[1].sourceLanguage == .english)
    #expect(events[0].utteranceID != events[1].utteranceID)
}

@Test @MainActor func 언어_전환_직전의_발화는_확정돼_전달된다() async {
    // 교체 전 finalize 결과를 버리면 사용자가 말하던 문장이 통째로 사라진다.
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.finalizesOnLanguageSwitch = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 직전 문장" }
        return false
    }

    let event = harness.transcripts.first { $0.text == "전환 직전 문장" }
    #expect(event?.isFinal == true)
    // 확정된 문장은 전환 전 언어로 남는다.
    #expect(event?.sourceLanguage == .korean)
    await harness.waitForEvent { $0.kind == .listening(language: .english) }
}

// MARK: - C-1. 실행 정체성은 생산 시점에 찍는다 (2026-09-17 야간 보완 #1)

@Test @MainActor func 성공한_전환의_구제된_final은_옛_언어를_첫_조각은_새_언어를_싣는다() async {
    // 언어 전환 도중에는 같은 실행 안에서 구제된 final(옛 언어)과 새 pump의 첫 조각
    // (새 언어)이 같은 스트림으로 섞여 나온다. run.language를 emit 시점에 live로
    // 읽으면 이 둘을 구별하지 못한다 — 조각 자신이 생산 시점에 찍은 값만 믿어야 한다.
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.finalizesOnLanguageSwitch = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 직전 문장" }
        return false
    }
    await harness.waitForEvent { $0.kind == .listening(language: .english) }

    session.emit("전환 뒤 첫 조각", isFinal: false, start: 2, end: 2.5)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 뒤 첫 조각" }
        return false
    }

    let rescued = harness.transcripts.first { $0.text == "전환 직전 문장" }!
    let afterSwitch = harness.transcripts.first { $0.text == "전환 뒤 첫 조각" }!
    #expect(rescued.sourceLanguage == .korean)     // 구제된 final은 여전히 옛 언어
    #expect(afterSwitch.sourceLanguage == .english) // 새 pump의 첫 조각은 새 언어
}

@Test @MainActor func 실패한_언어_전환의_유령_청크는_재시작한_새_Run과_runID가_겹치지_않는다() async {
    // controller를 거치지 않고 SpeechPipeline을 바로 몬다 — controller 자체의
    // runID==generation 필터가 결함이 있는 값도 우연히 걸러버려 버그를 가릴 수 있어서,
    // 결함이 있는 그 값 자체(PipelineEvent.runID)를 직접 살펴야 한다.
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.setLanguageSucceeds = false
    let engine = FakeSpeechEngine(behavior)
    let pipeline = SpeechPipeline(engine: engine, makeSource: { _ in FakeAudioSource() })
    var events: [PipelineEvent] = []
    let signal = Signal()
    pipeline.onEvent = { event in
        events.append(event)
        signal.fire()
    }

    await pipeline.start(koreanConfig, generation: 1)
    while !events.contains(where: { $0.kind == .listening(language: .korean) }) { await signal.wait() }
    let oldSession = engine.latestSession!

    // 세션 수준에서 실패할 교체를 시도하기 전, 옛 pump가 이미 만들어 내보낸 조각 —
    // 전환과 무관하게 큐에 있던, 뒤늦게 도착하는 결과를 흉내낸다.
    oldSession.emit("유령 청크", isFinal: false, start: 0, end: 0.5)
    while !events.contains(where: { if case .transcript(let e) = $0.kind { return e.text == "유령 청크" }; return false }) {
        await signal.wait()
    }
    let ghost = events.first { if case .transcript(let e) = $0.kind { return e.text == "유령 청크" }; return false }!

    let swapped = await pipeline.switchLanguage(to: .english, generation: 2)
    #expect(swapped == false)

    // PipelineController.drain()과 같은 순서: 실패하면 정지 후 같은 generation으로
    // 재시작한다(generation은 실패한 시도에서도 이미 올라 있었다).
    await pipeline.stop()
    await pipeline.start(englishConfig, generation: 2)
    while !events.contains(where: { $0.kind == .listening(language: .english) }) { await signal.wait() }
    let newListening = events.last { $0.kind == .listening(language: .english) }!

    #expect(ghost.runID == 1)          // 유령 청크는 옛 run의 id를 그대로 유지한다
    #expect(newListening.runID == 2)   // 재시작한 새 Run은 새 generation을 쓴다
    #expect(ghost.runID != newListening.runID) // 겹치지 않는다 — 핵심 단정
}

// MARK: - D. 목록 UI 연동(CaptionState) — FIX 2 회귀
//
// hot swap(위 테스트)은 같은 Run.ledger를 그대로 쓴다 — breakUtterance()는 finalize만
// 하고 nextID는 이어진다. 그래서 말하는 도중 전환된 문장의 "구제된 final"은 그 문장이
// 아직 partial이던 동안 받은 것과 **같은 utteranceID**로 돌아온다. AppDelegate 쪽 계약은
// "그 사이에 CaptionState의 발화 ID 장부(resetLedger)를 비우지 않는다"이다 — 비우면
// 구제된 final이 자기 줄을 못 찾아 새 UUID로 떨어지고, 옛 줄(미번역)이 위에 남아 같은
// 문장이 화면에 두 번 보인다. 이 테스트는 장부를 비우지 않았을 때 한 줄로 남는다는
// 계약 자체를 고정한다 — AppDelegate.apply(_:)는 이 계약을 지키는 쪽(hot swap이면
// resetLedger 호출 생략)으로 고쳤다.
@Test @MainActor func 말하는_도중_언어를_바꿔도_한_줄에만_반영된다() async {
    var behavior = FakeSpeechEngine.Behavior()
    behavior.plan.finalizesOnLanguageSwitch = true
    let harness = Harness(engine: FakeSpeechEngine(behavior))
    let state = CaptionState()
    let translator = Translator(table: .default, translate: { text, _, _ in "번역:\(text)" })
    var translated: [UUID: String] = [:]
    translator.onTranslation = { text, _, id in translated[id] = text }

    @discardableResult
    func show(_ event: TranscriptEvent) -> Task<Void, Never>? {
        var last: Task<Void, Never>?
        for update in state.apply(event) {
            last = translator.submit(update.transcript, from: event.sourceLanguage, captionID: update.id)
        }
        return last
    }

    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()
    let session = harness.engine.latestSession!

    // 말하는 도중의 partial. 가짜 세션이 hot swap 때 내보내는 구제된 final의 구간(0~1.2)과
    // 겹치도록 시작 시각을 맞춘다 — 실제로도 전환은 진행 중인 발화 위에서 일어난다.
    session.emit("전환 직전", isFinal: false, start: 0, end: 0.8)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 직전" }
        return false
    }
    show(harness.transcripts[0])
    #expect(state.entries.count == 1)
    let originalID = state.entries[0].id

    // 말하는 도중 언어를 바꾼다 — hot swap 조건(소스·민감도 동일, 듣는 중)을 만족해
    // 같은 실행(Run)이 이어진다.
    harness.controller.requestReconfigure(configuration: englishConfig)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "전환 직전 문장" }
        return false
    }
    #expect(harness.engine.sessions.wrapped.count == 1) // 재시작하지 않았다 — 세션이 하나다

    // 구제된 final. AppDelegate는 이 순간까지 장부를 비우지 않아야 한다(FIX 2) —
    // 여기서는 그 계약을 직접 지켜서 결과를 고정한다.
    let rescued = harness.transcripts.first { $0.text == "전환 직전 문장" }!
    let task = show(rescued)
    await task?.value

    #expect(state.entries.count == 1)              // 중복 줄이 생기지 않는다
    #expect(state.entries[0].id == originalID)      // 같은 줄이 갱신됐다 — 새 줄이 아니다
    #expect(state.entries[0].original == "전환 직전 문장")
    #expect(state.entries[0].isFinal)
    #expect(translated[originalID] == "번역:전환 직전 문장") // 번역도 그 줄에 붙는다

    await harness.waitForEvent { $0.kind == .listening(language: .english) }
}

// MARK: - E. 자동 모드 — 두 세션 신뢰도 중재 (2026-09-17 야간 §2)
//
// 자동 모드는 한 실행 안에서 세션을 **두 벌** 만든다(하드 제약: 분석기 하나에 전사기
// 둘은 SIGTRAP). `harness.engine.sessions.wrapped[0]`이 주 언어(한국어), `[1]`이 부
// 언어(영어)다 — startDualRun이 그 순서로 만든다.

@Test @MainActor func 자동_모드는_세션을_두_벌_만든다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()

    #expect(harness.engine.sessions.wrapped.count == 2)
    #expect(harness.engine.sessions.wrapped[0].locale.identifier == "ko-KR")
    #expect(harness.engine.sessions.wrapped[1].locale.identifier == "en-US")
}

@Test @MainActor func 자동_모드에서_신뢰도가_높은_쪽이_채택되고_진_쪽은_버려진다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    ko.emit("안녕하세요", isFinal: true, start: 0, end: 1, confidence: 0.4)
    en.emit("annyeonghaseyo", isFinal: true, start: 0, end: 1, confidence: 0.9)

    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.isFinal }
        return false
    }

    let finals = harness.transcripts.filter(\.isFinal)
    #expect(finals.count == 1) // 진 쪽(한국어)의 줄은 CaptionState까지 절대 오지 않는다
    #expect(finals[0].sourceLanguage == .english)
    #expect(finals[0].text == "annyeonghaseyo")
}

@Test @MainActor func 자동_모드에서_동점이면_직전_승자를_유지한다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    // 첫 발화: 한국어가 이긴다 — 이후 "직전 승자"가 된다.
    ko.emit("첫 문장", isFinal: true, start: 0, end: 1, confidence: 0.9)
    en.emit("first", isFinal: true, start: 0, end: 1, confidence: 0.2)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "첫 문장" }
        return false
    }

    // 두 번째 발화: 신뢰도가 동점이다 — 직전 승자(한국어)를 유지해야 한다.
    ko.emit("두번째", isFinal: true, start: 3, end: 4, confidence: 0.5)
    en.emit("second", isFinal: true, start: 3, end: 4, confidence: 0.5)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "두번째" }
        return false
    }

    let finals = harness.transcripts.filter(\.isFinal)
    #expect(finals.count == 2)
    #expect(finals[1].sourceLanguage == .korean)
    #expect(finals[1].text == "두번째")
}

@Test @MainActor func 자동_모드에서_한쪽이_실패해도_다른_쪽은_막히지_않는다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    ko.emitFailure(TestError.startFailed) // 한국어 쪽 결과 스트림이 죽는다

    en.emit("still working", isFinal: true, start: 0, end: 1, confidence: 0.7)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "still working" }
        return false
    }

    let finals = harness.transcripts.filter(\.isFinal)
    #expect(finals.contains { $0.text == "still working" && $0.sourceLanguage == .english })
    #expect(harness.controller.state == .listening) // 한쪽 실패가 전체 실행을 넘어뜨리지 않는다

    // 산 쪽이 계속 final을 내도 죽은 상대를 기다리며 막히지 않고 계속 흘러간다.
    en.emit("still working two", isFinal: true, start: 3, end: 4, confidence: 0.7)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "still working two" }
        return false
    }
}

// 코드 리뷰 F1: 승자가 아직 없을 때(첫 발화가 아직 안 끝났을 때) partial을 한쪽만
// 보여주면, 그 한쪽이 콜드 스타트로 느리거나 조용한 경우 화면이 통째로 비어 보일 수
// 있다. 승자가 없는 동안은 양쪽 partial을 다 흘려보내고, 승자가 한 번 정해진 뒤에야
// 그 언어만 보여준다.
@Test @MainActor func 승자가_아직_없으면_양쪽_partial이_다_화면에_뜬다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    // 아직 아무 발화도 확정되지 않았다 — 화면이 비지 않도록 둘 다 보여야 한다.
    ko.emit("듣는 중", isFinal: false, start: 0, end: 0.5)
    en.emit("listening", isFinal: false, start: 0, end: 0.5)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "listening" }
        return false
    }

    #expect(harness.transcripts.map(\.text) == ["듣는 중", "listening"])
}

@Test @MainActor func 승자가_정해진_뒤에는_진_쪽의_다음_partial이_버려진다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    // 첫 발화를 확정해 승자(한국어)를 정한다.
    ko.emit("첫 문장", isFinal: true, start: 0, end: 1, confidence: 0.9)
    en.emit("first", isFinal: true, start: 0, end: 1, confidence: 0.2)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "첫 문장" }
        return false
    }

    // 다음 발화의 partial — 영어(진 쪽) partial은 이제 버려진다.
    ko.emit("두 번째 듣는 중", isFinal: false, start: 3, end: 3.5)
    en.emit("second listening", isFinal: false, start: 3, end: 3.5)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "두 번째 듣는 중" }
        return false
    }

    #expect(harness.transcripts.map(\.text) == ["첫 문장", "두 번째 듣는 중"])
}

// 코드 리뷰 F1: `awaiting`은 짝이 영영 안 올 수 있다(상대가 멎었을 때) — grace 시계가
// 다 되면 무한정 기다리지 않고 기다리던 쪽을 그대로 채택한다. 실시간 sleep 대신
// `ManualGraceClock`을 주입해 "여유가 다 됐다"를 신호로 결정적으로 알린다.
@Test @MainActor func 상대가_영원히_조용해도_grace가_지나면_먼저_온_final을_채택한다() async {
    let clock = ManualGraceClock()
    let harness = Harness(graceClock: clock)
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    // en은 끝까지 아무것도 내지 않는다(콜드 스타트로 죽은 것처럼) — sideEnded도 안 부른다.

    ko.emit("한국어만 말했다", isFinal: true, start: 0, end: 1, confidence: 0.8)
    // en은 끝까지 짝을 주지 않는다 — grace가 없다면 이 final은 영원히 `awaiting`에
    // 머문다. 시계를 울려 "여유가 다 됐다"를 알리면 그제서야 채택돼 나온다.
    await clock.fire()
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "한국어만 말했다" }
        return false
    }

    #expect(harness.transcripts.map(\.text) == ["한국어만 말했다"])
    #expect(harness.transcripts[0].sourceLanguage == .korean)
}

@Test @MainActor func 고정_모드는_자동_모드_도입_뒤에도_그대로다() async {
    // 고정 모드는 여전히 세션 하나만 만들고, confidence 필드는 아무 영향이 없다.
    let harness = Harness()
    harness.controller.requestStart(configuration: koreanConfig)
    await harness.waitUntilListening()

    #expect(harness.engine.sessions.wrapped.count == 1)
    let session = harness.engine.sessions.wrapped[0]
    session.emit("고정 모드 문장", isFinal: true, start: 0, end: 1)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "고정 모드 문장" }
        return false
    }
    #expect(harness.transcripts.map(\.text) == ["고정 모드 문장"])
}

// 버그 회귀(en.aiff 실측 프로브에서 재현): 승자가 이미 정해진 뒤에도 진 쪽 전사기가
// 뒤늦게 "처음부터 끝까지"를 한 덩어리로 오인식한 final을 내보낼 수 있다(그 언어로
// 듣기엔 말이 안 되는 오디오라 문장 경계를 하나도 못 찾고 전체를 한 발화로 묶는다).
// 그 덩어리가 짝 없이 채택돼 승자의 세 번째 문장 뒤에 엉뚱한 네 번째 줄로 붙었다 —
// 사용자에게는 "영어가 이상한 줄로 끝난다"로 보였다. 짝 없는 final은 이미 채택된
// 구간보다 한참 앞에서 시작하면(진 쪽의 뒤늦은 덩어리) 버리고, 승자의 나머지 문장들은
// (짝이 없어도 새 구간이면) 전부 반영돼야 한다. grace 타이머 없이도(=NeverGraceClock)
// "다음 final이 짝이 아니다" 경로만으로 전부 결정되게 짰다 — 실시간 대기가 필요 없다.
@Test @MainActor func 승자의_연속된_세_final은_전부_반영되고_진_쪽의_뒤늦은_통짜_final은_버려진다() async {
    let harness = Harness()
    harness.controller.requestStart(configuration: autoConfig)
    await harness.waitUntilListening()
    let ko = harness.engine.sessions.wrapped[0]
    let en = harness.engine.sessions.wrapped[1]

    // 첫 문장 — 짝을 맞춰 영어가 이긴다(승자 확정).
    en.emit("Hello, everyone.", isFinal: true, start: 0, end: 1, confidence: 0.9)
    ko.emit("garbage1", isFinal: true, start: 0, end: 1, confidence: 0.3)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "Hello, everyone." }
        return false
    }

    // 두 번째 문장 — 진 쪽의 partial은 이미 승자가 있어서 버려진다.
    en.emit("Let us start today's meeting.", isFinal: false, start: 1.08, end: 2)
    ko.emit("안 들림", isFinal: false, start: 1.08, end: 2)
    en.emit("Let us start today's meeting.", isFinal: true, start: 1.08, end: 3.0, confidence: 0.9)
    ko.emit("garbage2", isFinal: true, start: 1.08, end: 3.0, confidence: 0.3)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "Let us start today's meeting." }
        return false
    }

    // 세 번째 문장 — 이번엔 진 쪽이 짝을 안 준다(승자 final은 짝 없이 새 구간이라
    // 그대로 채택돼야 한다). 그 대신 한참 뒤에 처음부터 끝까지 통째로 오인식한
    // 덩어리 final을 내보낸다(실제 버그 재현). 세 번째 문장의 짝-없음은 뒤이어 오는
    // 그 덩어리가 "짝이 아니다"로 판정되면서 함께 흘러나온다.
    en.emit("The 1st item is the schedule.", isFinal: true, start: 3.06, end: 5.34, confidence: 0.9)
    ko.emit("hello everyone let a star today meeting the first item is the schedule",
            isFinal: true, start: 0, end: 5.76, confidence: 0.8)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "The 1st item is the schedule." }
        return false
    }

    // 덩어리가 버려졌다는 걸 "아직 안 왔을 뿐"과 구별하려면 뒤이은 정상 발화가
    // 필요하다 — 그 발화가 도착하면 덩어리는 이미 "짝이 아니다" 경로로 처리된 뒤다.
    en.emit("epilogue", isFinal: true, start: 6, end: 6.5, confidence: 0.9)
    ko.emit("정크", isFinal: true, start: 6, end: 6.5, confidence: 0.2)
    await harness.waitForEvent {
        if case .transcript(let e) = $0.kind { return e.text == "epilogue" }
        return false
    }

    let finals = harness.transcripts.filter(\.isFinal)
    #expect(finals.map(\.text) == [
        "Hello, everyone.", "Let us start today's meeting.", "The 1st item is the schedule.", "epilogue",
    ])
    #expect(finals.allSatisfy { $0.sourceLanguage == .english })
}

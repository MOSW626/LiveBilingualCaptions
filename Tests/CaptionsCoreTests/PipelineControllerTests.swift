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

    func start(format: AVAudioFormat, input: AudioInputQueue) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error> {
        if plan.startFails { throw TestError.startFailed }
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, any Error>.makeStream()
        state.mutate {
            $0.preparedFormat = format
            $0.continuation = continuation
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

    func setLanguage(_ locale: Locale) async throws -> Bool {
        state.mutate { $0.languageSwaps.append(locale) }
        guard plan.setLanguageSucceeds else { return false }
        // 실제 세션은 교체 전에 finalize 해서 진행 중이던 발화를 확정해 내보낸다.
        if plan.finalizesOnLanguageSwitch {
            emit("전환 직전 문장", isFinal: true, start: 0, end: 1.2)
        }
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

    /// 분석기가 결과를 내보내는 것을 흉내낸다.
    func emit(_ text: String, isFinal: Bool, start: Double, end: Double) {
        state.wrapped.continuation?.yield(
            TranscriptionChunk(text: text, isFinal: isFinal, start: start, end: end))
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
         blockSourceStarts: Int = 0) {
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
        })
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

@Test @MainActor func 전사_이벤트는_실행ID_발화ID_수정번호_언어를_함께_싣는다() async {
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
    #expect(events[0].revision == 0 && events[1].revision == 1)
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
        guard let id = state.apply(event) else { return nil }
        return translator.submit(event.transcript, from: event.sourceLanguage, captionID: id)
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

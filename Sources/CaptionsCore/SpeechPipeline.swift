import AVFoundation
import Foundation
import Speech

// MARK: - 설정 스냅샷

/// 한 번의 실행이 쓰는 값들. 설정이 바뀌면 새 스냅샷을 만들어 controller에 넘긴다.
public struct PipelineConfiguration: Sendable, Equatable {
    public var source: AudioSourceKind
    public var language: CaptionLanguage
    public var sensitivity: DetectorSensitivity

    public init(source: AudioSourceKind, language: CaptionLanguage, sensitivity: DetectorSensitivity) {
        self.source = source
        self.language = language
        self.sensitivity = sensitivity
    }
}

// MARK: - 이벤트

/// 전사 한 조각. `Transcript`의 partial/final 구분은 그대로 두고 식별자만 덧붙인다.
///
/// `utteranceID`는 오디오 시간 구간으로 매긴다(문자열 일치가 아니다) — 같은 문장을
/// 두 번 말하면 서로 다른 발화이고, 같은 구간의 volatile 갱신과 final은 같은 발화다.
/// `sourceLanguage`는 이벤트를 만든 시점의 값으로 고정한다. 나중에 언어를 바꿔도
/// 이미 나간 이벤트의 번역 대상은 흔들리지 않는다.
public struct TranscriptEvent: Sendable, Equatable {
    public let utteranceID: Int
    public let revision: Int
    public let sourceLanguage: CaptionLanguage
    public let transcript: Transcript

    public var text: String { transcript.text }
    public var isFinal: Bool { transcript.isFinal }

    public init(utteranceID: Int, revision: Int, sourceLanguage: CaptionLanguage, transcript: Transcript) {
        self.utteranceID = utteranceID
        self.revision = revision
        self.sourceLanguage = sourceLanguage
        self.transcript = transcript
    }
}

/// 파이프라인이 UI에 알리는 것 전부. 모든 이벤트가 실행 ID를 달고 있어서
/// 뒤늦게 도착한 옛 실행의 이벤트를 걸러낼 수 있다.
public struct PipelineEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case installing(fraction: Double)
        case listening(language: CaptionLanguage)
        case transcript(TranscriptEvent)
        case failed(message: String)
    }

    public let runID: Int
    public let kind: Kind

    public init(runID: Int, kind: Kind) {
        self.runID = runID
        self.kind = kind
    }
}

// MARK: - 지연 계측 (LBC_TIMING=1)

/// 평소엔 완전히 꺼져 있는 지연 로그. 환경 변수는 정적 초기화 시 1번만 읽는다.
/// 실시간 오디오 콜백에서 쓰는 건 `AudioSinkGate`의 타임스탬프 기록 한 줄뿐이고,
/// 그마저 `enabled`가 꺼져 있으면 평가되지 않는다 — 포맷팅·stderr 쓰기는 전부
/// 콜백 밖(`consume`, 시작 절차)에서 일어난다.
enum LatencyTiming {
    static let enabled = ProcessInfo.processInfo.environment["LBC_TIMING"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[LBC_TIMING] \(message())\n".utf8))
    }
}

public enum PipelineError: LocalizedError, Equatable {
    case unsupportedLanguage(String)
    case noCompatibleFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let name): "\(name) 전사 모델을 지원하지 않습니다"
        case .noCompatibleFormat: "호환되는 오디오 형식을 찾지 못했습니다"
        }
    }
}

// MARK: - 발화 식별

/// 오디오 시간 구간으로 발화를 구분한다.
///
/// 규칙은 **시작 시각**이다. volatile 갱신은 같은 발화의 시작 시각 근처를 유지하며
/// 끝만 늘리고, 다음 발화는 이전 발화가 끝난 자리에서 새 시작 시각으로 온다. 그래서
/// 시작 시각이 (오차 범위 안에서) 같고 아직 확정되지 않은 발화에만 갱신을 붙인다.
/// 문자열을 보지 않으므로 같은 문장을 두 번 말해도 두 발화로 남고, 확정된 구간의
/// final이 뒤늦게 도착해도 그 사이에 시작된 새 발화를 덮어쓰지 않는다.
///
/// 비교 기준은 **최초** 시작 시각이 아니라 **직전에 맞춰본** 시작 시각이다(아래
/// `assign`이 매번 갱신한다). 긴 발화(특히 문장부호 없이 여러 문장을 묶어 내보내는
/// 한국어 final)는 volatile 조각마다 보고되는 시작 시각이 조금씩 밀릴 수 있는데,
/// 그 흔들림을 최초 값에 고정해 비교하면 한 조각씩은 허용치 안이어도 누적으로는
/// 허용치를 넘어버린다 — final이 자기 발화를 못 찾고 새 발화로 떨어져 나가, 사용자
/// 눈에는 같은 문장이 번역 없는 줄로 화면에 중복 표시된다(실사용 스크린샷에서 관찰된
/// 버그의 원인). 직전 값과 비교하면 조각 사이의 흔들림만 허용치 안이면 되므로 이
/// 누적 드리프트를 흡수한다.
public struct UtteranceLedger: Sendable {
    public struct Assignment: Sendable, Equatable {
        public let id: Int
        public let revision: Int
    }

    private struct Entry {
        var id: Int
        var start: Double
        var end: Double
        var revision: Int
        var finalized: Bool
    }

    private var entries: [Entry] = []
    private var nextID = 1
    private let tolerance: Double

    /// `tolerance`는 구간 경계의 흔들림을 흡수한다(초).
    public init(tolerance: Double = 0.2) { self.tolerance = tolerance }

    public mutating func assign(start: Double, end: Double, isFinal: Bool) -> Assignment {
        if let index = entries.lastIndex(where: { !$0.finalized && abs($0.start - start) <= tolerance }) {
            entries[index].revision += 1
            entries[index].start = start // 직전 대비로만 흔들림을 잰다 — 흔들림이 쌓이지 않게.
            entries[index].end = max(entries[index].end, end)
            entries[index].finalized = entries[index].finalized || isFinal
            return Assignment(id: entries[index].id, revision: entries[index].revision)
        }
        let entry = Entry(id: nextID, start: start, end: end, revision: 0, finalized: isFinal)
        nextID += 1
        entries.append(entry)
        if entries.count > 32 { entries.removeFirst() }
        return Assignment(id: entry.id, revision: 0)
    }

    /// 언어를 바꾸면 이전 구간과 잇지 않는다 — 한 발화에 두 언어가 섞이지 않도록.
    public mutating func breakUtterance() {
        for index in entries.indices { entries[index].finalized = true }
    }
}

/// 최신 발화가 무엇인지를 기억한다.
///
/// 확정 구간의 final과 그 뒤 구간의 volatile은 순서를 바꿔 도착할 수 있다. 발화 ID로
/// 구분하지 않으면 옛 구간의 final이 최신 원문을 되돌려버린다.
///
/// 여러 줄을 쌓는 UI(`CaptionState`)에서는 옛 구간의 뒤늦은 final도 **버릴 게 아니라
/// 자기 줄에 반영**해야 한다 — 사용자가 읽고 있는 게 바로 그 줄이다. 그래서 무시하라고
/// nil을 돌려주는 대신 "최신이 아니다"라는 표시를 붙여 돌려준다. 판단은 호출자 몫이고,
/// 여기서 지키는 건 `text`/`shownID`가 절대 되돌아가지 않는다는 것 하나다.
public struct LatestCaption: Sendable {
    public struct Update: Sendable, Equatable {
        public let text: String
        /// true면 최신 발화가 아니다 — 목록의 옛 줄에 반영해야 한다.
        public let isOutdated: Bool

        public init(text: String, isOutdated: Bool) {
            self.text = text
            self.isOutdated = isOutdated
        }
    }

    public private(set) var text = ""
    private var shownID = 0

    public init() {}

    public mutating func apply(_ event: TranscriptEvent) -> Update {
        // 옛 구간의 뒤늦은 갱신. 최신 원문은 건드리지 않고 표시만 붙여 넘긴다.
        guard event.utteranceID >= shownID else {
            return Update(text: event.text, isOutdated: true)
        }
        shownID = event.utteranceID
        text = event.text
        return Update(text: text, isOutdated: false)
    }

    public mutating func reset() {
        text = ""
        shownID = 0
    }
}

// MARK: - 입력 큐 (변환 + 백프레셔)

public enum AudioInputQueueError: LocalizedError, Equatable {
    case overflow

    public var errorDescription: String? {
        switch self {
        case .overflow: "오디오 입력이 밀렸습니다 — 분석기가 따라오지 못합니다"
        }
    }
}

/// 캡처 sink와 분석기 사이의 다리. 변환·백프레셔·소스 전환을 한곳에서 책임진다.
///
/// **변환은 여기서, 캡처 스레드 위에서, 이 객체의 락 아래에서 일어난다.**
/// `AudioBufferConverter`는 `AVAudioConverter` 하나를 재사용하는데 Apple은 그것을
/// thread-safe 라고 문서화한 적이 없다. sink는 캡처 스레드에서 불리고, 소스를 바꾸는
/// 순간에는 옛 tap과 새 tap의 콜백이 겹칠 수 있다. `AudioSource` 계약상 빌린 버퍼를
/// 비동기로 넘길 수 없으므로 변환을 다른 스레드로 미룰 수도 없다. 그래서 변환기 교체,
/// 변환, 적재를 전부 같은 락 안에서 직렬화한다.
///
/// 백프레셔는 진짜다. `AsyncStream`처럼 무한히 버퍼링하지 않고 소비자가 `next()`에서
/// 실제로 기다리게 만들어, 쌓인 프레임 수가 곧 소비자의 지연이 되게 한다. 상한을
/// 넘으면 PCM을 조용히 버리지 않고 오류를 흘려보내 실행을 정지시킨다.
public final class AudioInputQueue: @unchecked Sendable {
    /// 변환된 버퍼는 새로 할당된 것이고 넘긴 쪽은 다시 건드리지 않는다 —
    /// 소유권을 통째로 넘기는 것이라 경합이 없다.
    private struct Handoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer?
    }

    private enum Delivery {
        case value(AVAudioPCMBuffer?)
        case failure(any Error)
    }

    private let lock = NSLock()
    private let analysisFormat: AVAudioFormat
    private let capacityFrames: Int

    private var converter: AudioBufferConverter?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    private var waiter: CheckedContinuation<Handoff, any Error>?
    private var failure: (any Error)?
    private var finished = false

    public init(analysisFormat: AVAudioFormat, maximumSeconds: Double = 2.0) {
        self.analysisFormat = analysisFormat
        self.capacityFrames = Int(analysisFormat.sampleRate * maximumSeconds)
    }

    /// 캡처 콜백에서 부른다. 원본 버퍼는 이 호출 안에서만 쓰인다.
    public func ingest(_ raw: AVAudioPCMBuffer) {
        lock.lock()
        if finished || failure != nil {
            lock.unlock()
            return
        }
        do {
            // 장치 변경·소스 전환으로 입력 포맷이 바뀌면 변환기를 새로 만든다.
            if converter?.inputFormat != raw.format {
                converter = try AudioBufferConverter(from: raw.format, to: analysisFormat)
            }
            for buffer in try converter!.convert(raw) {
                pending.append(buffer)
                pendingFrames += Int(buffer.frameLength)
            }
            if pendingFrames > capacityFrames { throw AudioInputQueueError.overflow }
        } catch {
            failure = error
            pending.removeAll()
            pendingFrames = 0
        }
        let handoff = takeWaiterLocked()
        lock.unlock()
        deliver(handoff)
    }

    /// 더 이상 입력이 없다. 기다리던 소비자는 nil을 받고 시퀀스를 끝낸다.
    public func finish() {
        lock.lock()
        finished = true
        let handoff = takeWaiterLocked()
        lock.unlock()
        deliver(handoff)
    }

    fileprivate func next() async throws -> AVAudioPCMBuffer? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Handoff, any Error>) in
                lock.lock()
                if let delivery = pendingDeliveryLocked() {
                    lock.unlock()
                    resume(continuation, delivery)
                } else {
                    precondition(waiter == nil, "AudioInputQueue는 소비자 하나만 지원한다")
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish()
        }.buffer
    }

    private func pendingDeliveryLocked() -> Delivery? {
        if let failure { return .failure(failure) }
        if !pending.isEmpty {
            let buffer = pending.removeFirst()
            pendingFrames -= Int(buffer.frameLength)
            return .value(buffer)
        }
        if finished { return .value(nil) }
        return nil
    }

    private func takeWaiterLocked() -> (CheckedContinuation<Handoff, any Error>, Delivery)? {
        guard let waiter, let delivery = pendingDeliveryLocked() else { return nil }
        self.waiter = nil
        return (waiter, delivery)
    }

    /// 락을 놓은 뒤에 재개한다 — continuation이 동기적으로 실행을 이어받을 수 있으므로.
    private func deliver(_ handoff: (CheckedContinuation<Handoff, any Error>, Delivery)?) {
        guard let handoff else { return }
        resume(handoff.0, handoff.1)
    }

    private func resume(_ continuation: CheckedContinuation<Handoff, any Error>, _ delivery: Delivery) {
        switch delivery {
        case .value(let buffer): continuation.resume(returning: Handoff(buffer: buffer))
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

extension AudioInputQueue: AsyncSequence {
    public typealias Element = AVAudioPCMBuffer

    public struct AsyncIterator: AsyncIteratorProtocol {
        let queue: AudioInputQueue
        public mutating func next() async throws -> AVAudioPCMBuffer? { try await queue.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(queue: self) }
}

/// 캡처 콜백과 큐 사이의 스위치. 정리의 첫 단계는 "sink 수신 차단"이고, 큐가 아직
/// 없는 시점(포맷 협상 전)에 도착한 버퍼도 여기서 흘려보낸다.
public final class AudioSinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: AudioInputQueue?
    private var enabled = true
    /// LBC_TIMING 전용: 이 실행에서 오디오가 sink에 처음 닿은 벽시계 시각. 발화별
    /// 시작 시각은 이 값 + `chunk.start`(오디오 상대 시각)로 근사한다.
    private var firstIngestTime: Date?

    public init() {}

    public func attach(_ queue: AudioInputQueue) {
        lock.lock(); defer { lock.unlock() }
        self.queue = queue
    }

    public func disable() {
        lock.lock()
        enabled = false
        queue = nil
        lock.unlock()
    }

    /// 실시간 오디오 콜백에서 불린다. `LatencyTiming.enabled`가 꺼져 있으면
    /// `&&`의 단락 평가로 `Date()`조차 만들지 않는다 — 락 안에서 하는 일은
    /// 이미 있던 대입 하나뿐, 새 락도 포매팅도 없다.
    public func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let target = enabled ? queue : nil
        if LatencyTiming.enabled, firstIngestTime == nil { firstIngestTime = Date() }
        lock.unlock()
        target?.ingest(buffer)
    }

    /// LBC_TIMING 전용 판독. 오디오 스레드 밖(`consume`)에서만 부른다.
    public func captureAnchor() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return firstIngestTime
    }
}

// MARK: - Speech 프레임워크 경계

/// 전사 결과 한 조각. Speech 프레임워크 타입이 이 선을 넘어오지 않는다.
public struct TranscriptionChunk: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// 오디오 시간 기준 구간(초).
    public let start: Double
    public let end: Double

    public init(text: String, isFinal: Bool, start: Double, end: Double) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// 한 번의 실행이 쓰는 분석 세션. 실제 구현은 `SpeechAnalyzer`를 감싸고,
/// 테스트는 가짜를 넣는다.
public protocol SpeechSession: Sendable {
    /// 모델 설치. 설치할 것이 없으면 `progress` 호출 없이 바로 돌아온다(정상 경로).
    func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws
    /// 분석 포맷 협상. `considering`을 주면 캡처 포맷에 가까운 결과를 노린다.
    func bestAudioFormat(considering natural: AVAudioFormat?) async -> AVAudioFormat?
    /// 협상된 포맷으로 분석을 시작하고 결과 스트림을 돌려준다.
    func start(format: AVAudioFormat, input: AudioInputQueue) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error>
    /// 포맷이 호환되면 모듈만 갈아끼우고 true. 아니면 false — 호출자가 재시작한다.
    ///
    /// 교체 **전에** 진행 중인 오디오를 확정하고 그 결과를 결과 스트림으로 내보내야
    /// 한다. 그냥 갈아끼우면 사용자가 말하던 문장이 final 없이 사라진다.
    func setLanguage(_ locale: Locale) async throws -> Bool
    func finish() async
}

public protocol SpeechEngine: Sendable {
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func reservedLocales() async -> [Locale]
    func reserve(locale: Locale) async throws -> Bool
    func release(locale: Locale) async
    func makeSession(locale: Locale, sensitivity: DetectorSensitivity) throws -> any SpeechSession
}

// MARK: - 파이프라인

/// 실행(Run) 하나의 자원을 소유한다. AppDelegate가 직접 부르지 않는다 —
/// 진입점은 `PipelineController` 하나뿐이다.
@MainActor
public final class SpeechPipeline {
    public typealias SourceFactory = @MainActor (AudioSourceKind) -> any AudioSource

    /// 실행 중인 한 벌. 취소·정리 판정은 전부 이 객체의 **동일성**으로 한다.
    /// await 뒤에 공유 프로퍼티를 nil로 만들지 않고, 그 사이 새 실행이 들어섰는지만 본다.
    private final class Run {
        var id: Int
        var configuration: PipelineConfiguration
        var language: CaptionLanguage
        var ledger = UtteranceLedger()
        var gate: AudioSinkGate?
        var source: (any AudioSource)?
        var session: (any SpeechSession)?
        var queue: AudioInputQueue?
        var resultsTask: Task<Void, Never>?
        var progressTask: Task<Void, Never>?
        var reservedLocales: [Locale] = []
        var listening = false
        var tornDown = false

        init(id: Int, configuration: PipelineConfiguration) {
            self.id = id
            self.configuration = configuration
            self.language = configuration.language
        }
    }

    private let engine: any SpeechEngine
    private let makeSource: SourceFactory
    private var current: Run?

    public var onEvent: (@MainActor (PipelineEvent) -> Void)?

    public init(engine: any SpeechEngine = SystemSpeechEngine(),
                makeSource: @escaping SourceFactory = { _ in MicSource() }) {
        self.engine = engine
        self.makeSource = makeSource
    }

    public var isListening: Bool { current?.listening ?? false }

    /// 한 실행을 시작한다. 성공하면 `.listening` 이벤트가 나간 상태로 돌아온다.
    /// 취소되거나 실패하면 그때까지 잡은 자원을 같은 순서로 되돌린다.
    public func start(_ configuration: PipelineConfiguration, generation: Int) async {
        let run = Run(id: generation, configuration: configuration)
        current = run
        do {
            try await startRun(run)
        } catch {
            let superseded = current !== run
            await teardown(run)
            if !superseded && !(error is CancellationError) {
                emit(run.id, .failed(message: error.localizedDescription))
            }
        }
    }

    public func stop() async {
        guard let run = current else { return }
        await teardown(run)
    }

    /// 언어만 바뀐 경우. 포맷이 호환되면 실행을 끊지 않고 모듈만 교체한다.
    /// 불가능하면 false를 돌려주고, 호출자가 정지 후 재시작한다.
    public func switchLanguage(to language: CaptionLanguage, generation: Int) async -> Bool {
        guard let run = current, run.listening, let session = run.session else { return false }
        guard let locale = await engine.supportedLocale(equivalentTo: language.locale) else { return false }
        guard current === run else { return false }

        // 교체를 시작하기 전에 실행 ID를 최신 generation으로 올린다. 세션이 교체 직전에
        // 확정해 내보내는 마지막 문장이 controller의 generation 필터에 걸려 사라지지
        // 않도록 — 그 문장이야말로 사용자가 방금 말한, 잃으면 안 되는 문장이다.
        // 언어는 교체가 성공한 **뒤에** 바꾼다. 그 마지막 문장은 아직 이전 언어다.
        run.id = generation
        guard let swapped = try? await session.setLanguage(locale), swapped else { return false }
        guard current === run else { return false }

        await reserveIfNeeded(locale, run: run)
        guard current === run else { return false }

        run.configuration.language = language
        run.language = language
        run.ledger.breakUtterance()
        emit(run.id, .listening(language: language))
        return true
    }

    // MARK: 시작 절차

    private func startRun(_ run: Run) async throws {
        let language = run.configuration.language

        guard let locale = await engine.supportedLocale(equivalentTo: language.locale) else {
            throw PipelineError.unsupportedLanguage(language.displayName)
        }
        try checkAlive(run)

        let session = try engine.makeSession(locale: locale, sensitivity: run.configuration.sensitivity)
        run.session = session

        try await installAssets(session, run: run)
        try checkAlive(run)

        await reserveIfNeeded(locale, run: run)
        try checkAlive(run)

        // sink는 캡처가 시작되는 순간부터 불린다. 아직 큐가 없으므로 gate가 흘려보낸다.
        let gate = AudioSinkGate()
        run.gate = gate
        let source = makeSource(run.configuration.source)
        run.source = source
        let captureFormat = try await source.start { buffer in gate.ingest(buffer) }
        try checkAlive(run)

        // 캡처 포맷을 넘기면 협상 결과가 입력에 가까워져 변환 폭이 줄어든다.
        // 이 머신에서는 결과가 같지만 다른 locale·머신에서는 달라질 수 있고 비용이 없다.
        var negotiated = await session.bestAudioFormat(considering: captureFormat)
        if negotiated == nil { negotiated = await session.bestAudioFormat(considering: nil) }
        guard let analysisFormat = negotiated else { throw PipelineError.noCompatibleFormat }
        try checkAlive(run)
        LatencyTiming.log("협상된 분석 포맷: \(analysisFormat)")

        let queue = AudioInputQueue(analysisFormat: analysisFormat)
        run.queue = queue
        gate.attach(queue)

        let results = try await session.start(format: analysisFormat, input: queue)
        try checkAlive(run)

        run.resultsTask = Task { [weak self] in
            await self?.consume(results, run: run)
        }
        run.listening = true
        emit(run.id, .listening(language: run.language))
    }

    private func installAssets(_ session: any SpeechSession, run: Run) async throws {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let reporter = Task { [weak self] in
            for await fraction in stream {
                guard let self, self.current === run else { continue }
                self.emit(run.id, .installing(fraction: fraction))
            }
        }
        run.progressTask = reporter
        // 성공·실패·취소 어느 쪽으로 빠져나가도 진행률 태스크를 남기지 않는다.
        defer {
            continuation.finish()
            reporter.cancel()
            run.progressTask = nil
        }
        try await session.installAssets { continuation.yield($0) }
    }

    /// 예약은 최적화지 필수 조건이 아니다(캡은 5). 실패해도 시작을 멈추지 않고,
    /// 이 실행이 **직접 예약한 것만** 기억해 뒀다가 정지할 때 되돌린다.
    private func reserveIfNeeded(_ locale: Locale, run: Run) async {
        let reserved = await engine.reservedLocales()
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        guard !run.reservedLocales.contains(where: { $0.identifier == locale.identifier }) else { return }
        do {
            if try await engine.reserve(locale: locale) { run.reservedLocales.append(locale) }
        } catch {
            NSLog("locale 예약 실패(무시하고 계속): %@", error.localizedDescription)
        }
    }

    private func consume(_ results: AsyncThrowingStream<TranscriptionChunk, any Error>, run: Run) async {
        // LBC_TIMING 전용, 이 루프에만 사는 로컬 상태 — 발화마다 첫 부분결과 시각을
        // 기억해뒀다가 최종이 오면 지운다. 꺼져 있으면 절대 채워지지 않는다.
        var firstPartialAt: [Int: Date] = [:]
        do {
            for try await chunk in results {
                guard current === run else { return }
                let assignment = run.ledger.assign(start: chunk.start, end: chunk.end, isFinal: chunk.isFinal)
                if LatencyTiming.enabled {
                    logTiming(run: run, chunk: chunk, assignment: assignment, firstPartialAt: &firstPartialAt)
                }
                let transcript: Transcript = chunk.isFinal ? .final(chunk.text) : .partial(chunk.text)
                emit(run.id, .transcript(TranscriptEvent(
                    utteranceID: assignment.id,
                    revision: assignment.revision,
                    sourceLanguage: run.language,
                    transcript: transcript)))
            }
        } catch {
            guard current === run, !(error is CancellationError) else { return }
            emit(run.id, .failed(message: error.localizedDescription))
        }
    }

    /// 발화 시작 시각은 `gate.captureAnchor()`(오디오가 sink에 처음 닿은 벽시계 시각)에
    /// `chunk.start`(그 발화가 시작하는 오디오 상대 시각)를 더해 근사한다 — 마이크
    /// 캡처는 실시간이라 오디오 상대 시각과 벽시계 경과 시각이 거의 같다는 전제다.
    private func logTiming(
        run: Run, chunk: TranscriptionChunk, assignment: UtteranceLedger.Assignment,
        firstPartialAt: inout [Int: Date]
    ) {
        let now = Date()
        if firstPartialAt[assignment.id] == nil {
            firstPartialAt[assignment.id] = now
            if let anchor = run.gate?.captureAnchor() {
                let audioStartWallClock = anchor.addingTimeInterval(chunk.start)
                let ms = Int(now.timeIntervalSince(audioStartWallClock) * 1000)
                LatencyTiming.log("발화#\(assignment.id) 첫 인식까지 \(ms)ms (오디오 시작 → 첫 부분결과)")
            }
        }
        if chunk.isFinal, let firstPartial = firstPartialAt.removeValue(forKey: assignment.id) {
            let ms = Int(now.timeIntervalSince(firstPartial) * 1000)
            LatencyTiming.log("발화#\(assignment.id) 확정까지 \(ms)ms (첫 부분결과 → 최종)")
        }
    }

    // MARK: 정리

    /// sink 수신 차단 → source.stop 완료 → 입력 종료 → 결과/분석 태스크 취소 → 분석기 종료.
    /// 여러 번 불러도 안전하다.
    private func teardown(_ run: Run) async {
        guard !run.tornDown else { return }
        run.tornDown = true
        run.listening = false

        run.gate?.disable()
        if let source = run.source { await source.stop() }
        run.queue?.finish()
        run.progressTask?.cancel()
        run.resultsTask?.cancel()
        if let session = run.session { await session.finish() }
        for locale in run.reservedLocales { await engine.release(locale: locale) }

        run.gate = nil
        run.source = nil
        run.queue = nil
        run.session = nil
        run.progressTask = nil
        run.resultsTask = nil
        run.reservedLocales = []

        if current === run { current = nil }
    }

    private func checkAlive(_ run: Run) throws {
        try Task.checkCancellation()
        guard current === run else { throw CancellationError() }
    }

    private func emit(_ runID: Int, _ kind: PipelineEvent.Kind) {
        onEvent?(PipelineEvent(runID: runID, kind: kind))
    }
}

// MARK: - 실제 Speech 구현

extension DetectorSensitivity {
    var detectorLevel: SpeechDetector.SensitivityLevel {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

public struct SystemSpeechEngine: SpeechEngine {
    public init() {}

    public func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    public func reserve(locale: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: locale)
    }

    public func release(locale: Locale) async {
        _ = await AssetInventory.release(reservedLocale: locale)
    }

    public func makeSession(locale: Locale, sensitivity: DetectorSensitivity) throws -> any SpeechSession {
        SystemSpeechSession(locale: locale, sensitivity: sensitivity)
    }
}

/// `AnalyzerInput`으로 감싸는 얇은 어댑터. 변환된 버퍼만 여기를 통과한다.
private struct AnalyzerInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let queue: AudioInputQueue

    struct Iterator: AsyncIteratorProtocol {
        var base: AudioInputQueue.AsyncIterator
        mutating func next() async throws -> AnalyzerInput? {
            guard let buffer = try await base.next() else { return nil }
            return AnalyzerInput(buffer: buffer)
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(base: queue.makeAsyncIterator()) }
}

actor SystemSpeechSession: SpeechSession {
    private var locale: Locale
    private let detector: SpeechDetector
    private var transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var analysisFormat: AVAudioFormat?
    private var analysisTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    /// 언어 교체 직전까지 돌던 pump. 확정된 마지막 결과를 마저 실어 나른다.
    private var retiredPump: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<TranscriptionChunk, any Error>.Continuation?

    init(locale: Locale, sensitivity: DetectorSensitivity) {
        self.locale = locale
        // VAD는 SpeechDetector가 한다. 손으로 만든 RMS 감지는 없앴다.
        self.detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: sensitivity.detectorLevel),
            reportResults: false)
        self.transcriber = Self.makeTranscriber(locale)
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // .fastResults: 지연을 줄이는 저지연 보고 모드. .volatileResults와 함께 켜야
            // 원문 줄(부분결과)이 더 빨리 뜬다. SDK 인터페이스에서 두 옵션 다
            // SpeechTranscriber.ReportingOption에 있는 걸 확인했다(DictationTranscriber의
            // .frequentFinalization과 혼동하지 말 것).
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
    }

    private var modules: [any SpeechModule] { [detector, transcriber] }

    func installAssets(progress report: @escaping @Sendable (Double) -> Void) async throws {
        // nil은 "설치할 것이 없음"이다. 오류가 아니다.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let reporter = Task {
            while !Task.isCancelled && !request.progress.isFinished {
                report(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    func bestAudioFormat(considering natural: AVAudioFormat?) async -> AVAudioFormat? {
        if let natural {
            return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: natural)
        }
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    }

    func start(format: AVAudioFormat, input: AudioInputQueue) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error> {
        let analyzer = SpeechAnalyzer(modules: modules)
        // 협상된 포맷을 넘긴다. 분석기는 자동 리샘플링하지 않는다.
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        self.analysisFormat = format

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, any Error>.makeStream()
        self.continuation = continuation
        startPump()

        analysisTask = Task { [weak self] in
            do { _ = try await analyzer.analyzeSequence(AnalyzerInputs(queue: input)) }
            catch { await self?.fail(error) }
        }
        return stream
    }

    func setLanguage(_ newLocale: Locale) async throws -> Bool {
        guard let analyzer, let analysisFormat else { return false }
        let candidate = Self.makeTranscriber(newLocale)
        let newModules: [any SpeechModule] = [detector, candidate]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: newModules, considering: analysisFormat),
              format.sampleRate == analysisFormat.sampleRate,
              format.channelCount == analysisFormat.channelCount,
              format.commonFormat == analysisFormat.commonFormat,
              format.isInterleaved == analysisFormat.isInterleaved
        else { return false }

        // 1) 이미 먹인 오디오를 먼저 확정한다. 이걸 건너뛰고 모듈만 갈아끼우면 사용자가
        //    방금 말하던 문장이 final 없이 사라진다 — 자막이 말 없이 증발하는 것은 이
        //    앱에서 가장 민감한 실패다. 분석기 자체는 끝내지 않는다(사용자가 누른
        //    정지가 아니다). 사용자 정지 경로는 그대로 cancelAndFinishNow를 쓴다.
        try? await analyzer.finalize(through: nil)

        // 2) 모듈 교체. 빠진 모듈의 결과 스트림은 여기서 끝나므로 옛 pump는 스스로
        //    빠져나온다. pump를 먼저 취소하면 방금 확정한 결과를 그 pump가 버린다.
        try await analyzer.setModules(newModules)

        // 3) 옛 pump는 남은 결과(특히 방금의 final)를 같은 continuation으로 실어 나른
        //    뒤에 끝난다. 스트림이 끝나지 않는 구현이어도 태스크가 무한히 쌓이지 않도록
        //    직전에 은퇴시킨 것 하나만 남기고 정리한다.
        retiredPump?.cancel()
        retiredPump = pumpTask
        transcriber = candidate
        locale = newLocale
        startPump()
        return true
    }

    func finish() async {
        retiredPump?.cancel(); retiredPump = nil
        pumpTask?.cancel(); pumpTask = nil
        analysisTask?.cancel(); analysisTask = nil
        continuation?.finish(); continuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
    }

    /// 결과 스트림은 실행 내내 하나다. 언어를 바꿔도 소비자가 다시 구독하지 않는다.
    private func startPump() {
        let results = transcriber.results
        let sink = continuation
        pumpTask = Task {
            do {
                for try await result in results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    sink?.yield(TranscriptionChunk(
                        text: text,
                        isFinal: result.isFinal,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds))
                }
            } catch {
                guard !Task.isCancelled else { return }
                sink?.finish(throwing: error)
            }
        }
    }

    private func fail(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        continuation?.finish(throwing: error)
    }
}

import AVFoundation
import Foundation
import Speech

// MARK: - 설정 스냅샷

/// 한 번의 실행이 쓰는 값들. 설정이 바뀌면 새 스냅샷을 만들어 controller에 넘긴다.
public struct PipelineConfiguration: Sendable, Equatable {
    public var source: AudioSourceKind
    public var language: CaptionLanguage
    public var sensitivity: DetectorSensitivity
    /// nil = 고정 언어 모드(세션 한 벌). 값이 있으면 자동 모드 — `language`(주 언어)와
    /// 이 언어, 두 벌을 동시에 돌려 발화마다 신뢰도로 고른다(스펙 §2). 하드 제약(실측):
    /// 분석기 하나에 전사기 둘을 물리면 SIGTRAP이라 언어별로 분석기 자체를 두 벌 쓴다.
    public var secondaryLanguage: CaptionLanguage?

    public init(source: AudioSourceKind, language: CaptionLanguage, sensitivity: DetectorSensitivity,
                secondaryLanguage: CaptionLanguage? = nil) {
        self.source = source
        self.language = language
        self.sensitivity = sensitivity
        self.secondaryLanguage = secondaryLanguage
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
    public let sourceLanguage: CaptionLanguage
    public let transcript: Transcript

    public var text: String { transcript.text }
    public var isFinal: Bool { transcript.isFinal }

    public init(utteranceID: Int, sourceLanguage: CaptionLanguage, transcript: Transcript) {
        self.utteranceID = utteranceID
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
                appendLocked(buffer)
            }
            if pendingFrames > capacityFrames { throw AudioInputQueueError.overflow }
        } catch {
            failLocked(error)
        }
        let handoff = takeWaiterLocked()
        lock.unlock()
        deliver(handoff)
    }

    /// 이미 변환된 버퍼를 받는다 — 자동 모드의 팬아웃(`DualAudioSink`)이 변환을 상류에서
    /// 한 번만 하고, 언어별 큐에는 결과만 나눠 넣을 때 쓴다. 변환기를 갖지 않고 같은
    /// 백프레셔·상한 규칙만 각자 적용한다.
    public func ingestConverted(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if finished || failure != nil {
            lock.unlock()
            return
        }
        appendLocked(buffer)
        if pendingFrames > capacityFrames { failLocked(AudioInputQueueError.overflow) }
        let handoff = takeWaiterLocked()
        lock.unlock()
        deliver(handoff)
    }

    /// 상류(팬아웃의 공유 변환)에서 난 오류를 이 큐의 소비자에게도 흘린다.
    public func fail(_ error: any Error) {
        lock.lock()
        if finished || failure != nil {
            lock.unlock()
            return
        }
        failLocked(error)
        let handoff = takeWaiterLocked()
        lock.unlock()
        deliver(handoff)
    }

    private func appendLocked(_ buffer: AVAudioPCMBuffer) {
        pending.append(buffer)
        pendingFrames += Int(buffer.frameLength)
    }

    private func failLocked(_ error: any Error) {
        failure = error
        pending.removeAll()
        pendingFrames = 0
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

/// `AudioSinkGate`가 밀어 넣는 대상의 최소 계약. 고정 언어 모드는 `AudioInputQueue`
/// 하나가 직접 이 역할을 하고(변환도 자신이 한다), 자동 모드는 `DualAudioSink`가 대신
/// 받아 변환을 한 번만 하고 언어별 두 큐로 나눠 넣는다.
///
/// `Sendable`을 요구하지 않는다 — 구현체는 실시간 오디오 스레드에서 호출되는
/// `AudioSinkGate.ingest`를 통해서만 불리고(그 자신이 캡처 스레드 하나로 직렬화를
/// 이미 보장한다), 그 경계를 넘어 스레드 사이로 값 자체가 오가지 않는다. 여기서
/// `Sendable`을 강제하면 구현체가 저마다 불필요한 `@unchecked Sendable`을 달아야 한다.
public protocol AudioIngestSink {
    func ingest(_ buffer: AVAudioPCMBuffer)
}

extension AudioInputQueue: AudioIngestSink {}

/// 자동 모드 전용 팬아웃. 변환기 하나를 재사용해 원본 버퍼를 **한 번만** 변환하고,
/// 그 결과를 언어별 두 큐에 나눠 넣는다(각 큐는 다시 변환하지 않는다) — 캡처 스레드
/// 위에서 호출된다는 계약은 `AudioInputQueue.ingest`와 같다.
///
/// 두 큐는 **같은 버퍼 인스턴스를 나눠 갖지 않는다**(코드 리뷰 F2) — `primary`는 방금
/// 변환된 버퍼를 그대로 받고, `secondary`는 채널 데이터를 그대로 복사한 새 버퍼를
/// 받는다. 두 `SpeechAnalyzer.analyzeSequence`가 동시에 같은 가변 `AVAudioPCMBuffer`를
/// 읽는 경합을 이 타입이 직접 보장하지 않으므로(문서화된 계약이 아니다), 값을 복사해
/// 아예 경합의 여지를 없앤다 — 변환은 다시 하지 않으니 비용은 memcpy 한 번뿐이다.
///
/// `converter`는 이 타입이 유일하게 들고 있는 가변 상태다. 이 타입은 `Sendable`이
/// 아니다(코드 리뷰 F3) — `AudioIngestSink`가 `Sendable`을 요구하지 않으므로 그럴
/// 필요가 없다. `ingest`는 오직 `AudioSinkGate.ingest`를 통해서만, 실시간 캡처
/// 스레드 하나로 이미 직렬화된 채로 불린다(`AudioInputQueue.ingest`와 같은 호출
/// 계약). 그래도 락을 두는 건 그 직렬화를 이 타입 혼자 재확인하지 않고 그냥
/// 믿어야 하는 상태로 남기지 않기 위해서다 — `AudioInputQueue`가 자신의 가변
/// 상태를 잠그는 것과 같은 이유.
public final class DualAudioSink: AudioIngestSink {
    private let lock = NSLock()
    private let analysisFormat: AVAudioFormat
    private let primary: AudioInputQueue
    private let secondary: AudioInputQueue
    private var converter: AudioBufferConverter?

    public init(analysisFormat: AVAudioFormat, primary: AudioInputQueue, secondary: AudioInputQueue) {
        self.analysisFormat = analysisFormat
        self.primary = primary
        self.secondary = secondary
    }

    public func ingest(_ raw: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if converter?.inputFormat != raw.format {
                converter = try AudioBufferConverter(from: raw.format, to: analysisFormat)
            }
            for buffer in try converter!.convert(raw) {
                primary.ingestConverted(buffer)
                if let copy = Self.copy(buffer) {
                    secondary.ingestConverted(copy)
                } else {
                    secondary.fail(AudioBufferConverterError.allocationFailed)
                }
            }
        } catch {
            primary.fail(error)
            secondary.fail(error)
        }
    }

    /// `buffer`와 같은 포맷·길이의 새 버퍼에 오디오 데이터를 그대로 복사한다.
    /// 인터리브 여부와 무관하게 동작한다 — `AudioBufferList`의 각 버퍼를 그대로
    /// memcpy한다(채널별 accessor로 나누지 않는다).
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            dstData.copyMemory(from: srcData, byteCount: Int(src.mDataByteSize))
        }
        return copy
    }
}

/// 캡처 콜백과 큐 사이의 스위치. 정리의 첫 단계는 "sink 수신 차단"이고, 큐가 아직
/// 없는 시점(포맷 협상 전)에 도착한 버퍼도 여기서 흘려보낸다.
public final class AudioSinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: (any AudioIngestSink)?
    private var enabled = true
    /// LBC_TIMING 전용: 이 실행에서 오디오가 sink에 처음 닿은 벽시계 시각. 발화별
    /// 시작 시각은 이 값 + `chunk.start`(오디오 상대 시각)로 근사한다.
    private var firstIngestTime: Date?

    public init() {}

    public func attach(_ sink: any AudioIngestSink) {
        lock.lock(); defer { lock.unlock() }
        self.queue = sink
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
///
/// `runID`·`language`는 세션이 이 조각을 만드는 **바로 그 순간**에 찍는다 — 나중에
/// `SpeechPipeline`이 실행 상태를 보고 다시 매기지 않는다. hot swap 도중에는 같은
/// 실행 안에서 옛 언어의 구제된 final과 새 언어의 첫 조각이 같은 스트림으로 섞여
/// 나오므로, 조각 자신이 자기 출처를 증언해야 나중에 값이 바뀌어도 흔들리지 않는다.
public struct TranscriptionChunk: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// 오디오 시간 기준 구간(초).
    public let start: Double
    public let end: Double
    public let runID: Int
    public let language: CaptionLanguage
    /// final에만 값이 있다 — 자동 모드의 선택 규칙(스펙 §2)은 final의 평균 confidence만
    /// 비교한다. 고정 모드에서도 계산은 되지만(트랜스크라이버 옵션이 모드와 무관하게
    /// 하나라서) 아무도 읽지 않는다.
    public let confidence: Double?

    public init(text: String, isFinal: Bool, start: Double, end: Double, runID: Int, language: CaptionLanguage,
                confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
        self.runID = runID
        self.language = language
        self.confidence = confidence
    }
}

/// 한 번의 실행이 쓰는 분석 세션. 실제 구현은 `SpeechAnalyzer`를 감싸고,
/// 테스트는 가짜를 넣는다.
public protocol SpeechSession: Sendable {
    /// 모델 설치. 설치할 것이 없으면 `progress` 호출 없이 바로 돌아온다(정상 경로).
    func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws
    /// 분석 포맷 협상. `considering`을 주면 캡처 포맷에 가까운 결과를 노린다.
    func bestAudioFormat(considering natural: AVAudioFormat?) async -> AVAudioFormat?
    /// 협상된 포맷으로 분석을 시작하고 결과 스트림을 돌려준다. `runID`·`language`는
    /// 이 실행이 내보내는 조각에 찍을 초기 식별값이다.
    func start(format: AVAudioFormat, input: AudioInputQueue, runID: Int, language: CaptionLanguage) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error>
    /// 포맷이 호환되면 모듈만 갈아끼우고 true. 아니면 false — 호출자가 재시작한다.
    ///
    /// 교체 **전에** 진행 중인 오디오를 확정하고 그 결과를 결과 스트림으로 내보내야
    /// 한다. 그냥 갈아끼우면 사용자가 말하던 문장이 final 없이 사라진다. 확정된
    /// 문장(구제된 final)은 `runID`(호출자가 이미 최신 generation으로 올려 건넨 값)를
    /// 달고 나가되, `language`는 교체가 실제로 끝나기 전까지 옛 값으로 남는다 —
    /// 그 문장은 옛 언어로 말해진 것이기 때문이다. 실패하면 아무것도 바꾸지 않는다.
    func setLanguage(_ locale: Locale, runID: Int, language: CaptionLanguage) async throws -> Bool
    func finish() async
}

public protocol SpeechEngine: Sendable {
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func reservedLocales() async -> [Locale]
    func reserve(locale: Locale) async throws -> Bool
    func release(locale: Locale) async
    func makeSession(locale: Locale, sensitivity: DetectorSensitivity) throws -> any SpeechSession
}

// MARK: - 자동 모드: 신뢰도 기반 언어 중재

/// 두 세션의 final이 서로 짝을 못 찾을 때 얼마나 기다릴지를 결정한다(코드 리뷰 F1).
/// 실전 구현(`RealTimeGraceClock`)은 실제 시간을 재고, 테스트는 `Signal`과 같은 패턴의
/// 가짜를 주입해 시간 대신 신호로 결정적으로 통제한다.
public protocol DualArbitratorClock: Sendable {
    /// 여유 시간이 지날 때까지 매달린다.
    func waitGrace() async
}

/// 실제 벽시계 여유, 기본 0.4초.
///
/// 근거: 두 세션은 같은 변환된 오디오를 같은 페이싱으로 받으므로, 같은 발화의 final은
/// 보통 수십~100ms 안쪽 간격으로 도착한다(실측 프로브 로그 기준). 0.4초는 그 정상
/// 지터를 넉넉히 덮으면서도, 상대가 진짜로 멎었을 때 화면이 비어 보이는 시간을
/// 사람이 "끊겼다"고 느끼기 전 수준(수백 ms)으로 제한한다 — 너무 짧으면(예: 100ms)
/// 정상적인 두 세션 사이의 지터만으로도 성급하게 확정해버려 신뢰도 비교 자체가
/// 무의미해진다.
public struct RealTimeGraceClock: DualArbitratorClock {
    public let seconds: Double
    public init(seconds: Double = 0.4) { self.seconds = seconds }
    public func waitGrace() async { try? await Task.sleep(for: .seconds(seconds)) }
}

/// 언어별로 완전히 따로 도는 두 세션의 결과를 하나의 결과 스트림으로 합친다(스펙 §2).
///
/// 규칙: 발화 단위로 양쪽 final의 confidence(`TranscriptionChunk.confidence`, 이미 조각에
/// 찍혀 있는 평균값)를 비교해 높은 쪽을 채택한다. **아직 확정된 승자가 없으면**(첫 발화가
/// 아직 안 끝났으면) 화면이 비지 않도록 양쪽 partial을 다 흘려보낸다 — 한쪽이 첫 인식부터
/// 느리거나(콜드 스타트) 조용하면 나머지 쪽이라도 보여야 한다(코드 리뷰 F1). 승자가 한 번
/// 정해진 뒤에는 그 언어의 partial만 보인다. final은 짝이 맞을 때(구간 시작 시각 차이가
/// `tolerance` 안쪽) 비교해 확정한다. 동점이거나 둘 다 confidence가 없으면 직전 승자를
/// 유지한다.
///
/// 짝을 기다리는 final은 최대 하나(`awaiting`)만 들고 있는다. 그 짝이 영영 오지 않을 수
/// 있는 세 경우 — 상대 쪽 스트림이 이미 끝났거나(`sideEnded`), 다음 final이 짝이 아닌 채로
/// 도착하거나, `clock`의 여유 시간이 먼저 지나거나 — 에는 기다리던 쪽을 그대로 채택해
/// 흘려보낸다. 그래서 한쪽이 멎어도(스펙 §2 "한쪽 실패") 다른 쪽이 무한정 막히지 않는다.
actor DualArbitrator {
    enum Side: Sendable { case a, b }

    private struct Pending {
        let side: Side
        let chunk: TranscriptionChunk
    }

    private let tolerance: Double
    private let clock: any DualArbitratorClock
    private let continuation: AsyncThrowingStream<TranscriptionChunk, any Error>.Continuation
    private var winner: CaptionLanguage
    /// 승자를 한 번이라도 확정했는지. false인 동안은 partial을 언어로 거르지 않는다.
    private var hasWinner = false
    private var awaiting: Pending?
    /// `awaiting`을 새로 세울 때마다 올린다. grace 타이머가 뒤늦게 울렸을 때 그사이
    /// 다른 경로(정상 짝맺기·다음 final·sideEnded)로 이미 처리됐는지 이 값으로 가른다.
    private var awaitingToken = 0
    /// 지금 `awaiting`을 지키는 grace 타이머. 다른 경로로 먼저 해소되면 곧바로
    /// 취소한다 — 안 그러면 실행 내내(테스트라면 가짜 시계가 절대 안 울릴 때까지)
    /// 매달린 채로 남는다.
    private var graceTask: Task<Void, Never>?
    private var ended: Set<Side> = []
    private var lastError: (any Error)?

    init(initialWinner: CaptionLanguage, tolerance: Double = 0.2,
         clock: any DualArbitratorClock = RealTimeGraceClock(),
         continuation: AsyncThrowingStream<TranscriptionChunk, any Error>.Continuation) {
        self.winner = initialWinner
        self.tolerance = tolerance
        self.clock = clock
        self.continuation = continuation
    }

    func ingest(_ chunk: TranscriptionChunk, side: Side) {
        LatencyTiming.log("[자동] \(chunk.language.displayName) 쪽 \(chunk.isFinal ? "final" : "partial") "
            + "신뢰도=\(chunk.confidence.map { String(format: "%.3f", $0) } ?? "-") 구간=\(chunk.start)~\(chunk.end)")

        guard chunk.isFinal else {
            if !hasWinner || chunk.language == winner { continuation.yield(chunk) }
            return
        }

        if let pending = awaiting {
            // 이 pending은 여기서 어떻게든 끝난다 — grace 타이머를 취소해 정리한다.
            clearAwaiting()
            if pending.side != side, abs(pending.chunk.start - chunk.start) <= tolerance {
                adopt(decide(pending.chunk, chunk))
                return
            }
            // 짝이 아니다 — 같은 쪽이 또 냈거나 시간이 안 맞는다. 기다리던 것부터 흘려보내고
            // 이번 것을 새로 기다린다.
            adopt(pending.chunk)
            beginWaiting(side: side, chunk: chunk)
            return
        }

        if ended.contains(opposite(of: side)) {
            adopt(chunk) // 상대는 이미 끝났다 — 짝이 다시는 안 온다. 곧바로 채택한다.
        } else {
            beginWaiting(side: side, chunk: chunk)
        }
    }

    /// 한쪽 세션의 결과 스트림이 끝났다(정상 종료거나 오류). 기다리던 짝이 있으면 곧바로
    /// 흘려보낸다 — 다시는 짝이 올 수 없으므로. 둘 다 끝났으면 합류 스트림도 끝낸다.
    func sideEnded(_ side: Side, error: (any Error)?) {
        ended.insert(side)
        if let error { lastError = error }
        if let pending = awaiting {
            clearAwaiting()
            adopt(pending.chunk)
        }
        if ended.count >= 2 {
            if let lastError { continuation.finish(throwing: lastError) } else { continuation.finish() }
        }
    }

    /// 새 final을 기다림 상태로 걸고, `clock`이 여유 시간을 다 쓰면(상대가 안 오면)
    /// 곧바로 채택하는 백그라운드 타이머를 하나 띄운다. `ingest` 자신은 여기서 멈추지
    /// 않는다 — 타이머를 기다리느라 같은 쪽의 다음 조각 처리를 막지 않는다.
    private func beginWaiting(side: Side, chunk: TranscriptionChunk) {
        awaitingToken += 1
        let token = awaitingToken
        awaiting = Pending(side: side, chunk: chunk)
        let clock = clock
        graceTask = Task { [weak self] in
            await clock.waitGrace()
            await self?.graceExpired(token: token)
        }
    }

    private func graceExpired(token: Int) {
        // 토큰이 안 맞으면 이미 다른 경로로 처리된 뒤다 — 아무 일도 하지 않는다.
        guard token == awaitingToken, let pending = awaiting else { return }
        awaiting = nil
        graceTask = nil
        adopt(pending.chunk)
    }

    /// `awaiting`을 다른 경로(정상 짝맺기·다음 final·sideEnded)로 이미 처리할 때 부른다.
    /// 지키고 있던 grace 타이머를 취소해서 실행 내내(테스트라면 가짜 시계가 절대 안
    /// 울릴 때까지) 매달린 태스크로 남지 않게 한다. 토큰도 같이 올려 만에 하나 취소가
    /// 늦게 반영돼도 `graceExpired`가 스스로 무효화한다.
    private func clearAwaiting() {
        awaitingToken += 1
        awaiting = nil
        graceTask?.cancel()
        graceTask = nil
    }

    private func adopt(_ chunk: TranscriptionChunk) {
        winner = chunk.language
        hasWinner = true
        continuation.yield(chunk)
    }

    private func opposite(of side: Side) -> Side { side == .a ? .b : .a }

    /// 스펙 §2 선택 규칙: 둘 다 있으면 높은 쪽, 하나만 있으면 그쪽, 동점·둘 다 없으면
    /// 직전 승자(`winner`, 이 비교 시점의 값)를 유지한다.
    private func decide(_ a: TranscriptionChunk, _ b: TranscriptionChunk) -> TranscriptionChunk {
        switch (a.confidence, b.confidence) {
        case let (x?, y?):
            if x > y { return a }
            if y > x { return b }
            return a.language == winner ? a : b
        case (.some, nil): return a
        case (nil, .some): return b
        case (nil, nil): return a.language == winner ? a : b
        }
    }
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
        /// 자동 모드에서만 쓴다 — 부 언어 세션과 큐. 고정 모드에서는 항상 nil이다.
        var secondarySession: (any SpeechSession)?
        var secondaryQueue: AudioInputQueue?
        /// 자동 모드에서 두 세션의 결과 스트림을 `DualArbitrator`로 실어 나르는 태스크.
        var arbitrationTasks: [Task<Void, Never>] = []
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
    /// 자동 모드에서 `DualArbitrator`가 쓰는 시계. 테스트는 결정적인 가짜를 주입한다.
    private let autoModeGrace: any DualArbitratorClock
    private var current: Run?

    public var onEvent: (@MainActor (PipelineEvent) -> Void)?

    public init(engine: any SpeechEngine = SystemSpeechEngine(),
                makeSource: @escaping SourceFactory = { _ in MicSource() },
                autoModeGrace: any DualArbitratorClock = RealTimeGraceClock()) {
        self.engine = engine
        self.makeSource = makeSource
        self.autoModeGrace = autoModeGrace
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

        // 실행 ID는 세션에 넘겨서 세션이 직접 조각에 찍게 한다(생산 시점 스탬프) —
        // 교체 직전에 확정해 내보내는 마지막 문장도 이 값을 달고 나가 controller의
        // generation 필터에 걸려 사라지지 않는다. 그 문장이야말로 사용자가 방금 말한,
        // 잃으면 안 되는 문장이다. 이 Run 객체의 `id`/`language` 필드는 교체가
        // **확정 성공한 뒤에만** 갱신한다 — 실패하면 세션은 아무것도 찍지 않았으므로
        // 옛 조각은 여전히 옛 run.id를 달고 나가고, 재시작한 새 Run과 값이 겹치지 않는다.
        guard let swapped = try? await session.setLanguage(locale, runID: generation, language: language),
              swapped else { return false }
        guard current === run else { return false }

        await reserveIfNeeded(locale, run: run)
        guard current === run else { return false }

        run.id = generation
        run.configuration.language = language
        run.language = language
        run.ledger.breakUtterance()
        emit(run.id, .listening(language: language))
        return true
    }

    // MARK: 시작 절차

    private func startRun(_ run: Run) async throws {
        if let secondaryLanguage = run.configuration.secondaryLanguage {
            try await startDualRun(run, secondaryLanguage: secondaryLanguage)
        } else {
            try await startFixedRun(run)
        }
    }

    private func startFixedRun(_ run: Run) async throws {
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

        let results = try await session.start(format: analysisFormat, input: queue, runID: run.id, language: run.language)
        try checkAlive(run)

        run.resultsTask = Task { [weak self] in
            await self?.consume(results, run: run)
        }
        run.listening = true
        emit(run.id, .listening(language: run.language))
    }

    /// 자동 모드. 하드 제약(실측, 스펙 §2): 분석기 하나에 전사기 둘을 물리면 SIGTRAP —
    /// 그래서 언어별로 분석기·전사기·pump를 완전히 별개로 두 벌 돌리고, 변환된 오디오만
    /// `DualAudioSink`로 팬아웃한다. 두 세션의 결과는 `DualArbitrator`가 신뢰도로 골라
    /// 하나의 스트림으로 합치고, 그 뒤로는 `consume(_:run:)`이 고정 모드와 똑같이 받는다 —
    /// 발화 장부(ledger)·이벤트 스탬프 규칙이 갈라지지 않는다.
    private func startDualRun(_ run: Run, secondaryLanguage: CaptionLanguage) async throws {
        let primaryLanguage = run.configuration.language

        guard let primaryLocale = await engine.supportedLocale(equivalentTo: primaryLanguage.locale) else {
            throw PipelineError.unsupportedLanguage(primaryLanguage.displayName)
        }
        try checkAlive(run)
        guard let secondaryLocale = await engine.supportedLocale(equivalentTo: secondaryLanguage.locale) else {
            throw PipelineError.unsupportedLanguage(secondaryLanguage.displayName)
        }
        try checkAlive(run)

        let sessionA = try engine.makeSession(locale: primaryLocale, sensitivity: run.configuration.sensitivity)
        let sessionB = try engine.makeSession(locale: secondaryLocale, sensitivity: run.configuration.sensitivity)
        run.session = sessionA
        run.secondarySession = sessionB

        try await installAssets(sessionA, run: run, progressRange: 0.0..<0.5)
        try checkAlive(run)
        try await installAssets(sessionB, run: run, progressRange: 0.5..<1.0)
        try checkAlive(run)

        await reserveIfNeeded(primaryLocale, run: run)
        try checkAlive(run)
        await reserveIfNeeded(secondaryLocale, run: run)
        try checkAlive(run)

        let gate = AudioSinkGate()
        run.gate = gate
        let source = makeSource(run.configuration.source)
        run.source = source
        let captureFormat = try await source.start { buffer in gate.ingest(buffer) }
        try checkAlive(run)

        var negotiatedA = await sessionA.bestAudioFormat(considering: captureFormat)
        if negotiatedA == nil { negotiatedA = await sessionA.bestAudioFormat(considering: nil) }
        guard let formatA = negotiatedA else { throw PipelineError.noCompatibleFormat }
        try checkAlive(run)

        var negotiatedB = await sessionB.bestAudioFormat(considering: captureFormat)
        if negotiatedB == nil { negotiatedB = await sessionB.bestAudioFormat(considering: nil) }
        guard let formatB = negotiatedB else { throw PipelineError.noCompatibleFormat }
        try checkAlive(run)

        // 두 벌이 서로 다른 분석 포맷을 요구하면 오디오를 두 번 변환해야 한다 — 이
        // 기기에서는 한 번도 관찰되지 않았고(스펙 §2 하드 제약 실측 메모) 지원할 가치가
        // 낮다. 다르면 시작에 실패한다(호출자가 실패로 보고한다).
        guard formatA.sampleRate == formatB.sampleRate,
              formatA.channelCount == formatB.channelCount,
              formatA.commonFormat == formatB.commonFormat,
              formatA.isInterleaved == formatB.isInterleaved
        else { throw PipelineError.noCompatibleFormat }
        let analysisFormat = formatA
        LatencyTiming.log("자동 모드 협상된 분석 포맷(양쪽 공통): \(analysisFormat)")

        let queueA = AudioInputQueue(analysisFormat: analysisFormat)
        let queueB = AudioInputQueue(analysisFormat: analysisFormat)
        run.queue = queueA
        run.secondaryQueue = queueB
        gate.attach(DualAudioSink(analysisFormat: analysisFormat, primary: queueA, secondary: queueB))

        let streamA = try await sessionA.start(format: analysisFormat, input: queueA, runID: run.id, language: primaryLanguage)
        try checkAlive(run)
        let streamB = try await sessionB.start(format: analysisFormat, input: queueB, runID: run.id, language: secondaryLanguage)
        try checkAlive(run)

        let (merged, continuation) = AsyncThrowingStream<TranscriptionChunk, any Error>.makeStream()
        let arbitrator = DualArbitrator(initialWinner: run.language, clock: autoModeGrace, continuation: continuation)
        let taskA = Task {
            do {
                for try await chunk in streamA { await arbitrator.ingest(chunk, side: .a) }
                await arbitrator.sideEnded(.a, error: nil)
            } catch {
                await arbitrator.sideEnded(.a, error: error is CancellationError ? nil : error)
            }
        }
        let taskB = Task {
            do {
                for try await chunk in streamB { await arbitrator.ingest(chunk, side: .b) }
                await arbitrator.sideEnded(.b, error: nil)
            } catch {
                await arbitrator.sideEnded(.b, error: error is CancellationError ? nil : error)
            }
        }
        run.arbitrationTasks = [taskA, taskB]

        run.resultsTask = Task { [weak self] in
            await self?.consume(merged, run: run)
        }
        run.listening = true
        emit(run.id, .listening(language: run.language))
    }

    private func installAssets(_ session: any SpeechSession, run: Run, progressRange: Range<Double> = 0.0..<1.0) async throws {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let reporter = Task { [weak self] in
            for await fraction in stream {
                guard let self, self.current === run else { continue }
                let scaled = progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound)
                self.emit(run.id, .installing(fraction: scaled))
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
                // runID·언어는 조각에 이미 찍혀 있는 값만 쓴다(생산 시점 스탬프) — 여기서
                // run.id/run.language를 다시 읽지 않는다. hot swap 도중에는 그 필드들이
                // 이미 다음 상태로 넘어가 있을 수 있어, 그 순간 흘러오는 옛 조각에 새
                // 값을 잘못 입히게 된다.
                let transcript: Transcript = chunk.isFinal ? .final(chunk.text) : .partial(chunk.text)
                emit(chunk.runID, .transcript(TranscriptEvent(
                    utteranceID: assignment.id,
                    sourceLanguage: chunk.language,
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
        run.secondaryQueue?.finish()
        run.progressTask?.cancel()
        run.resultsTask?.cancel()
        for task in run.arbitrationTasks { task.cancel() }
        if let session = run.session { await session.finish() }
        if let secondarySession = run.secondarySession { await secondarySession.finish() }
        for locale in run.reservedLocales { await engine.release(locale: locale) }

        run.gate = nil
        run.source = nil
        run.queue = nil
        run.secondaryQueue = nil
        run.session = nil
        run.secondarySession = nil
        run.progressTask = nil
        run.resultsTask = nil
        run.arbitrationTasks = []
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
    /// 지금 나가는 조각에 찍을 실행 ID. `setLanguage`가 교체를 커밋하기 **직전**(finalize
    /// 호출 전)에 올려서, 그 finalize가 실어 내보내는 구제된 final도 이 값을 달고 나간다.
    /// pump는 이 값을 매 yield마다 살아있는 그대로 읽는다 — 언어(per-pump 고정)와 달리
    /// runID는 같은 pump가 살아있는 동안에도 바뀔 수 있어야 하기 때문이다.
    private var currentRunID: Int = 0

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
            // 자동 모드의 신뢰도 비교(스펙 §2)에 쓴다. 고정 모드에서는 계산만 되고
            // 아무도 읽지 않는다 — 세션 생성 경로를 자동/고정으로 가르지 않으려고
            // 항상 켠다.
            attributeOptions: [.transcriptionConfidence])
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

    func start(format: AVAudioFormat, input: AudioInputQueue, runID: Int, language: CaptionLanguage) async throws -> AsyncThrowingStream<TranscriptionChunk, any Error> {
        let analyzer = SpeechAnalyzer(modules: modules)
        // 협상된 포맷을 넘긴다. 분석기는 자동 리샘플링하지 않는다.
        try await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        self.analysisFormat = format
        self.currentRunID = runID

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, any Error>.makeStream()
        self.continuation = continuation
        startPump(language: language)

        analysisTask = Task { [weak self] in
            do { _ = try await analyzer.analyzeSequence(AnalyzerInputs(queue: input)) }
            catch { await self?.fail(error) }
        }
        return stream
    }

    func setLanguage(_ newLocale: Locale, runID: Int, language: CaptionLanguage) async throws -> Bool {
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
        // 여기까지는 아무것도 바꾸지 않았다 — 호환되지 않으면 옛 pump는 계속 옛
        // runID·언어를 찍은 채로 산다. 실패한 교체 뒤 호출자가 새 Run으로 재시작해도
        // 그 새 Run의 id와 겹치지 않는다.

        // 커밋 지점: finalize가 실어 내보낼 구제된 final부터 새 runID를 달고 나가야
        // controller의 generation 필터를 통과한다. 언어는 아직 올리지 않는다 —
        // 그 문장은 옛 언어로 말해진 것이다.
        currentRunID = runID

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
        startPump(language: language)
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
    ///
    /// `language`는 이 pump 인스턴스 수명 내내 고정된다(이 pump가 물린 transcriber가
    /// 그 언어로 인식하는 동안만 산다) — 나중에 `setLanguage`가 언어를 올려도 이미
    /// 돌고 있는(은퇴 예정인) pump는 옛 언어를 계속 찍는다. `runID`는 반대로 매
    /// yield마다 `currentRunID`를 살아있는 그대로 읽는다 — `setLanguage`가 finalize
    /// 직전에 미리 올려두면, 같은 pump가 실어 나르는 구제된 final도 새 runID를 단다.
    private func startPump(language: CaptionLanguage) {
        let results = transcriber.results
        let sink = continuation
        pumpTask = Task { [weak self] in
            do {
                for try await result in results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    guard let runID = await self?.currentRunID else { return }
                    sink?.yield(TranscriptionChunk(
                        text: text,
                        isFinal: result.isFinal,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        runID: runID,
                        language: language,
                        confidence: result.isFinal ? Self.meanConfidence(result.text) : nil))
                }
            } catch {
                guard !Task.isCancelled else { return }
                sink?.finish(throwing: error)
            }
        }
    }

    /// `result.text.runs`에 달린 `AttributeScopes.SpeechAttributes.ConfidenceAttribute`의
    /// 평균. 런이 하나도 없으면(속성이 안 붙는 드문 경우) nil — 자동 모드 선택 규칙(스펙
    /// §2)은 nil을 "낮음"으로 다룬다.
    private static func meanConfidence(_ text: AttributedString) -> Double? {
        let values = text.runs.compactMap { $0.attributes[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func fail(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        continuation?.finish(throwing: error)
    }
}

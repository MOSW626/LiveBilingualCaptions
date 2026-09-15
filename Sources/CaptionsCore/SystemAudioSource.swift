import AVFoundation
import Foundation
import ScreenCaptureKit
import Synchronization

// MARK: - 시계

/// `SystemAudioSource`가 무음 제한 시간을 재는 데 쓰는 시계. 실제 구현은 `Task.sleep`을
/// 쓰고, 테스트는 수동으로 재개되는 가짜를 넣어 실제 5초를 기다리지 않고 시간 초과 경로를
/// 확인한다. 호출은 `SystemAudioSource`가 만든, MainActor 격리를 물려받는 `Task`에서만
/// 나가므로 `Sendable`일 필요가 없다.
@MainActor
public protocol SystemAudioClock {
    func sleep(seconds: Double) async throws
}

public struct RealSystemAudioClock: SystemAudioClock {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - 캡처 백엔드 (테스트 가능한 경계)

/// `SCStream` 캡처 한 번의 최소 인터페이스. 실제 구현(`SCStreamCaptureBackend`)은
/// 화면 기록 권한과 디스플레이가 있어야 동작한다. `SystemAudioSource`는 이 프로토콜에만
/// 의존해서, 테스트는 가짜를 주입해 권한·디스플레이 없이 시작/정지 계약(토큰·게이트·
/// 제한 시간)만 검증한다.
///
/// 호출은 전부 MainActor(`SystemAudioSource`)에서 나간다 — `AudioSource`와 같은 이유로
/// 프로토콜 자체를 MainActor에 묶는다. sink/onError 클로저만 캡처 스레드에서 불리므로
/// 그 둘만 `@Sendable`이다. `SCStreamOutput`/`SCStreamDelegate` 콜백(`SCStreamCaptureBackend`
/// 참고)은 이 프로토콜에 속하지 않으므로 이 제약과 무관하게 여전히 sample queue에서 산다.
@MainActor
public protocol SystemCaptureBackend {
    /// `sink`/`onError`는 이 함수를 부르기 전에 이미 설치가 끝나 있어야 한다 — 첫 유효
    /// 버퍼가 이 함수의 반환보다 먼저 올 수 있기 때문이다(SCStream의 실제 동작).
    func startCapture(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) async throws
    func stopCapture() async
}

// MARK: - 실행 게이트

/// 한 실행의 신원이자 sink 차단 스위치. 클래스 동일성이 곧 "이 실행"이라는 토큰이다.
/// `disable()`은 이후 도착하는 모든 콜백을 조용히 막는다 — stop()과 경쟁하는 버퍼,
/// 이전 실행의 뒤늦은 콜백이 전부 이 문을 못 넘는다. 캡처 콜백(어떤 스레드에서든)과
/// MainActor(start/stop)가 같이 만지므로 `Mutex`로 지킨다.
private final class RunGate: Sendable {
    private let active = Mutex(true)

    func disable() { active.withLock { $0 = false } }

    func run(_ body: () -> Void) {
        guard active.withLock({ $0 }) else { return }
        body()
    }
}

// MARK: - SystemAudioSource

/// ScreenCaptureKit으로 시스템 오디오를 캡처하는 `AudioSource`.
///
/// `SCStreamOutput`/`SCStreamDelegate` 콜백은 `SystemCaptureBackend`(실제 구현은
/// `SCStreamCaptureBackend`) 안, sample queue에서 산다. 여기 `SystemAudioSource`는
/// MainActor 상태를 sink/onError 클로저 안에서 절대 직접 건드리지 않는다 — 넘어오는 건
/// 이미 복사·변환된 `AVAudioPCMBuffer`이거나 오류 값뿐이다.
///
/// 시작마다 새 `RunGate`(토큰 역할)와 새 `FormatGate`를 만든다. gate와 sink는
/// `startCapture()`를 부르기 **전에** 설치한다 — 기준 초안은 이 순서를 반대로 해서,
/// 첫 버퍼가 `startCapture()` 도중에 도착하면 받아줄 곳이 없어 영원히 기다렸다.
///
/// `stop()`은 토큰(RunGate) 무효화 → gate를 취소로 완료 → `stopCapture()`를 await,
/// 순서를 지킨다. 무효화가 먼저라 이후 도착하는 콜백은 전부 버려진다.
@MainActor
public final class SystemAudioSource: AudioSource {
    private let timeoutSeconds: Double
    private let clock: any SystemAudioClock
    private let makeBackend: @MainActor () -> any SystemCaptureBackend

    private var currentGate: FormatGate?
    private var runGate: RunGate?
    private var backend: (any SystemCaptureBackend)?

    public init(
        timeoutSeconds: Double = 5,
        clock: any SystemAudioClock = RealSystemAudioClock(),
        makeBackend: @escaping @MainActor () -> any SystemCaptureBackend = { SCStreamCaptureBackend() }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.clock = clock
        self.makeBackend = makeBackend
    }

    public func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        let gate = FormatGate()
        let runGate = RunGate()
        let backend = makeBackend()
        currentGate = gate
        self.runGate = runGate
        self.backend = backend

        // 캡처 콜백 스레드에서만 쓰인다. MainActor 프로퍼티는 여기서 절대 건드리지 않는다 —
        // 대신 이 함수 스코프의 지역 상수(gate, runGate, sink)만 캡처한다.
        let guardedSink: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            runGate.run {
                // 첫 유효 버퍼가 포맷을 정한다. 이후 버퍼는 gate가 이미 찬 상태라 조용히 씹힌다.
                gate.complete(.success(buffer.format))
                sink(buffer)
            }
        }
        let onError: @Sendable (any Error) -> Void = { error in
            runGate.run { gate.fail(error) }
        }

        let format: AVAudioFormat
        do {
            format = try await withTaskCancellationHandler {
                try await backend.startCapture(sink: guardedSink, onError: onError)
                let timeoutTask = Task { [clock, timeoutSeconds] in
                    try? await clock.sleep(seconds: timeoutSeconds)
                    guard !Task.isCancelled else { return }
                    // 무음이면 첫 버퍼가 영원히 안 온다 — 여기서 gate를 풀어 대기가 끝나게 한다.
                    gate.fail(AudioSourceError.captureTimedOut)
                }
                defer { timeoutTask.cancel() }
                return try await gate.wait()
            } onCancel: {
                // 취소 시점이 startCapture() 도중이든 gate 대기 중이든 안전하다 — gate.fail은
                // 선착순 한 번만 효력이 있고, disable은 그 뒤에 뭘 더 해도 무해하게 만든다.
                runGate.disable()
                gate.fail(CancellationError())
            }
        } catch {
            runGate.disable()
            gate.fail(error)
            // stop()이 이미 이 실행을 치웠다면(대기 중 정지 경쟁) 여기서 다시 stopCapture()를
            // 부르지 않는다 — 실제 백엔드는 중복 호출을 무해하게 씹지만, 횟수 자체가 계약이다.
            await stopIfStillOwned(backend, runGate: runGate)
            throw error
        }

        // start() 대기 중에 stop()이 먼저 불려 이 실행이 이미 버려졌을 수 있다 — 그때는
        // stop()이 이미 stopCapture()까지 마쳤으므로 여기서 다시 부르지 않는다.
        guard self.runGate === runGate else { throw CancellationError() }
        return format
    }

    public func stop() async {
        guard let runGate, let backend else { return }
        self.runGate = nil
        self.backend = nil
        let gate = currentGate
        currentGate = nil
        // 무효화가 먼저다 — 이후 어떤 콜백이 와도 문이 닫혀 있다.
        runGate.disable()
        gate?.fail(CancellationError())
        await backend.stopCapture()
    }

    /// 이 실행이 아직 `self`가 쥐고 있는 실행이면(=stop()이 끼어들지 않았으면) 정리하고
    /// stopCapture()를 부른다. 이미 다른 경로가 정리했다면 조용히 넘어간다.
    private func stopIfStillOwned(_ backend: any SystemCaptureBackend, runGate: RunGate) async {
        guard self.runGate === runGate else { return }
        self.runGate = nil
        self.backend = nil
        currentGate = nil
        await backend.stopCapture()
    }
}

// MARK: - 실제 SCStream 구현

/// 실제 `SCStream` 캡처. 화면 기록 권한과 디스플레이가 필요해서 테스트는 이 타입을
/// 만들지 않는다 — `SystemAudioSourceTests`는 `SystemCaptureBackend` 가짜로 돈다.
public final class SCStreamCaptureBackend: NSObject, SystemCaptureBackend, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // sink/onError는 MainActor(startCapture/stopCapture)와 sample queue(SCStreamOutput
    // 콜백)가 같이 만진다. Mutex 하나로 그 상태만 지키고, 클래스 전체는 SCStreamOutput/
    // SCStreamDelegate가 nonisolated 콜백이라 필요한 @unchecked Sendable이다.
    private struct State {
        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onError: (@Sendable (any Error) -> Void)?
    }
    private let state = Mutex(State())
    private let sampleQueue = DispatchQueue(label: "SystemAudioSource.sampleQueue")
    private var stream: SCStream?

    public override init() { super.init() }

    public func startCapture(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) async throws {
        state.withLock {
            $0.sink = sink
            $0.onError = onError
        }

        guard let display = try await SCShareableContent.current.displays.first else {
            throw AudioSourceError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 오디오만 필요하다 — 화면 프레임 생산을 최대한 줄여 비용을 낮춘다.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    public func stopCapture() async {
        state.withLock {
            $0.sink = nil
            $0.onError = nil
        }
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput — sample queue에서 호출된다. MainActor를 건드리지 않는다.

    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.numSamples > 0,
              let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else {
            report(.captureFailed("PCM 버퍼 할당 실패"))
            return
        }
        buffer.frameLength = buffer.frameCapacity
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
        } catch {
            report(.captureFailed("PCM 복사 실패: \(error.localizedDescription)"))
            return
        }
        state.withLock { $0.sink }?(buffer)
    }

    // MARK: SCStreamDelegate

    public nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.onError }?(error)
    }

    private nonisolated func report(_ error: AudioSourceError) {
        state.withLock { $0.onError }?(error)
    }
}

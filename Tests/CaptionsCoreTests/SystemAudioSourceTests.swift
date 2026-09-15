import AVFoundation
import Foundation
import Testing
@testable import CaptionsCore

// SystemAudioSource의 시작/정지 계약만 본다: 토큰·게이트·제한 시간. 실제 SCStream은
// 화면 기록 권한과 디스플레이가 있어야 해서 이 환경에서 돌릴 수 없다 — SystemCaptureBackend
// 가짜를 주입해 그 경계 아래만 검증한다. sine/micFormat48kStereo/Signal/Locked는
// PipelineControllerTests.swift의 공용 도구를 그대로 쓴다.

// MARK: - 가짜 캡처 백엔드

@MainActor
final class FakeCaptureBackend: SystemCaptureBackend {
    var startError: (any Error)?
    /// true면 startCapture()가 release()까지 매달린다 — 정지/취소가 시작 도중과 경쟁하는 걸 본다.
    var blocksUntilReleased = false
    /// 설정하면 startCapture()가 반환하기 **전에** 이 버퍼를 낸다(SCStream의 실제 동작 — 첫
    /// 버퍼가 시작 호출의 반환보다 먼저 올 수 있다).
    var emitsBeforeReturning: AVAudioPCMBuffer?

    let startSuspended = Signal()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var onError: (@Sendable (any Error) -> Void)?
    private var pending: CheckedContinuation<Void, any Error>?

    func startCapture(
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) async throws {
        startCount += 1
        self.sink = sink
        self.onError = onError
        if let buffer = emitsBeforeReturning { sink(buffer) }
        if let startError { throw startError }
        if blocksUntilReleased {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    pending = continuation
                    startSuspended.fire()
                }
            } onCancel: {
                Task { @MainActor in self.release(throwing: CancellationError()) }
            }
        }
    }

    func stopCapture() async { stopCount += 1 }

    func release(throwing error: (any Error)? = nil) {
        guard let pending else { return }
        self.pending = nil
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }

    /// 캡처 콜백을 흉내낸다 — 실제로는 sample queue에서, 여기서는 그냥 동기 호출한다.
    func emit(_ buffer: AVAudioPCMBuffer) { sink?(buffer) }
    func emitError(_ error: any Error) { onError?(error) }
}

// MARK: - 가짜 시계

/// 수동으로 재개되는 가짜 시계. 실제 5초를 기다리지 않고 무음 제한 시간 경로를 확인한다.
@MainActor
final class FakeClock: SystemAudioClock {
    private var continuation: CheckedContinuation<Void, any Error>?
    let sleepRequested = Signal()
    private(set) var lastRequestedSeconds: Double?

    func sleep(seconds: Double) async throws {
        lastRequestedSeconds = seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                sleepRequested.fire()
            }
        } onCancel: {
            Task { @MainActor in self.release(throwing: CancellationError()) }
        }
    }

    /// 무음 제한 시간이 다 됐다고 알린다.
    func fireTimeout() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }

    private func release(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

// MARK: - 도구

@MainActor
private func makeSource(
    timeoutSeconds: Double = 5,
    clock: any SystemAudioClock = FakeClock(),
    backend: FakeCaptureBackend = FakeCaptureBackend()
) -> SystemAudioSource {
    SystemAudioSource(timeoutSeconds: timeoutSeconds, clock: clock, makeBackend: { backend })
}

// MARK: - A. 첫 포맷 경합

@Test @MainActor func 결과가_대기보다_먼저_도착하면_그_포맷으로_시작한다() async throws {
    let backend = FakeCaptureBackend()
    backend.emitsBeforeReturning = sine(micFormat48kStereo, frames: 4800)
    let source = makeSource(backend: backend)

    let format = try await source.start { _ in }
    #expect(format == micFormat48kStereo)
    #expect(backend.startCount == 1)
}

@Test @MainActor func 대기_후_첫_버퍼가_도착하면_그_포맷으로_시작한다() async throws {
    let backend = FakeCaptureBackend()
    let source = makeSource(backend: backend)
    let received = Locked<[AVAudioPCMBuffer]>([])

    let startTask = Task { try await source.start { buffer in received.mutate { $0.append(buffer) } } }
    // startCapture()가 반환하고 start()가 gate.wait()에서 실제로 멈출 때까지 양보한다.
    while backend.startCount == 0 { await Task.yield() }
    await Task.yield()

    let buffer = sine(micFormat44kMono, frames: 4410)
    backend.emit(buffer)

    let format = try await startTask.value
    #expect(format == micFormat44kMono)
    #expect(received.wrapped.count == 1)
}

@Test @MainActor func 무음이면_제한_시간_뒤_한국어_메시지로_실패하고_스트림을_정리한다() async throws {
    let clock = FakeClock()
    let backend = FakeCaptureBackend()
    let source = makeSource(timeoutSeconds: 5, clock: clock, backend: backend)

    let startTask = Task { try await source.start { _ in } }
    await clock.sleepRequested.wait()
    #expect(clock.lastRequestedSeconds == 5)
    clock.fireTimeout()

    do {
        _ = try await startTask.value
        Issue.record("시간 초과가 오류를 던지지 않았다")
    } catch {
        #expect(error.localizedDescription == "오디오 입력을 기다리다 중단했습니다. 재생 후 다시 시작하세요")
    }
    #expect(backend.stopCount == 1)
}

@Test @MainActor func 캡처_시작_실패는_그대로_던져지고_스트림이_정리된다() async throws {
    enum StartFailure: Error { case boom }
    let backend = FakeCaptureBackend()
    backend.startError = StartFailure.boom
    let source = makeSource(backend: backend)

    await #expect(throws: StartFailure.self) {
        _ = try await source.start { _ in }
    }
    #expect(backend.stopCount == 1)
}

// MARK: - B. 정지·취소 경합

@Test @MainActor func 대기_중_stop을_부르면_취소로_끝나고_한_번만_정리된다() async throws {
    let backend = FakeCaptureBackend()
    let source = makeSource(backend: backend)

    let startTask = Task { try await source.start { _ in } }
    while backend.startCount == 0 { await Task.yield() }
    await Task.yield() // gate.wait()에서 실제로 멈출 때까지 한 번 더 양보한다.

    await source.stop()

    await #expect(throws: CancellationError.self) { try await startTask.value }
    // stop() 자신의 stopCapture() 한 번뿐이다 — start()의 정리 경로가 중복으로 부르지 않는다.
    #expect(backend.stopCount == 1)
}

@Test @MainActor func 시작_도중_취소되면_매달린_startCapture가_풀리고_정리된다() async throws {
    let backend = FakeCaptureBackend()
    backend.blocksUntilReleased = true
    let source = makeSource(backend: backend)

    let startTask = Task { try await source.start { _ in } }
    await backend.startSuspended.wait()

    startTask.cancel()

    await #expect(throws: CancellationError.self) { try await startTask.value }
    #expect(backend.stopCount == 1)
}

@Test @MainActor func stop과_첫_버퍼가_동시에_도착해도_안전하다() async throws {
    let backend = FakeCaptureBackend()
    let source = makeSource(backend: backend)
    let received = Locked<Int>(0)

    let startTask = Task { try await source.start { _ in received.mutate { $0 += 1 } } }
    while backend.startCount == 0 { await Task.yield() }
    await Task.yield()

    // 버퍼가 오는 바로 그 순간 정지도 걸린다. 버퍼 콜백이 stop()보다 먼저 gate를 채웠을
    // 수도 있다 — 그러면 start()는 성공하고, 곧바로 stop()이 그 실행을 정지시킨다.
    // 어느 쪽이든 중복 재개나 충돌 없이 한쪽으로 정확히 끝나야 한다.
    backend.emit(sine(micFormat48kStereo, frames: 4800))
    await source.stop()

    do {
        _ = try await startTask.value
    } catch {
        #expect(error is CancellationError)
    }
    #expect(backend.stopCount >= 1)
}

// MARK: - C. 재시작과 옛 콜백

@Test @MainActor func 같은_소스를_재시작하면_새_게이트와_포맷을_쓴다() async throws {
    let firstBackend = FakeCaptureBackend()
    let secondBackend = FakeCaptureBackend()
    var handedOutFirst = true
    let source = SystemAudioSource(clock: FakeClock(), makeBackend: {
        defer { handedOutFirst = false }
        return handedOutFirst ? firstBackend : secondBackend
    })

    firstBackend.emitsBeforeReturning = sine(micFormat48kStereo, frames: 4800)
    let firstFormat = try await source.start { _ in }
    #expect(firstFormat == micFormat48kStereo)
    await source.stop()

    secondBackend.emitsBeforeReturning = sine(micFormat44kMono, frames: 4410)
    let secondFormat = try await source.start { _ in }
    #expect(secondFormat == micFormat44kMono)
    #expect(firstBackend.stopCount == 1)
    #expect(secondBackend.startCount == 1)
    await source.stop()
    #expect(secondBackend.stopCount == 1)
}

@Test @MainActor func 이전_실행의_뒤늦은_콜백은_새_실행에_영향을_주지_않는다() async throws {
    let firstBackend = FakeCaptureBackend()
    let secondBackend = FakeCaptureBackend()
    var handedOutFirst = true
    let source = SystemAudioSource(clock: FakeClock(), makeBackend: {
        defer { handedOutFirst = false }
        return handedOutFirst ? firstBackend : secondBackend
    })

    firstBackend.emitsBeforeReturning = sine(micFormat48kStereo, frames: 4800)
    _ = try await source.start { _ in }
    await source.stop()

    let startTask = Task { try await source.start { _ in } }
    while secondBackend.startCount == 0 { await Task.yield() }
    await Task.yield()

    // 옛 백엔드가 뒤늦게 콜백을 흘려도(이미 stop() 했지만) 새 실행의 게이트는 못 건드린다.
    firstBackend.emit(sine(micFormat48kStereo, frames: 4800))
    firstBackend.emitError(NSError(domain: "stale", code: 1))

    // 새 실행은 자기 백엔드의 버퍼로만 끝난다.
    secondBackend.emit(sine(micFormat44kMono, frames: 4410))
    let format = try await startTask.value
    #expect(format == micFormat44kMono)
}

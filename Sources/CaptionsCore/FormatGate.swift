import AVFoundation
import Synchronization

/// 첫 오디오 포맷을 기다리는 **일회성** 관문.
///
/// 핵심은 "결과가 대기보다 먼저 와도 저장한다"는 것이다. 기준 초안은 `startCapture()`를
/// 먼저 부르고 그 다음에 continuation을 등록해서, 첫 버퍼가 그 사이에 도착하면 결과를
/// 받아줄 곳이 없어 영원히 기다렸다. 여기서는 결과를 상태에 적어두고, 늦게 온 `wait()`은
/// 저장된 결과를 즉시 돌려받는다.
///
/// 샘플 큐(완료)와 MainActor(대기)가 같이 만지므로 `Mutex` 하나로 지킨다. 완료는 선착순
/// 한 번만 효력이 있어서 — 첫 버퍼·시작 실패·delegate 오류·취소·정지·제한 시간이 한꺼번에
/// 몰려도 — continuation은 정확히 한 번만 재개된다.
public final class FormatGate: Sendable {
    private struct State {
        var result: Result<AVAudioFormat, any Error>?
        var waiter: CheckedContinuation<AVAudioFormat, any Error>?
    }

    private let state = Mutex(State())

    public init() {}

    public var isResolved: Bool { state.withLock { $0.result != nil } }

    /// 처음 한 번만 효력이 있다. 이후 호출은 조용히 무시된다.
    public func complete(_ result: Result<AVAudioFormat, any Error>) {
        // continuation 재개는 락 **밖에서** 한다. 재개된 쪽이 곧바로 이 gate를 다시
        // 만지면 같은 락을 두 번 잡게 된다.
        let waiter = state.withLock { state -> CheckedContinuation<AVAudioFormat, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
    }

    public func fail(_ error: any Error) { complete(.failure(error)) }

    /// 대기자는 하나뿐이다 — `start()` 한 번이 이 gate 하나를 기다린다.
    public func wait() async throws -> AVAudioFormat {
        try await withCheckedThrowingContinuation { continuation in
            let stored = state.withLock { state -> Result<AVAudioFormat, any Error>? in
                if let result = state.result { return result }
                precondition(state.waiter == nil, "FormatGate는 대기자를 하나만 받는다")
                state.waiter = continuation
                return nil
            }
            if let stored { continuation.resume(with: stored) }
        }
    }
}

import AVFoundation

public enum AudioSourceError: LocalizedError {
    case noInput
    case permissionDenied
    case noDisplay
    /// 첫 오디오 버퍼가 제한 시간 안에 도착하지 않았다(재생 중인 소리가 없거나 무음).
    case captureTimedOut
    /// CMSampleBuffer → AVAudioPCMBuffer 변환에 실패했다. 조용히 버리지 않고 실행 오류로 알린다.
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: "마이크 입력을 찾지 못했습니다"
        case .permissionDenied: "권한이 거부되었습니다"
        case .noDisplay: "캡처할 디스플레이를 찾지 못했습니다"
        case .captureTimedOut: "오디오 입력을 기다리다 중단했습니다. 재생 후 다시 시작하세요"
        case .captureFailed(let reason): "오디오 캡처 처리에 실패했습니다: \(reason)"
        }
    }
}

/// 오디오 한 줄기. 구현은 마이크와 시스템 오디오 두 가지다.
@MainActor
public protocol AudioSource: AnyObject {
    /// 캡처를 시작하고 실제 오디오 포맷을 돌려준다.
    /// sink는 콜백이 반환되기 전에 버퍼를 복사/변환한다. 빌린 버퍼를 비동기로 보관하지 않는다.
    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat
    func stop() async
}

/// AVAudioEngine 마이크 입력. 마이크 권한만 필요하고 화면 기록 권한은 필요 없다.
@MainActor
public final class MicSource: AudioSource {
    private let engine = AVAudioEngine()
    private var started = false

    public init() {}

    public func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AudioSourceError.noInput }

        input.removeTap(onBus: 0)
        // installTap의 블록은 인라인으로 쓰면 감싸는 @MainActor start(_:)의 격리를 물려받는다
        // (블록 타입 자체는 @Sendable이 아니라서 추론이 컨텍스트를 따라간다). AVAudioEngine은
        // 이 블록을 realtime 오디오 스레드에서 부르므로, MainActor로 격리된 채로 불리면
        // 런타임에 executor assert가 터진다(SIGTRAP). 명시적 @Sendable 타입 지역 변수에
        // 먼저 담아서 바인딩하면 MainActor를 물려받지 않고, sink 하나만 캡처한다 — self도,
        // 다른 MainActor 상태도 캡처하지 않는다.
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            sink(buffer)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tapBlock)
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        started = true
        return format
    }

    public func stop() async {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        started = false
    }
}

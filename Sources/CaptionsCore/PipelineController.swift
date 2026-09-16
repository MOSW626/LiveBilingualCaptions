import Foundation

/// 파이프라인의 **유일한** 진입점.
///
/// 버튼마다 `Task { stop; start }`를 만들면 두 요청이 겹치면서 옛 실행이 새 실행을
/// 정리해버린다. 그래서 요청은 동기적으로 받아 generation만 올리고(그리고 진행 중인
/// 시작을 즉시 취소하고), worker 하나가 "이전 실행 정리 → 최신 요청 시작"을 순서대로
/// 돌린다. 빠르게 눌러대도 마지막 요청 하나만 살아남는다.
@MainActor
public final class PipelineController {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case listening
        case stopping
        case failed(String)
    }

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    public var onState: ((State) -> Void)?
    public var onEvent: ((PipelineEvent) -> Void)?

    private let pipeline: SpeechPipeline
    private var generation = 0
    /// nil = 정지 요청.
    private var desired: PipelineConfiguration?
    /// 지금 실제로 듣고 있는 설정. `.listening`을 받은 뒤에만 채운다.
    private var live: PipelineConfiguration?
    private var attempted: PipelineConfiguration?
    private var worker: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    public init(pipeline: SpeechPipeline) {
        self.pipeline = pipeline
        pipeline.onEvent = { [weak self] event in self?.handle(event) }
    }

    public var currentGeneration: Int { generation }

    public func requestStart(configuration: PipelineConfiguration) { submit(configuration) }
    public func requestReconfigure(configuration: PipelineConfiguration) { submit(configuration) }
    public func requestStop() { submit(nil) }

    private func submit(_ configuration: PipelineConfiguration?) {
        generation += 1
        desired = configuration
        if configuration != nil {
            state = .starting
        } else if !isFailed {
            // 실패 메시지는 정지 요청으로 덮지 않는다 — 사용자가 이유를 봐야 한다.
            state = .stopping
        }
        // 진행 중인 시작을 즉시 끊는다. 다운로드가 취소를 무시하고 끝나더라도
        // 다음 await의 checkCancellation에서 걸려 캡처는 켜지지 않는다.
        runTask?.cancel()
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while true {
            let generationAtStart = generation
            let target = desired

            // 언어만 바뀌었고 이미 듣고 있으면 실행을 끊지 않고 모듈만 교체한다.
            // 민감도나 소스가 바뀌면 모듈 구성 자체가 달라지므로 재시작한다.
            // secondaryLanguage가 같아야만 hot swap을 시도한다 — 모드 자체가 바뀌면
            // (고정↔자동) 언어 값이 같아도 세션 구성(한 벌 vs 두 벌)이 통째로 달라져서
            // switchLanguage가 다룰 수 있는 범위를 벗어난다. 그런 변경은 재시작이다.
            if let target, let live,
               live.source == target.source,
               live.sensitivity == target.sensitivity,
               live.language != target.language,
               live.secondaryLanguage == target.secondaryLanguage,
               pipeline.isListening {
                attempted = target
                if await pipeline.switchLanguage(to: target.language, generation: generationAtStart) {
                    if generation == generationAtStart { break }
                    continue
                }
            }

            await pipeline.stop()
            live = nil

            guard let target else {
                if generation == generationAtStart {
                    if !isFailed { state = .stopped }
                    break
                }
                continue
            }

            attempted = target
            let task = Task { [pipeline] in
                await pipeline.start(target, generation: generationAtStart)
            }
            runTask = task
            await task.value
            runTask = nil

            if generation == generationAtStart { break }
        }
        worker = nil
    }

    private func handle(_ event: PipelineEvent) {
        // 현행 실행의 이벤트만 통과시킨다. 옛 실행의 뒤늦은 결과·오류는 버린다.
        guard event.runID == generation else { return }
        onEvent?(event)

        switch event.kind {
        case .listening:
            live = attempted
            state = .listening
        case .failed(let message):
            live = nil
            state = .failed(message)
            // 오류는 숨기지 않는다 — 알린 뒤 실행을 정지한다.
            requestStop()
        case .installing, .transcript:
            break
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

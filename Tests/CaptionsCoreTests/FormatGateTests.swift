import AVFoundation
import Testing
@testable import CaptionsCore

// FormatGate 하나의 계약만 본다: 결과가 대기보다 먼저 와도 저장하고, 대기가 먼저면
// 나중 결과로 재개하고, 첫 완료만 효력이 있다. sleep은 쓰지 않는다 — "대기가 먼저"
// 경로는 Task.yield로 자식 태스크가 continuation 등록을 마칠 때까지 양보한다.
// (실제 시간을 재는 게 아니라 스케줄러에게 진행 기회를 주는 협력적 지점이다.)

private let formatA = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
private let formatB = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

private enum GateTestError: Error, Equatable { case boom }

@Test func 결과가_먼저_오면_대기는_즉시_받는다() async throws {
    let gate = FormatGate()
    #expect(!gate.isResolved)
    gate.complete(.success(formatA))
    #expect(gate.isResolved)
    let result = try await gate.wait()
    #expect(result === formatA)
}

@Test func 오류가_먼저_와도_대기는_즉시_던진다() async throws {
    let gate = FormatGate()
    gate.fail(GateTestError.boom)
    await #expect(throws: GateTestError.boom) {
        _ = try await gate.wait()
    }
}

@Test func 대기가_먼저_등록되면_나중_결과로_재개된다() async throws {
    let gate = FormatGate()
    let waitTask = Task { try await gate.wait() }
    await Task.yield()
    #expect(!gate.isResolved)
    gate.complete(.success(formatA))
    let result = try await waitTask.value
    #expect(result === formatA)
}

@Test func 대기가_먼저_등록되면_나중_오류로_재개된다() async throws {
    let gate = FormatGate()
    let waitTask = Task { try await gate.wait() }
    await Task.yield()
    gate.fail(GateTestError.boom)
    await #expect(throws: GateTestError.boom) {
        _ = try await waitTask.value
    }
}

@Test func 첫_완료만_효력이_있고_이후_완료는_무시된다() async throws {
    let gate = FormatGate()
    let waitTask = Task { try await gate.wait() }
    await Task.yield()
    gate.complete(.success(formatA))
    gate.complete(.success(formatB))  // 무시된다
    gate.fail(GateTestError.boom)     // 이것도 무시된다
    let result = try await waitTask.value
    #expect(result === formatA)
}

@Test func 완료가_먼저여도_이후_완료는_무시된다() async throws {
    let gate = FormatGate()
    gate.fail(GateTestError.boom)
    gate.complete(.success(formatA))  // 무시된다 — 첫 완료가 실패였다
    await #expect(throws: GateTestError.boom) {
        _ = try await gate.wait()
    }
}

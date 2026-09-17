import AVFoundation
import Foundation
import Testing
@testable import CaptionsCore

// 스펙 §2 검증: "실제 음성은 `say` 파일로 ko/en 각각 올바른 언어가 채택되는지 프로브".
//
// 이 파일은 가짜가 아니라 **진짜** SystemSpeechEngine·SpeechPipeline·PipelineController를
// 파일 오디오로 돌린다 — 모델 다운로드·실제 인식 추론이 필요해 몇 초에서 몇십 초가 걸리고
// 이 기기 밖에서는 재현되지 않을 수 있어서, 평소 `./test.sh`에서는 즉시 반환한다(트리비얼
// 통과). `LBC_DUAL_PROBE=1 ./test.sh --filter 실제_ko_en` 로 직접 돌릴 때만 실제로 확인한다.

/// AIFF 파일을 실시간 배속에 맞춰 흘려보내는 `AudioSource`. 마이크 대신 쓴다 — 파일 길이를
/// 넘는 속도로 밀어 넣으면 `AudioInputQueue`의 2초 상한을 순식간에 넘겨버리므로, 버퍼
/// 길이만큼 잠들었다가 다음 조각을 내보낸다(실제 마이크 tap과 같은 페이싱).
@MainActor
private final class FileAudioSource: AudioSource {
    private let url: URL
    private var feedTask: Task<Void, Never>?

    init(url: URL) { self.url = url }

    func start(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws -> AVAudioFormat {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        feedTask = Task.detached {
            let chunk: AVAudioFrameCount = 4096
            var remaining = totalFrames
            while remaining > 0, !Task.isCancelled {
                let toRead = min(chunk, remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
                do { try file.read(into: buffer, frameCount: toRead) } catch { break }
                guard buffer.frameLength > 0 else { break }
                sink(buffer)
                remaining -= toRead
                let seconds = Double(buffer.frameLength) / format.sampleRate
                try? await Task.sleep(for: .seconds(seconds))
            }
            // `say` 출력은 뒤에 유의미한 무음이 거의 없다 — SpeechDetector가 "말이
            // 끝났다"고 볼 만한 침묵을 실제 마이크처럼 흉내내려고 무음 5초를 덧붙인다.
            // 이게 없으면 VAD가 발화 경계를 못 잡아 끝까지 partial로만 남을 수 있다
            // (2초로는 부족했다 — 고정 모드 대조 실험에서 5초로 확인).
            var silenceRemaining = AVAudioFrameCount(format.sampleRate * 5)
            while silenceRemaining > 0, !Task.isCancelled {
                let toEmit = min(chunk, silenceRemaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toEmit) else { break }
                buffer.frameLength = toEmit
                for channel in 0..<Int(format.channelCount) {
                    if let data = buffer.floatChannelData?[channel] {
                        data.update(repeating: 0, count: Int(toEmit))
                    } else if let data = buffer.int16ChannelData?[channel] {
                        data.update(repeating: 0, count: Int(toEmit))
                    }
                }
                sink(buffer)
                silenceRemaining -= toEmit
                try? await Task.sleep(for: .seconds(Double(toEmit) / format.sampleRate))
            }
        }
        return format
    }

    func stop() async {
        feedTask?.cancel()
        feedTask = nil
    }
}

@Test @MainActor func 실제_ko_en_오디오로_자동_모드가_올바른_언어를_채택한다() async throws {
    guard ProcessInfo.processInfo.environment["LBC_DUAL_PROBE"] == "1" else { return }

    let dir = ProcessInfo.processInfo.environment["LBC_DUAL_PROBE_DIR"]
        ?? "/private/tmp/claude-501/-Users-an-yeonsu-Desktop-vivecoding-LiveBilingualCaptions/"
        + "10259627-8632-499d-ad9f-c8945adee815/scratchpad"

    // 버그 회귀(코드 리뷰): en.aiff는 세 문장이다. 전에는 프로브가 첫 final 하나만 보고
    // 멈춰서(위 참고) "영어는 너무 빨리 끊긴다"는 사용자 신고를 놓쳤다 — 이제는 언어뿐
    // 아니라 final 개수와 문장 전체를 정확히 고정한다.
    let order = ProcessInfo.processInfo.environment["LBC_DUAL_PROBE_ORDER"] ?? "ko,en"
    let all: [(file: String, expected: CaptionLanguage, expectedTexts: [String]?)] = [
        ("ko.aiff", .korean, nil),
        ("en.aiff", .english, ["Hello, everyone.", "Let us start today's meeting.", "The 1st item is the schedule."]),
    ]
    let cases = order.split(separator: ",").compactMap { key in all.first { $0.file.hasPrefix(key) } }

    for testCase in cases {
        let url = URL(fileURLWithPath: "\(dir)/\(testCase.file)")
        let pipeline = SpeechPipeline(engine: SystemSpeechEngine(), makeSource: { _ in FileAudioSource(url: url) })
        let controller = PipelineController(pipeline: pipeline)

        var finals: [TranscriptEvent] = []
        var stopped = false
        // 버그 회귀: 예전에는 **첫 final 하나**만 기다리고 곧바로 requestStop()을 불러서
        // 뒤이은 문장들을 잘라먹었다("영어는 너무 빨리 끊긴다" 버그의 원인 — 실제 인식이
        // 아니라 프로브 자체가 일찍 멈춘 것이었다). 이제는 "마지막 이벤트 이후로 한동안
        // 조용하다"를 기준으로 멈춘다 — 여러 문장짜리 발화가 전부 끝날 시간을 준다.
        var lastActivity = Date()
        controller.onEvent = { event in
            if case .transcript(let e) = event.kind {
                lastActivity = Date()
                if e.isFinal { finals.append(e) }
            }
        }
        controller.onState = { state in if state == .stopped { stopped = true } }

        let config = PipelineConfiguration(source: .microphone, language: .korean, sensitivity: .medium,
                                           secondaryLanguage: .english)
        controller.requestStart(configuration: config)

        // 모델 로딩 + 파일 재생 + 확정까지 넉넉히 기다리되 영원히 걸지 않는다. 프로세스의
        // 첫 인식은 두 언어 모델을 동시에 준비하느라(신경망 엔진 그래프 컴파일 등) 눈에
        // 띄게 느리다 — 실측으로 60초는 코드 첫 실행도 넉넉히 덮었다(그 뒤로는 13초대).
        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["LBC_DUAL_PROBE_TIMEOUT"] ?? "") ?? 60
        let quietSeconds = 3.0
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !finals.isEmpty, Date().timeIntervalSince(lastActivity) > quietSeconds { break }
        }

        controller.requestStop()
        while !stopped { try? await Task.sleep(for: .milliseconds(50)) }

        let adopted = finals.first?.sourceLanguage
        let text = finals.map(\.text).joined(separator: " / ")
        print("[DUAL_PROBE] \(testCase.file) → 채택된 언어: \(adopted?.displayName ?? "없음(타임아웃)") "
            + "/ 원문(\(finals.count)개): \(text)")
        #expect(adopted == testCase.expected)
        if let expectedTexts = testCase.expectedTexts {
            #expect(finals.count == expectedTexts.count)
            #expect(finals.map(\.text) == expectedTexts)
        }
    }
}

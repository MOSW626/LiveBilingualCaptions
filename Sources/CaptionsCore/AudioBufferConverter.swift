import AVFoundation

public enum AudioBufferConverterError: LocalizedError {
    case unsupportedFormat
    case allocationFailed
    case conversionFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "지원하지 않는 오디오 포맷 조합입니다"
        case .allocationFailed: "출력 버퍼를 할당하지 못했습니다"
        case .conversionFailed(let error): "오디오 변환 실패: \(error.localizedDescription)"
        }
    }
}

/// 캡처 포맷을 다른 포맷으로 변환한다.
///
/// SpeechAnalyzer는 입력을 리샘플링하지 않는다 — 마이크가 주는 포맷(예: 48kHz Float32
/// non-interleaved stereo)과 분석기가 원하는 포맷(예: 16kHz Int16 interleaved mono)이
/// 다르면 그대로 흘려보내는 것으로는 무음이나 잡음만 나온다. 이 타입은 그 사이의 다리다.
/// 포맷 *협상*(SpeechAnalyzer.bestAvailableAudioFormat)은 호출자(5B)의 몫이고,
/// 여기서는 주어진 두 포맷 사이를 정확히 변환하는 일만 한다 — Speech 프레임워크를
/// 알지 못한다.
///
/// 변환기 인스턴스는 재사용한다(버퍼마다 새로 만들지 않는다). 입력 포맷이 바뀌면
/// 호출자가 새 인스턴스를 만든다 — 이 타입 자신은 상태를 재구성하지 않는다.
public final class AudioBufferConverter {
    public let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioBufferConverterError.unsupportedFormat
        }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
    }

    /// 입력 버퍼를 출력 포맷으로 변환한다.
    ///
    /// 반환된 버퍼는 새로 할당된, 입력과 독립적으로 소유된 버퍼다 — 호출자가 캡처
    /// 콜백 안에서 불러도 콜백이 끝난 뒤(OS가 입력 버퍼를 재사용한 뒤)까지 안전하다.
    /// 한 번의 호출이 0개, 1개, 여러 개의 출력 버퍼를 낼 수 있다. 전부 반환한다.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        var results: [AVAudioPCMBuffer] = []

        // AVAudioConverter의 input block은 호출될 때마다 새 데이터를 요구한다.
        // 같은 입력 버퍼를 두 번 공급하면 스트림이 깨지므로, 한 번 공급한 뒤에는
        // .noDataNow로 응답해 컨버터가 지금까지 쌓인 출력을 배출하게 한다.
        // convert(to:error:withInputFrom:)는 이 클로저를 같은 스레드에서 동기적으로만
        // 호출한다(Apple 문서 기준) — 실제 동시성은 없으므로 안전하다.
        nonisolated(unsafe) var providedInput = false

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioBufferConverterError.allocationFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if providedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let conversionError {
                throw AudioBufferConverterError.conversionFailed(conversionError)
            }

            if outBuffer.frameLength > 0 {
                results.append(outBuffer)
            }

            switch status {
            case .haveData:
                continue // 더 배출할 것이 남아있을 수 있으니 새 버퍼로 계속 드레인한다.
            case .inputRanDry, .endOfStream:
                return results
            case .error:
                throw AudioBufferConverterError.conversionFailed(
                    conversionError ?? NSError(domain: "AudioBufferConverter", code: -1)
                )
            @unknown default:
                return results
            }
        }
    }
}

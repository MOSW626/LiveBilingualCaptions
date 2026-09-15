import AVFoundation
import Testing
@testable import CaptionsCore

// 실측: 이 머신에서 SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)은
// 16kHz / mono / Int16 / interleaved 를 요구한다. 마이크는 48kHz Float32 non-interleaved
// stereo를 준다. 따라서 변환은 샘플레이트·채널수뿐 아니라 샘플 타입(Float32->Int16)과
// 인터리빙까지 함께 바뀐다. 여기서는 실제 목표 포맷을 직접 구성해서 그 경로를 검증한다.
private let realWorldOutputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
)!

/// 표준(non-interleaved Float32) 포맷으로 순수 합성 사인파 버퍼를 만든다. 마이크가 주는
/// 입력 포맷은 항상 Float32이므로 입력 쪽 헬퍼는 이것 하나로 충분하다.
/// `startFrame`은 여러 청크에 걸쳐 위상을 이어 붙일 때 쓴다(연속성 테스트).
private func sineBuffer(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount,
    frequency: Double = 440,
    amplitude: Float = 0.5,
    startFrame: Int = 0
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let sampleRate = format.sampleRate
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frameCount) {
            let t = Double(startFrame + i) / sampleRate
            data[i] = amplitude * Float(sin(2 * Double.pi * frequency * t))
        }
    }
    return buffer
}

private func totalFrames(_ buffers: [AVAudioPCMBuffer]) -> Int {
    buffers.reduce(0) { $0 + Int($1.frameLength) }
}

/// 버퍼의 실제 commonFormat에 맞는 접근자(floatChannelData 또는 int16ChannelData)로
/// 한 채널의 샘플을 [-1, 1] 범위 Float로 읽어온다. force-unwrap으로 크래시하지 않도록
/// 두 접근자 모두 옵셔널로 다룬다.
private func samples(from buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return [] }
    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<frameLength).map { data[channel][$0] }
    case .pcmFormatInt16:
        guard let data = buffer.int16ChannelData else { return [] }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let base = buffer.format.isInterleaved ? 0 : channel
        let plane = buffer.format.isInterleaved ? data[0] : data[channel]
        return (0..<frameLength).map { Float(plane[base + $0 * stride]) / 32768.0 }
    default:
        return []
    }
}

// MARK: 1. 포맷 (Float32 stereo -> Int16 mono, 실측 목표 포맷)

@Test func 출력_포맷의_샘플레이트_채널수_샘플타입이_요청한_값과_같다() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let output = realWorldOutputFormat
    let converter = try AudioBufferConverter(from: input, to: output)

    let buffer = sineBuffer(format: input, frameCount: 4800)
    let results = try converter.convert(buffer)

    #expect(!results.isEmpty)
    for result in results {
        #expect(result.format.sampleRate == 16000)
        #expect(result.format.channelCount == 1)
        #expect(result.format.commonFormat == .pcmFormatInt16)
        #expect(result.format.isInterleaved == true)
    }
}

// MARK: 2. 프레임 수 (48kHz -> 16kHz, 정수배)

@Test func 일초_분량_48kHz_입력이_16kHz로_근사_변환된다() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let converter = try AudioBufferConverter(from: input, to: realWorldOutputFormat)

    let chunkFrames: AVAudioFrameCount = 4800 // 100ms 청크 * 10 = 1초
    var accumulated = 0
    for chunk in 0..<10 {
        let buffer = sineBuffer(format: input, frameCount: chunkFrames, startFrame: chunk * Int(chunkFrames))
        accumulated += totalFrames(try converter.convert(buffer))
    }

    let expected = 16000
    let tolerance = Int(Double(expected) * 0.01)
    #expect(abs(accumulated - expected) <= tolerance)
}

// MARK: 3. 정수배가 아닌 비율 (44.1kHz -> 16kHz)

@Test func 정수배가_아닌_비율에서도_포맷과_프레임수가_맞는다() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let converter = try AudioBufferConverter(from: input, to: realWorldOutputFormat)

    let chunkFrames: AVAudioFrameCount = 4410 // 100ms 청크 * 10 = 1초
    var accumulated = 0
    for chunk in 0..<10 {
        let buffer = sineBuffer(format: input, frameCount: chunkFrames, startFrame: chunk * Int(chunkFrames))
        let results = try converter.convert(buffer)
        for result in results {
            #expect(result.format.sampleRate == 16000)
            #expect(result.format.channelCount == 1)
            #expect(result.format.commonFormat == .pcmFormatInt16)
        }
        accumulated += totalFrames(results)
    }

    let expected = 16000
    let tolerance = Int(Double(expected) * 0.01)
    #expect(abs(accumulated - expected) <= tolerance)
}

// MARK: 4. 연속성 (실측 목표 포맷, Int16 경로)

@Test func 연속된_사인파를_나눠_넣어도_경계에서_불연속이_없다() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let converter = try AudioBufferConverter(from: input, to: realWorldOutputFormat)
    let amplitude: Float = 0.5

    let chunkFrames: AVAudioFrameCount = 4800
    var collected: [Float] = []
    for chunk in 0..<10 {
        let buffer = sineBuffer(
            format: input, frameCount: chunkFrames, amplitude: amplitude,
            startFrame: chunk * Int(chunkFrames)
        )
        for result in try converter.convert(buffer) {
            collected.append(contentsOf: samples(from: result))
        }
    }

    #expect(collected.count > 100)
    var maxDelta: Float = 0
    for i in 1..<collected.count {
        maxDelta = max(maxDelta, abs(collected[i] - collected[i - 1]))
    }
    // 440Hz, 16kHz, 진폭 0.5인 사인파의 이론적 최대 샘플간 변화량은 대략
    // 2π*440/16000*0.5 ≈ 0.086. 불연속(청크 경계 점프)이 있다면 이보다 훨씬 커진다.
    #expect(maxDelta < amplitude) // 진폭 자체보다는 훨씬 작아야 한다
}

// MARK: 5. 동일 포맷 (Float32 -> Float32, 같은 샘플레이트)

@Test func 입력과_출력_포맷이_같아도_프레임수가_맞는다() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let converter = try AudioBufferConverter(from: format, to: format)

    let buffer = sineBuffer(format: format, frameCount: 1600)
    let results = try converter.convert(buffer)

    #expect(totalFrames(results) == 1600)
}

// MARK: 6. 소유권 (Float32 -> Float32 동일 포맷 경로에서 검증 — 별도 버퍼를 반환하는 게
// 가장 유혹적으로 생략되기 쉬운 지점이 "입출력 포맷이 같을 때"이다)

@Test func 반환된_버퍼는_입력과_독립된_새_버퍼다() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let converter = try AudioBufferConverter(from: format, to: format)

    let buffer = sineBuffer(format: format, frameCount: 1600)
    let results = try converter.convert(buffer)
    #expect(results.count == 1)
    let result = results[0]

    #expect(result !== buffer)

    let before = samples(from: result)

    // 입력 버퍼를 변환 후 덮어쓴다 — 콜백이 끝나면 OS가 재사용하는 상황을 흉내낸다.
    let inputData = buffer.floatChannelData![0]
    for i in 0..<Int(buffer.frameLength) {
        inputData[i] = 999
    }

    let after = samples(from: result)
    #expect(before == after)
}

// MARK: 7. 빈 입력 (실측 목표 포맷 경로)

@Test func 빈_입력에서도_크래시하지_않는다() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let converter = try AudioBufferConverter(from: input, to: realWorldOutputFormat)

    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 0)!
    buffer.frameLength = 0

    let results = try converter.convert(buffer)
    #expect(totalFrames(results) == 0)
}

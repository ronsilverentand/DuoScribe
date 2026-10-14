import AVFoundation

/// Converts mono Float32 audio at any sample rate to the 16 kHz mono that Whisper expects.
/// Keeps its converter between calls so consecutive buffers join without clicks.
final class MonoResampler {
    static let targetSampleRate: Double = 16_000

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: MonoResampler.targetSampleRate,
        channels: 1,
        interleaved: false
    )!
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func resample(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        if sampleRate == Self.targetSampleRate { return samples }

        if inputFormat?.sampleRate != sampleRate {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else { return [] }
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }

        guard let converter = converter, let inputFormat = inputFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputData = input.floatChannelData
        else { return [] }

        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                inputData[0].update(from: base, count: samples.count)
            }
        }
        input.frameLength = AVAudioFrameCount(samples.count)

        let capacity = AVAudioFrameCount(Double(samples.count) * Self.targetSampleRate / sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, let outputData = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: outputData[0], count: Int(output.frameLength)))
    }
}

extension AVAudioPCMBuffer {
    /// The first channel as plain floats (for a microphone that is the channel we want).
    func firstChannelSamples() -> [Float] {
        let frames = Int(frameLength)
        guard frames > 0, let data = floatChannelData else { return [] }
        let step = self.stride
        let channel = data[0]
        if step == 1 {
            return Array(UnsafeBufferPointer(start: channel, count: frames))
        }
        var result = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            result[index] = channel[index * step]
        }
        return result
    }
}

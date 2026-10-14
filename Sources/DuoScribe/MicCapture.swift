import AVFoundation

/// Captures the default microphone and hands out 16 kHz mono samples.
final class MicCapture {
    /// Called on an audio thread.
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private var observer: NSObjectProtocol?
    private var running = false

    func start() throws {
        try startEngine()
        running = true
        // Fires when the input device changes (headset plugged in, AirPods connected, ...).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
        Log.write("mic: started")
    }

    func stop() {
        guard running else { return }
        running = false
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.write("mic: stopped")
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        Log.write("mic: input format \(format.sampleRate) Hz, \(format.channelCount) ch")

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            let samples = self.resampler.resample(buffer.firstChannelSamples(), sampleRate: buffer.format.sampleRate)
            if !samples.isEmpty {
                self.onSamples?(samples)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func restart() {
        guard running else { return }
        Log.write("mic: input device changed, restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
        } catch {
            Log.write("mic: restart failed: \(error.localizedDescription)")
        }
    }
}

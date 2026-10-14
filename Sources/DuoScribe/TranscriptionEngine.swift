import Foundation
import WhisperKit

struct TranscriptionOutput {
    let text: String
    let language: String
}

/// Owns the Whisper model and runs one transcription at a time.
/// Both streams share this one model, so their requests are queued.
actor TranscriptionEngine {
    /// Whisper large-v3-turbo, compressed. Handles Dutch and English well and runs
    /// faster than real time on Apple Silicon.
    static let modelName = "openai_whisper-large-v3-v20240930_626MB"

    private var whisper: WhisperKit?
    private var lastJob: Task<Void, Never>?

    /// Where the model is stored (about 630 MB).
    static var storageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DuoScribe", isDirectory: true)
    }

    /// Downloads the model on first use, then loads it.
    func load(onStatus: @escaping @Sendable (ModelStatus) -> Void) async throws {
        if whisper != nil {
            onStatus(.ready)
            return
        }

        let base = Self.storageFolder
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // The folder is only remembered after a complete download, so an interrupted
        // download is simply resumed next time.
        let defaultsKey = "modelFolder." + Self.modelName
        let folder: URL
        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           FileManager.default.fileExists(atPath: saved) {
            folder = URL(fileURLWithPath: saved)
        } else {
            onStatus(.downloading(0))
            Log.write("model: downloading \(Self.modelName)")
            folder = try await WhisperKit.download(
                variant: Self.modelName,
                downloadBase: base,
                progressCallback: { progress in
                    onStatus(.downloading(progress.fractionCompleted))
                }
            )
            UserDefaults.standard.set(folder.path, forKey: defaultsKey)
        }

        onStatus(.loading)
        Log.write("model: loading from \(folder.path)")
        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: base,
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
        Log.write("model: ready")
        onStatus(.ready)
    }

    /// Transcribes 16 kHz mono audio. Returns nil when the model is not loaded or decoding failed.
    /// - Parameter fallbackLanguage: used in auto mode when the model detects something other than Dutch or English.
    func transcribe(_ samples: [Float], mode: LanguageMode, fallbackLanguage: String) async -> TranscriptionOutput? {
        guard let whisper = whisper else { return nil }

        // Chain onto the previous request so only one runs at a time.
        let previous = lastJob
        let job = Task.detached(priority: .userInitiated) { () -> TranscriptionOutput? in
            _ = await previous?.value
            return await TranscriptionEngine.run(whisper, samples: samples, mode: mode, fallbackLanguage: fallbackLanguage)
        }
        lastJob = Task { _ = await job.value }
        return await job.value
    }

    private static func run(
        _ whisper: WhisperKit,
        samples: [Float],
        mode: LanguageMode,
        fallbackLanguage: String
    ) async -> TranscriptionOutput? {
        // Give very short clips a full second to work with.
        let minimumCount = WhisperKit.sampleRate
        let audio = samples.count >= minimumCount
            ? samples
            : samples + [Float](repeating: 0, count: minimumCount - samples.count)

        guard let first = await decode(whisper, audio: audio, language: mode.code, fallbackLanguage: fallbackLanguage) else {
            return nil
        }
        // Short or noisy clips are sometimes detected as a different language
        // (Afrikaans, German). Only Dutch and English are expected here.
        if mode == .auto, first.language != "nl", first.language != "en" {
            return await decode(whisper, audio: audio, language: fallbackLanguage, fallbackLanguage: fallbackLanguage)
        }
        return first
    }

    private static func decode(
        _ whisper: WhisperKit,
        audio: [Float],
        language: String?,
        fallbackLanguage: String
    ) async -> TranscriptionOutput? {
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            windowClipTime: 0
        )
        do {
            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ")
            let detected = results.first?.language ?? language ?? fallbackLanguage
            return TranscriptionOutput(text: TextTools.clean(text), language: detected)
        } catch {
            Log.write("transcription failed: \(error)")
            return nil
        }
    }
}

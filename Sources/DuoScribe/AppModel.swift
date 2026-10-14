import AVFoundation
import AppKit
import SwiftUI

/// Everything the window shows, and the wiring between capture, transcription and the transcript file.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var partials: [Speaker: String] = [:]
    @Published private(set) var levels: [Speaker: Float] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var modelStatus: ModelStatus = .idle
    @Published private(set) var transcriptURL: URL?
    @Published var errorMessage: String?
    @Published var echoFilter = true
    @Published var languageMode: LanguageMode = .auto {
        didSet {
            for pipeline in pipelines.values {
                pipeline.languageMode = languageMode
            }
        }
    }

    private let engine = TranscriptionEngine()
    private let microphone = MicCapture()
    private let systemAudio = SystemAudioCapture()
    private var pipelines: [Speaker: StreamPipeline] = [:]
    private var levelTimer: Timer?
    private var sessionStart = Date()

    var canToggle: Bool {
        !isBusy && (isRunning || modelStatus == .ready)
    }

    // MARK: Model

    func loadModel() {
        switch modelStatus {
        case .idle, .failed: break
        default: return
        }
        modelStatus = .loading
        Task {
            do {
                try await engine.load { [weak self] status in
                    Task { @MainActor in
                        guard let self = self, self.modelStatus != .ready else { return }
                        self.modelStatus = status
                    }
                }
                modelStatus = .ready
            } catch {
                Log.write("model: failed: \(error)")
                modelStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Start / stop

    func toggle() {
        Task {
            if isRunning {
                await stop()
            } else {
                await start()
            }
        }
    }

    private func start() async {
        guard !isRunning, !isBusy, modelStatus == .ready else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Microphone access is off. Allow DuoScribe under System Settings > Privacy & Security > Microphone."
            return
        }

        lines = []
        partials = [:]
        sessionStart = Date()
        transcriptURL = TranscriptStore.newFileURL(for: sessionStart)

        let me = makePipeline(for: .me, minimumLevel: 0.004)
        let them = makePipeline(for: .them, minimumLevel: 0.002)
        microphone.onSamples = { [segmenter = me.segmenter] samples in
            segmenter.append(samples)
        }
        systemAudio.onSamples = { [segmenter = them.segmenter] samples in
            segmenter.append(samples)
        }

        var problems: [String] = []
        var started = 0
        do {
            try microphone.start()
            started += 1
        } catch {
            problems.append("Microphone: \(error.localizedDescription)")
        }
        do {
            try systemAudio.start()
            started += 1
        } catch {
            problems.append("System audio: \(error.localizedDescription)")
        }
        if !problems.isEmpty {
            Log.write("start: " + problems.joined(separator: " | "))
            errorMessage = problems.joined(separator: " ")
        }
        guard started > 0 else { return }

        pipelines = [.me: me, .them: them]
        me.start()
        them.start()
        startLevelTimer()
        isRunning = true
        save()
    }

    private func stop() async {
        guard isRunning, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        microphone.stop()
        systemAudio.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        levels = [:]

        // Let both streams finish transcribing what was already said.
        for pipeline in pipelines.values {
            await pipeline.finish()
        }
        pipelines = [:]
        partials = [:]
        isRunning = false
        save()
    }

    private func makePipeline(for speaker: Speaker, minimumLevel: Float) -> StreamPipeline {
        let segmenter = SpeechSegmenter(settings: .init(minimumLevel: minimumLevel))
        let pipeline = StreamPipeline(speaker: speaker, segmenter: segmenter, engine: engine, languageMode: languageMode)
        pipeline.onPartial = { [weak self] text in
            self?.partials[speaker] = text.isEmpty ? nil : text
        }
        pipeline.onFinal = { [weak self] segment, text in
            self?.addLine(TranscriptLine(speaker: speaker, start: segment.start, end: segment.end, text: text))
        }
        return pipeline
    }

    // MARK: Transcript

    private func addLine(_ line: TranscriptLine) {
        if echoFilter {
            switch line.speaker {
            case .me:
                if isEcho(line) {
                    Log.write("echo filter: dropped a microphone line that repeats the speakers")
                    return
                }
            case .them:
                // The matching microphone line may already be there; check the recent ones again.
                let recent = line.start.addingTimeInterval(-30)
                lines.append(line)
                let echoes = Set(lines.filter { $0.speaker == .me && $0.end >= recent && isEcho($0) }.map { $0.id })
                if !echoes.isEmpty {
                    lines = lines.filter { !echoes.contains($0.id) }
                    Log.write("echo filter: removed \(echoes.count) microphone line(s) that repeat the speakers")
                }
                lines.sort { $0.start < $1.start }
                save()
                return
            }
        }
        lines.append(line)
        lines.sort { $0.start < $1.start }
        save()
    }

    /// True when a microphone line mostly repeats what the other side said at the same moment,
    /// which happens when the speakers are audible to the microphone.
    private func isEcho(_ candidate: TranscriptLine) -> Bool {
        let slack: TimeInterval = 3
        let from = candidate.start.addingTimeInterval(-slack)
        let to = candidate.end.addingTimeInterval(slack)
        let reference = lines
            .filter { $0.speaker == .them && $0.start <= to && $0.end >= from }
            .map { $0.text }
            .joined(separator: " ")
        return TextTools.isEcho(candidate: candidate.text, reference: reference)
    }

    private func save() {
        guard let url = transcriptURL else { return }
        do {
            try TranscriptStore.write(lines: lines, started: sessionStart, to: url)
        } catch {
            Log.write("transcript: could not save: \(error)")
            errorMessage = "Could not save the transcript: \(error.localizedDescription)"
        }
    }

    func revealTranscript() {
        if let url = transcriptURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: TranscriptStore.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(TranscriptStore.folder)
        }
    }

    // MARK: Level meters

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLevels()
            }
        }
    }

    private func refreshLevels() {
        guard isRunning else { return }
        var updated: [Speaker: Float] = [:]
        for (speaker, pipeline) in pipelines {
            updated[speaker] = pipeline.segmenter.level
        }
        levels = updated
    }
}

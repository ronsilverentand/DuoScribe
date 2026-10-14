import Foundation

/// Turns one audio stream (microphone or system audio) into text:
/// previews while someone is talking, a final line once they pause.
@MainActor
final class StreamPipeline {
    let speaker: Speaker
    let segmenter: SpeechSegmenter
    var languageMode: LanguageMode

    /// Preview text for the utterance in progress; an empty string clears it.
    var onPartial: ((String) -> Void)?
    /// A finished utterance and its text.
    var onFinal: ((SpeechSegment, String) -> Void)?

    private let engine: TranscriptionEngine
    private var loop: Task<Void, Never>?
    private var finishing = false
    private var partialShown = false
    private var lastLanguage = "nl"

    init(speaker: Speaker, segmenter: SpeechSegmenter, engine: TranscriptionEngine, languageMode: LanguageMode) {
        self.speaker = speaker
        self.segmenter = segmenter
        self.engine = engine
        self.languageMode = languageMode
    }

    func start() {
        finishing = false
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    /// Transcribes whatever is still waiting, then ends the loop.
    func finish() async {
        segmenter.flush()
        finishing = true
        await loop?.value
        loop = nil
    }

    private func run() async {
        let oneSecond = 16_000
        var previewID = -1
        var previewCount = 0

        while !Task.isCancelled {
            // Finished utterances come first.
            if let segment = segmenter.popFinished() {
                let output = await engine.transcribe(segment.samples, mode: languageMode, fallbackLanguage: lastLanguage)
                showPartial("")
                if let output = output, !output.text.isEmpty {
                    remember(language: output.language)
                    onFinal?(segment, output.text)
                }
                continue
            }

            // Otherwise refresh the preview about once per second of new speech.
            if let state = segmenter.partialState {
                let alreadyPreviewed = state.id == previewID ? previewCount : 0
                if state.sampleCount >= oneSecond, state.sampleCount - alreadyPreviewed >= oneSecond,
                   let partial = segmenter.currentPartial() {
                    previewID = partial.id
                    previewCount = partial.samples.count
                    let output = await engine.transcribe(partial.samples, mode: languageMode, fallbackLanguage: lastLanguage)
                    // Skip it if that utterance ended in the meantime; its final text is on the way.
                    if let output = output, segmenter.partialState?.id == partial.id {
                        showPartial(output.text)
                    }
                    continue
                }
            } else if partialShown {
                showPartial("")
            }

            if finishing { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        showPartial("")
    }

    private func showPartial(_ text: String) {
        if text.isEmpty && !partialShown { return }
        partialShown = !text.isEmpty
        onPartial?(text)
    }

    private func remember(language: String) {
        if language == "nl" || language == "en" {
            lastLanguage = language
        }
    }
}

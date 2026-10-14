# Status and roadmap

## Status (October 2026)

- Builds with `./build.sh` on macOS 27.2, Swift 6.4, WhisperKit 1.1.0.
- One compiler warning: `AppModel.swift:46`, `[weak self]` inside a `Task` that already captures `self`
  strongly (ImplicitStrongCapture). Harmless; fix by adding `[weak self]` to the outer `Task` and unwrapping.
- Runtime behaviour has not been checked against the manual test list in `docs/DEVELOPMENT.md` yet.

## Known limitations and open questions

- **System audio with headsets.** `tapOnly` mode is preferred; whether it delivers callbacks on every setup, and
  whether the `withOutputDevice` fallback picks the right buffer for devices with both input and output (USB
  headsets, AirPods), is untested.
- **Echo without headphones** is only filtered at text level. Partial previews may briefly show echoed text under
  Me, and short echoes (one word) are not filtered.
- **Language detection** on very short utterances can be wrong; the fallback only guards against languages other
  than Dutch and English, not against Dutch detected as English.
- **Permissions** reset on every rebuild because of ad-hoc signing.
- **Overlapping speech** on the same stream is one text; there is no speaker separation within Them (several
  remote participants are all "Them").
- The noise floor and level thresholds are first guesses and not tuned on real recordings.

## Ideas

- Unit tests for the pure logic (`SpeechSegmenter`, `TextTools`, `TranscriptStore.render`) with a test target
  that feeds synthetic audio.
- Acoustic echo cancellation as an option (voice-processing IO).
- Speaker labels within Them (WhisperKit's SpeakerKit does diarization).
- Settings window: transcript folder, model size, thresholds.
- Export to Markdown or SRT; copy transcript to clipboard.
- Always-on-top compact caption window.
- Developer ID signing and notarization so permissions survive updates.
- Automatic summary of a finished transcript.

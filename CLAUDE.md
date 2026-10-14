# DuoScribe: notes for coding agents

A native macOS app (SwiftUI, Swift Package Manager) that live-transcribes the microphone ("Me")
and the Mac's audio output ("Them") in Dutch and English, shows both side by side, and saves one
combined transcript. Transcription runs locally with WhisperKit.

Read `docs/ARCHITECTURE.md` before changing anything in the audio or transcription path.

## Build and run

```sh
./build.sh          # swift build -c release, assembles and ad-hoc signs build/DuoScribe.app, output also in build.log
./build.sh run      # same, then opens the app
swift build         # quick compile check only (no app bundle)
```

- Builds only on macOS (AppKit, Core Audio, AVFoundation). A Linux sandbox cannot compile this.
- Always run the app through `build/DuoScribe.app`. The bare binary (or running the scheme from Xcode) has no
  Info.plist, so the microphone and system audio permissions do not work.
- Runtime log: `~/Library/Logs/DuoScribe/DuoScribe.log` (`tail -f` it while testing).
- There are no automated tests yet. Verify changes by building and, for audio changes, by a manual run
  (see "Manual test" in `docs/DEVELOPMENT.md`).

## Layout

```
Package.swift                 one executable target, depends on WhisperKit (pinned exact 1.1.0)
Resources/Info.plist          bundle id nl.ingbersoft.DuoScribe, permission strings
build.sh                      build + bundle + codesign
Sources/DuoScribe/
  DuoScribeApp.swift          @main, window
  ContentView.swift           UI: controls, two TranscriptColumns, footer, LevelMeter
  AppModel.swift              @MainActor state, start/stop, echo filter, saving
  StreamPipeline.swift        per stream: preview + final transcription loop
  SpeechSegmenter.swift       energy VAD, cuts audio into utterances
  TranscriptionEngine.swift   actor around WhisperKit, model download/load, serial queue
  MicCapture.swift            AVAudioEngine microphone tap
  SystemAudioCapture.swift    Core Audio process tap + aggregate device
  AudioUtilities.swift        MonoResampler (any rate -> 16 kHz mono)
  TextTools.swift             output clean-up, hallucination filter, echo similarity
  TranscriptStore.swift       transcript file format and location
  Models.swift                Speaker, TranscriptLine, LanguageMode, ModelStatus, CaptureError
  Log.swift                   file logger
docs/                         architecture, development guide, status and roadmap
```

## Rules that keep it working

- **One transcription at a time.** WhisperKit is not safe to call concurrently. Always go through
  `TranscriptionEngine.transcribe`, which chains requests. Never hold a `WhisperKit` reference elsewhere.
- **Threading.** Capture callbacks run on audio threads and only call `SpeechSegmenter.append` (guarded by an
  `NSLock`). Everything else that touches UI state is `@MainActor` (`AppModel`, `StreamPipeline`). Keep heavy work
  out of the audio callbacks.
- **Exclusive access.** Do not mutate `AppModel.lines` inside a closure that also reads `lines`
  (for example `lines.removeAll { isEcho($0) }`); that crashes at runtime. Compute first, then assign.
- **Swift 5 language mode on purpose** (`swiftLanguageVersions: [.v5]`). WhisperKit types are not `Sendable`;
  Swift 6 mode would turn many warnings into errors. Don't switch without a plan.
- **Audio format contract.** Everything after the capture classes is 16 kHz mono `[Float]`. New sources must
  resample with `MonoResampler` before calling `append`.
- **Permissions fail silently.** Core Audio returns `noErr` even when system audio recording is denied and then
  delivers silence. A flat level meter is the symptom; don't chase it as a code bug first.
- **Ad-hoc signing.** Every rebuild changes the signature, so macOS may ask for permissions again.
- **Dependency.** WhisperKit lives in `argmaxinc/argmax-oss-swift` and is pinned with `exact:`. Before upgrading,
  read its source for API changes (`DecodingOptions` init order, `WhisperKitConfig`, `WhisperKit.download`).
- **Privacy.** Audio and text never leave the machine. Don't add network calls beyond the one-time model download.

## Conventions

- Plain Swift, no third-party dependencies besides WhisperKit.
- Short doc comments on types and on non-obvious decisions; explain *why*, not *what*.
- User-facing text in English. Keep the UI native (system colors, SF Symbols, no custom theming).
- Log noteworthy runtime events with `Log.write("area: message")`.
- Tunable numbers live in one place each (see the tuning table in `docs/ARCHITECTURE.md`); update that table
  when you change one.

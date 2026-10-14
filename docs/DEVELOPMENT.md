# Development

## Requirements

- Apple Silicon Mac, macOS 14.2 or later (developed on macOS 27.2)
- Xcode or the command line tools with Swift 5.10 or later (built with Swift 6.4)
- About 2 GB free disk space (build cache plus the speech model)

## Building

```sh
./build.sh         # build and assemble build/DuoScribe.app
./build.sh run     # build and open
swift build        # compile check only
```

`build.sh` runs `swift build -c release`, copies the binary, `Resources/Info.plist` and any resource bundles
into `build/DuoScribe.app`, signs it ad hoc, and writes everything it printed to `build.log`.

### Editing in Xcode

`open Package.swift` opens the package in Xcode for editing, code completion and compiling. Run the app with
`./build.sh run`, not from Xcode: the scheme launches the bare binary without the Info.plist, so the permission
prompts and system audio capture don't work.

## Debugging

- Log: `tail -f ~/Library/Logs/DuoScribe/DuoScribe.log`. It records capture start/stop, formats, device changes,
  model download and load, echo filter decisions and errors.
- A flat level meter means no audio is arriving. Check permissions before the code.
- Reset permissions (useful after rebuilding):

  ```sh
  tccutil reset Microphone nl.ingbersoft.DuoScribe
  tccutil reset AudioCapture nl.ingbersoft.DuoScribe
  tccutil reset SystemPolicyDocumentsFolder nl.ingbersoft.DuoScribe
  ```

- Force a fresh model download: quit the app, delete `~/Library/Application Support/DuoScribe`, and run
  `defaults delete nl.ingbersoft.DuoScribe`.

## Manual test

There are no automated tests yet. After changing audio or transcription code, go through this list:

1. Fresh start: the model status goes from loading to Ready.
2. Start: the microphone and system audio prompts appear (first time or after a permission reset).
3. Speak Dutch, then English: the Me column shows previews, then final lines in the right language.
4. Play a Dutch and an English video: same for the Them column.
5. With speakers (no headphones) and the echo filter on: the video's speech does not show up under Me.
6. Switch output device while running (plug in headphones, connect AirPods): Them keeps working; the log shows a
   restart.
7. Stop: the last sentence still appears; the file in `~/Documents/DuoScribe` matches the screen, in time order.
8. Silence or music only for a minute: no invented text.

## Making changes

- Changing a tunable value: also update the tuning table in `docs/ARCHITECTURE.md`.
- Adding an audio source: produce 16 kHz mono `[Float]` with `MonoResampler`, feed a new `SpeechSegmenter`, add a
  `Speaker` case and a `StreamPipeline` in `AppModel.start`.
- Changing the transcript format: `TranscriptStore.render` is the only place that formats it.
- Upgrading WhisperKit: change the `exact:` version in `Package.swift`, run `swift package update`, read the release
  notes and the source of `DecodingOptions`, `WhisperKitConfig` and `WhisperKit.transcribe`, then build.

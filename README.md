# DuoScribe

Live transcription of both sides of a conversation on a Mac, in Dutch and English.

- **Me**: what the microphone hears.
- **Them**: everything the Mac plays through its speakers or headphones.

Both appear side by side while you talk and are saved as one combined transcript:

```
[12:30:05] Me: Hallo, hoor je mij?
[12:30:09] Them: Ja, ik hoor je goed.
```

Transcription runs on the Mac itself (Whisper large-v3-turbo through
[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)). No audio or text leaves the machine.

## Requirements

- Apple Silicon Mac with macOS 14.2 or later
- Xcode or the command line tools with Swift 5.10 or later

## Build and run

```sh
./build.sh run
```

This builds `build/DuoScribe.app` and opens it. The build output is also written to `build.log`.

The build fetches WhisperKit from GitHub. On first launch the app downloads the speech model (about 630 MB, from
Hugging Face) into `~/Library/Application Support/DuoScribe` and prepares it for this Mac, which takes a few
minutes once. After that it starts in seconds and works offline.

## Permissions

macOS asks for these the first time you press Start:

1. **Microphone**, for the Me column.
2. **System Audio Recording**, for the Them column.
3. **Documents folder**, to save the transcript.

If a column stays empty and its level meter stays flat, check System Settings > Privacy & Security >
Microphone, and > Screen & System Audio Recording > System Audio Recording Only. Rebuilding can make macOS ask
again, because the app is signed ad hoc.

## Using it

- **Start / Stop** (Command-Return). Each Start begins a new transcript file in `~/Documents/DuoScribe`.
- **Auto NL/EN** detects the language per sentence. Pick Nederlands or English if it guesses wrong.
- **Filter speaker echo**: without headphones the microphone also hears the other side. With this on, microphone
  lines that repeat what was playing at that moment are dropped. Headphones give the cleanest split.
- Grey italic text is a preview of the sentence being spoken; it becomes final at the next pause.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): data flow, threading, components, tuning values, design decisions
- [Development](docs/DEVELOPMENT.md): building, debugging, permissions, manual test list
- [Status and roadmap](docs/STATUS.md): what works, known limitations, ideas
- [CLAUDE.md](CLAUDE.md): rules and orientation for coding agents

## Privacy

Transcribing a call records the other participants. Tell them.

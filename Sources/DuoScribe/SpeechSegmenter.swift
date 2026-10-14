import Foundation

/// A finished stretch of speech, ready to be transcribed.
struct SpeechSegment {
    let samples: [Float]
    let start: Date
    let end: Date
}

/// A snapshot of speech that is still going on.
struct PartialSegment {
    let id: Int
    let samples: [Float]
}

/// Cuts a continuous 16 kHz audio stream into utterances.
///
/// Whisper transcribes chunks rather than a stream, so the audio has to be cut somewhere.
/// Cutting at pauses keeps words whole; skipping silence keeps Whisper from inventing text.
/// Audio arrives on an audio thread, the transcriber reads from another one, hence the lock.
final class SpeechSegmenter {
    struct Settings {
        /// Quietest level (RMS, 0...1) that can count as speech.
        var minimumLevel: Float
        /// Pause that ends an utterance.
        var endSilence: Double = 0.7
        /// Shorter pause that is accepted once an utterance gets long.
        var relaxedEndSilence: Double = 0.3
        var relaxAfter: Double = 12
        /// Hard limit; Whisper's window is 30 s.
        var maximumLength: Double = 24
        /// Audio kept from just before speech starts, so the first syllable is not clipped.
        var preRoll: Double = 0.3
        /// Shorter bursts (clicks, a cough) are thrown away.
        var minimumSpeech: Double = 0.25
    }

    private static let sampleRate = 16_000
    private static let frameSize = 320 // 20 ms

    private let settings: Settings
    private let lock = NSLock()

    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var current: [Float] = []
    private var finished: [SpeechSegment] = []

    private var inSpeech = false
    private var currentID = 0
    private var currentStart = Date()
    private var voicedFrames = 0
    private var silenceFrames = 0
    private var noiseFloor: Float = 0.0005
    private var recentLevel: Float = 0

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Feeding audio

    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.frameSize {
            process(frame: pending[offset..<(offset + Self.frameSize)])
            offset += Self.frameSize
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
    }

    private func process(frame: ArraySlice<Float>) {
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        let level = (sum / Float(frame.count)).squareRoot()
        recentLevel = max(level, recentLevel * 0.85)

        let voiced = level > max(settings.minimumLevel, noiseFloor * 3)
        if voiced {
            // Creep upwards, so a new steady noise (a fan) stops counting as speech after a while.
            noiseFloor = min(noiseFloor * 1.0005, 0.05)
        } else {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
        }

        if inSpeech {
            current.append(contentsOf: frame)
            if voiced {
                voicedFrames += 1
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }
            let length = Self.seconds(current.count)
            let silence = Self.seconds(silenceFrames * Self.frameSize)
            let neededSilence = length >= settings.relaxAfter ? settings.relaxedEndSilence : settings.endSilence
            if silence >= neededSilence {
                finishCurrent(cutMidSpeech: false)
            } else if length >= settings.maximumLength {
                finishCurrent(cutMidSpeech: true)
            }
        } else if voiced {
            inSpeech = true
            currentID += 1
            current = preRoll
            current.append(contentsOf: frame)
            preRoll.removeAll(keepingCapacity: true)
            currentStart = Date().addingTimeInterval(-Self.seconds(current.count))
            voicedFrames = 1
            silenceFrames = 0
        } else {
            preRoll.append(contentsOf: frame)
            let limit = Int(settings.preRoll * Double(Self.sampleRate))
            if preRoll.count > limit {
                preRoll.removeFirst(preRoll.count - limit)
            }
        }
    }

    private func finishCurrent(cutMidSpeech: Bool) {
        let voicedSeconds = Self.seconds(voicedFrames * Self.frameSize)
        if voicedSeconds >= settings.minimumSpeech {
            // Keep a little of the trailing pause, drop the rest.
            let trailing = silenceFrames * Self.frameSize
            let kept = min(trailing, Self.sampleRate / 5)
            let samples = Array(current.prefix(current.count - (trailing - kept)))
            let end = currentStart.addingTimeInterval(Self.seconds(samples.count))
            finished.append(SpeechSegment(samples: samples, start: currentStart, end: end))
        }

        if cutMidSpeech {
            preRoll.removeAll(keepingCapacity: true)
        } else {
            preRoll = Array(current.suffix(Int(settings.preRoll * Double(Self.sampleRate))))
        }
        current.removeAll(keepingCapacity: true)
        inSpeech = false
        voicedFrames = 0
        silenceFrames = 0
    }

    private static func seconds(_ sampleCount: Int) -> Double {
        Double(sampleCount) / Double(sampleRate)
    }

    // MARK: Reading results

    /// The oldest finished utterance, if there is one.
    func popFinished() -> SpeechSegment? {
        lock.lock()
        defer { lock.unlock() }
        return finished.isEmpty ? nil : finished.removeFirst()
    }

    /// Identity and length of the utterance in progress, without copying its audio.
    var partialState: (id: Int, sampleCount: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return inSpeech ? (id: currentID, sampleCount: current.count) : nil
    }

    /// A copy of the utterance in progress, for a preview transcription.
    func currentPartial() -> PartialSegment? {
        lock.lock()
        defer { lock.unlock() }
        return inSpeech ? PartialSegment(id: currentID, samples: current) : nil
    }

    /// Ends the utterance in progress (used when stopping).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if inSpeech {
            finishCurrent(cutMidSpeech: true)
        }
        pending.removeAll()
        preRoll.removeAll()
        recentLevel = 0
    }

    /// Recent loudness (RMS, 0...1), for the level meter.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return recentLevel
    }
}

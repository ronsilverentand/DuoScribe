import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (speakers or headphones) through a Core Audio tap
/// and hands out 16 kHz mono samples. Needs macOS 14.2 and the "System Audio Recording" permission.
///
/// A tap cannot be read directly: it has to sit inside an aggregate device, which is then
/// read like a microphone.
final class SystemAudioCapture {
    /// Called on a background queue.
    var onSamples: (([Float]) -> Void)?

    private enum Mode {
        /// Aggregate device that contains only the tap.
        case tapOnly
        /// Aggregate device that also contains the current output device, which then drives the clock.
        case withOutputDevice
    }

    private static let unknownID = AudioObjectID(kAudioObjectUnknown)
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(label: "duoscribe.system-audio", qos: .userInitiated)
    private let resampler = MonoResampler()

    private var tapID = SystemAudioCapture.unknownID
    private var aggregateID = SystemAudioCapture.unknownID
    private var ioProcID: AudioDeviceIOProcID?
    private var mode = Mode.tapOnly
    private var running = false
    private var generation = 0
    private var callbackCount = 0 // only touched on `queue`
    private var deviceListener: AudioObjectPropertyListenerBlock?

    // MARK: Start / stop (call on the main thread)

    func start() throws {
        try open(mode: .tapOnly)
        running = true
        installDeviceListener()
        scheduleWatchdog()
    }

    func stop() {
        guard running else { return }
        running = false
        removeDeviceListener()
        close()
        Log.write("system audio: stopped")
    }

    // MARK: Tap and aggregate device

    private func open(mode: Mode) throws {
        self.mode = mode
        generation += 1
        queue.sync { callbackCount = 0 }

        do {
            // 1. A tap on the mixed output of every process, mixed down to mono.
            let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            let tapUID = UUID()
            tapDescription.uuid = tapUID
            tapDescription.name = "DuoScribe system audio"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var newTapID = Self.unknownID
            var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
            guard status == noErr else {
                throw CaptureError.coreAudio("creating the system audio tap", status)
            }
            tapID = newTapID

            // 2. The tap's audio format.
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
            guard status == noErr else {
                throw CaptureError.coreAudio("reading the tap format", status)
            }
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32,
                  format.mSampleRate > 0
            else {
                throw CaptureError.unsupportedFormat
            }
            let sampleRate = format.mSampleRate

            // 3. A private aggregate device that contains the tap.
            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: tapUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]
            var description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "DuoScribe capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [tapEntry],
            ]
            if mode == .withOutputDevice {
                let outputUID = try Self.defaultOutputDeviceUID()
                let subDevice: [String: Any] = [kAudioSubDeviceUIDKey: outputUID]
                description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
                description[kAudioAggregateDeviceSubDeviceListKey] = [subDevice]
            }

            var newAggregateID = Self.unknownID
            status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
            guard status == noErr else {
                throw CaptureError.coreAudio("creating the capture device", status)
            }
            aggregateID = newAggregateID

            // 4. Read from it.
            var newProcID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
                self?.handle(inputData, sampleRate: sampleRate)
            }
            guard status == noErr, let procID = newProcID else {
                throw CaptureError.coreAudio("installing the audio callback", status)
            }
            ioProcID = procID

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else {
                throw CaptureError.coreAudio("starting system audio capture", status)
            }
            Log.write("system audio: started (\(mode), \(sampleRate) Hz, \(format.mChannelsPerFrame) ch)")
        } catch {
            close()
            throw error
        }
    }

    private func close() {
        if aggregateID != Self.unknownID {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = Self.unknownID

        if tapID != Self.unknownID {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = Self.unknownID
    }

    // MARK: Audio callback (runs on `queue`)

    private func handle(_ inputData: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        callbackCount += 1

        // The tap's stream comes after any streams of real devices in the aggregate.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let buffer = buffers.last, let data = buffer.mData else { return }

        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
        guard frames > 0 else { return }

        let source = data.assumingMemoryBound(to: Float32.self)
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            for frame in 0..<frames {
                mono[frame] = source[frame]
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += source[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        let samples = resampler.resample(mono, sampleRate: sampleRate)
        if !samples.isEmpty {
            onSamples?(samples)
        }
    }

    // MARK: Recovery

    /// If the tap-only device never calls back, fall back to clocking it from the output device.
    private func scheduleWatchdog() {
        let expectedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.running, self.generation == expectedGeneration, self.mode == .tapOnly else { return }
            let count = self.queue.sync { self.callbackCount }
            guard count == 0 else { return }
            Log.write("system audio: no audio callbacks yet, retrying with the output device as clock")
            self.close()
            do {
                try self.open(mode: .withOutputDevice)
            } catch {
                Log.write("system audio: fallback failed: \(error.localizedDescription)")
            }
        }
    }

    /// Rebuilds the tap when the output device changes (headphones plugged in or removed).
    private func installDeviceListener() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartAfterDeviceChange()
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, DispatchQueue.main, listener)
    }

    private func removeDeviceListener() {
        guard let listener = deviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, DispatchQueue.main, listener)
        deviceListener = nil
    }

    private func restartAfterDeviceChange() {
        guard running else { return }
        Log.write("system audio: output device changed, restarting")
        let previousMode = mode
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.running, self.aggregateID == Self.unknownID else { return }
            do {
                try self.open(mode: previousMode)
                self.scheduleWatchdog()
            } catch {
                Log.write("system audio: restart failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        var status = AudioObjectGetPropertyData(systemObject, &deviceAddress, 0, nil, &deviceSize, &deviceID)
        guard status == noErr else {
            throw CaptureError.coreAudio("finding the output device", status)
        }

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = address(kAudioDevicePropertyDeviceUID)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw CaptureError.coreAudio("reading the output device name", status)
        }
        return value as String
    }
}

import AVFoundation
import CoreAudio

/// Everything other apps are playing, which during a meeting is the call, taken straight
/// from the system instead of through the microphone. This process's own output is left
/// out, so Stand's voice is never in it.
///
/// Why it exists: macOS voice processing removes all of the Mac's output from the
/// microphone signal, the call included. That keeps Stand from hearing itself, and also
/// makes it deaf to the call. So the call is heard here and the microphone is left for
/// the person in the room. (`stand --probe otherapp` shows the problem and the fix.)
///
/// Needs the "System Audio Recording" permission, asked for on first use.
public final class SystemAudioTap {
    /// Mono 16-bit little-endian PCM at 16 kHz. Called on a background queue.
    public var onAudio: ((Data) -> Void)?
    public private(set) var formatDescription = ""

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "stand.system-audio", qos: .userInitiated)
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GeminiLive.microphoneRate, channels: 1, interleaved: true)!
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var channels = 2
    private var interleaved = false
    private var reportedLayout = false
    private let peakLock = NSLock()
    private var rawPeakSinceRead: Float = 0

    /// The loudest sample the tap itself delivered since the last call, where 1.0 is full
    /// scale, before any conversion. For telling a quiet tap from a faulty conversion.
    public func takeRawPeak() -> Float {
        peakLock.withLock {
            defer { rawPeakSinceRead = 0 }
            return rawPeakSinceRead
        }
    }

    public init() {}

    /// Start after this process has begun playing or recording audio, so that the system
    /// knows it as an audio process and can leave it out of the tap.
    public func start() throws {
        // 1. A tap on everything the system plays, minus this process.
        let ownProcess = try Self.audioProcessObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Stand"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

        var format = AudioStreamBasicDescription()
        try Self.read(tapID, kAudioTapPropertyFormat, into: &format)
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw StandError("The system audio tap has a format this app does not handle (\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags)).")
        }
        channels = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        formatDescription = "\(Int(format.mSampleRate)) Hz, \(channels) channel(s)\(interleaved ? "" : ", not interleaved")\(ownProcess == nil ? ", own output NOT excluded" : "")"
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, channels: 1, interleaved: false)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: sendFormat)

        // 2. A private aggregate device that carries the tap, so it can be read like an input.
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &outputDevice)
        var outputUID: CFString = "" as CFString
        try Self.read(outputDevice, kAudioDevicePropertyDeviceUID, into: &outputUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stand system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Creating the device that carries the tap")

        // 3. Read it.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.capture(input)
        }, "Attaching to the system audio tap")
        try check(AudioDeviceStart(deviceID, procID), "Starting the system audio tap")
    }

    public func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Mixes the tap's channels down to one, converts to 16 kHz 16-bit, and hands it on.
    private func capture(_ list: UnsafePointer<AudioBufferList>) {
        guard let converter, let monoFormat else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // The device hands over more than the tap when it has inputs of its own, and those
        // come first. With voice processing on, the MacBook's speakers gain a six-channel
        // input, so the tap is the second buffer, not the first. The tap is always last:
        // one buffer holding every channel, or one buffer per channel.
        let tapBuffers = Array(buffers.suffix(interleaved ? 1 : channels))
        guard let first = tapBuffers.first, let firstData = first.mData,
              tapBuffers.count == (interleaved ? 1 : channels),
              Int(first.mNumberChannels) == (interleaved ? channels : 1) else {
            if !reportedLayout {
                reportedLayout = true
                let layout = buffers.map { "\($0.mNumberChannels) ch" }.joined(separator: ", ")
                FileHandle.standardError.write(Data("The system audio tap's buffers are not laid out as expected (\(layout)); the call will not be heard.\n".utf8))
            }
            return
        }
        let frames = interleaved
            ? Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            : Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        if interleaved {
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                out[i] = sum / Float(channels)
            }
        } else {
            for i in 0..<frames { out[i] = 0 }
            var used = 0
            for buffer in tapBuffers {
                guard let data = buffer.mData, Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { out[i] += samples[i] }
                used += 1
            }
            if used > 1 { for i in 0..<frames { out[i] /= Float(used) } }
        }

        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(out[i])) }
        peakLock.withLock { rawPeakSinceRead = max(rawPeakSinceRead, peak) }

        let capacity = AVAudioFrameCount(Double(frames) * sendFormat.sampleRate / monoFormat.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
        onAudio?(Data(bytes: samples, count: Int(converted.frameLength) * 2))
    }

    // MARK: Core Audio plumbing

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw StandError("\(what) failed (Core Audio error \(status)).") }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw StandError("Reading an audio property failed (Core Audio error \(status)).") }
    }

    /// The system's handle for a process that is playing or recording audio, or nil if it
    /// is not doing either yet.
    private static func audioProcessObject(for pid: pid_t) throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr else { throw StandError("Looking up this process for the audio tap failed (Core Audio error \(status)).") }
        return object == kAudioObjectUnknown ? nil : object
    }
}

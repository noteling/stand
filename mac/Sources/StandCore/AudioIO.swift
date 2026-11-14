import AVFoundation

/// Everything Stand hears and the speakers it talks through.
///
/// It hears two things, mixed into one stream for the voice model:
///   - the microphone, for the person in the room. With voice processing on, macOS removes
///     from it whatever the Mac is playing, so Stand does not hear itself.
///   - the system audio tap, for the call. Voice processing removes the call from the
///     microphone too, so the call has to be heard directly.
public final class AudioIO {
    public struct Options {
        public var voiceProcessing = true
        public var systemAudio = true
        public init(voiceProcessing: Bool = true, systemAudio: Bool = true) {
            self.voiceProcessing = voiceProcessing
            self.systemAudio = systemAudio
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tap = SystemAudioTap()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: GeminiLive.speechRate, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GeminiLive.microphoneRate, channels: 1, interleaved: true)!
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // System audio waiting to be mixed into the next microphone chunk.
    private let lock = NSLock()
    private var pendingSystem = [Int16]()
    private var systemPeakSinceRead: Int16 = 0
    private var microphonePeakSinceRead: Int16 = 0
    private static let maxPendingSystem = 16_000 // one second; older audio is dropped

    /// What Stand hears: mono 16-bit little-endian PCM at 16 kHz. Called on an audio thread.
    public var onHeard: ((Data) -> Void)?
    /// For probes: each source on its own, before the two are mixed. Same format as `onHeard`.
    public var onMicrophoneOnly: ((Data) -> Void)?
    public var onSystemOnly: ((Data) -> Void)?
    /// What the inputs turned out to be, for the log.
    public private(set) var description = ""

    public init() {}

    /// Asks macOS for the microphone if it has not been decided yet.
    public static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(_ options: Options = Options()) throws {
        let input = engine.inputNode
        if options.voiceProcessing {
            // Has to be set before the engine starts. It applies to the output too, which
            // is how the echo canceller knows what is being played.
            try input.setVoiceProcessingEnabled(true)
            // By default macOS turns other apps down while voice processing is active.
            // The other app is the call, so ask for as little of that as possible.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw StandError("No microphone is available.") }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        if options.voiceProcessing {
            // The voice-processing unit only initialises with a mono feed at its own sample
            // rate. Left at the default stereo connection, engine.start() fails with -10875
            // (found by trying each combination on a MacBook Air, 2026-11-11).
            let processed = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: 1, interleaved: false)!
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: processed)
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: 1, interleaved: false)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: sendFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        description = "microphone \(Int(hardware.sampleRate)) Hz, \(hardware.channelCount) channel(s), voice processing \(options.voiceProcessing ? "on" : "off")"


        if options.systemAudio {
            // Started after the engine, so the system already knows this process and
            // can leave its output out of the tap.
            tap.onAudio = { [weak self] pcm in self?.queueSystemAudio(pcm) }
            try tap.start()
            description += "; system audio \(tap.formatDescription)"
        } else {
            description += "; system audio off"
        }
    }

    /// Queues Stand's speech: mono 16-bit little-endian PCM at 24 kHz.
    public func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(buffer)
    }

    /// Drops everything queued but not yet played.
    public func flush() {
        player.stop()
        player.play()
    }

    public func stop() {
        tap.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// The loudest sample from each source since the last call, out of 32767. For checking
    /// that both are alive: a tap that was refused permission delivers silence.
    public func takePeaks() -> (microphone: Int, system: Int) {
        lock.withLock {
            defer { microphonePeakSinceRead = 0; systemPeakSinceRead = 0 }
            return (Int(microphonePeakSinceRead), Int(systemPeakSinceRead))
        }
    }

    /// The loudest sample the system audio tap delivered since the last call, 1.0 being full scale.
    public func takeSystemRawPeak() -> Float { tap.takeRawPeak() }

    private func queueSystemAudio(_ pcm: Data) {
        onSystemOnly?(pcm)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            lock.withLock {
                pendingSystem.append(contentsOf: samples)
                if pendingSystem.count > Self.maxPendingSystem { pendingSystem.removeFirst(pendingSystem.count - Self.maxPendingSystem) }
                for s in samples where abs(Int(s)) > Int(systemPeakSinceRead) { systemPeakSinceRead = Int16(min(abs(Int(s)), 32767)) }
            }
        }
    }

    /// Takes the first microphone channel, converts it to 16 kHz 16-bit, adds whatever
    /// system audio has arrived, and hands the mix on.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let monoFormat, let channels = buffer.floatChannelData, buffer.frameLength > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        memcpy(mono.floatChannelData![0], channels[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sendFormat.sampleRate / monoFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let count = Int(out.frameLength)
        onMicrophoneOnly?(Data(bytes: samples, count: count * 2))

        lock.withLock {
            for i in 0..<count where abs(Int(samples[i])) > Int(microphonePeakSinceRead) {
                microphonePeakSinceRead = Int16(min(abs(Int(samples[i])), 32767))
            }
            let take = min(count, pendingSystem.count)
            for i in 0..<take {
                samples[i] = Int16(max(-32768, min(32767, Int(samples[i]) + Int(pendingSystem[i]))))
            }
            pendingSystem.removeFirst(take)
        }
        onHeard?(Data(bytes: samples, count: count * 2))
    }
}

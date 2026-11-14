import AVFoundation

/// Plays speech through the speakers and does nothing else: no microphone, no voice
/// processing, no call. It is for hearing a sample of a voice before a meeting. In a
/// meeting Stand speaks through `AudioIO`, which also listens.
///
/// Sound may be handed to it from any thread, a piece at a time, as it arrives.
public final class SpeechPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: GeminiLive.speechRate, channels: 1, interleaved: false)!
    private var attached = false
    private var stretch = 0
    private let volume: Float

    /// `volume` runs from 0 to 1. Zero is for checking the player with nobody there to hear it.
    public init(volume: Float = 1) {
        self.volume = volume
    }

    /// How much of the present stretch has come out of the speakers so far, in seconds.
    public var played: Double {
        lock.withLock {
            guard attached, node.isPlaying, let rendered = node.lastRenderTime, let time = node.playerTime(forNodeTime: rendered) else { return 0 }
            return max(0, Double(time.sampleTime) / time.sampleRate)
        }
    }

    /// Stops whatever is playing and begins a new stretch of speech. What it returns goes
    /// with every `play` of that stretch, so that sound still arriving for an earlier one
    /// is dropped and not played over the new.
    public func begin() -> Int {
        lock.withLock {
            stretch += 1
            if attached { node.stop() }
            return stretch
        }
    }

    /// Queues speech: mono 16-bit little-endian PCM at 24 kHz.
    public func play(_ pcm: Data, of stretch: Int) {
        lock.withLock {
            guard stretch == self.stretch else { return }
            let frames = pcm.count / 2
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let samples = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { raw in
                for i in 0..<frames {
                    samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                }
            }
            if !attached {
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = volume
                attached = true
            }
            if !engine.isRunning {
                engine.prepare()
                do { try engine.start() } catch { return }
            }
            if !node.isPlaying { node.play() }
            node.scheduleBuffer(buffer)
        }
    }

    /// Stops the sound and lets go of the speakers. With `ifStill`, only when no newer
    /// stretch has begun since: that is how a stretch that has played out is tidied away.
    public func stop(ifStill stretch: Int? = nil) {
        lock.withLock {
            if let stretch, stretch != self.stretch { return }
            self.stretch += 1
            guard attached else { return }
            node.stop()
            engine.stop()
        }
    }
}

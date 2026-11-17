import Foundation

/// Decides, from the room's sound alone, when someone starts and stops speaking, so that
/// the voice service can be handed each utterance whole (`StandSession.hear`). The service
/// can decide this for itself, and did until 2026-11-12; it lost the first word of
/// whatever was said about a second after someone else had finished.
///
/// It judges the sound in frames of 20 ms, whatever size the sound arrives in. A real
/// microphone delivers a tenth of a second at a time and the scripted audience a
/// fiftieth, and the two have to be judged alike: at a tenth of a second, "kept up for
/// 0.15 seconds" would mean three whole chunks, and someone cutting in on Stand would be
/// noticed up to a second late.
///
/// It has no state but what it is fed, so a recording can be played through it with no
/// session at all: `Stand --probe marker <run folder>`.
public struct SpeechMarker {
    public enum Event {
        /// The room was loud at this moment: a voice, or any other sound over the bar.
        case loud(at: Double)
        /// Someone has started speaking. With it comes the sound from just before, so
        /// that a soft first consonant is not lost.
        case started(at: Double, leadIn: Data)
        /// More of what they are saying.
        case sound(Data, at: Double)
        /// They have stopped.
        case stopped(at: Double)
        /// Someone made a sound while Stand was speaking, and it was over before it came
        /// to anything: a cough, an "mm-hm", a short laugh. Nobody was told. `from` is its
        /// first loud moment and `to` its last.
        case passedOver(id: Int, from: Double, to: Double, loud: Double)
        /// A sound made while Stand was speaking has gone quiet without having come to
        /// enough to count as someone speaking. It is still being weighed: more of it may
        /// follow. This is all of it so far, with the quiet before it, for something that
        /// can tell what it was (`Ear`). `id` is the same for every part of one sound, and
        /// for the `passedOver` that lets it go.
        case weighed(id: Int, sound: Data, from: Double, to: Double, loud: Double)
    }

    /// Sound has to be louder than this, out of 32768, to count at all.
    public var level: Double
    /// This much quiet ends an utterance.
    public var endsAfter: Double
    /// While Stand is speaking, a sound counts as someone speaking only once this much of
    /// it has been loud. A person who is talking is not stopped by a cough or an "mm-hm",
    /// and takes most of a second to notice that someone else has started; until
    /// 2026-11-13 Stand stopped for anything, a fifth of a second in. The sound is kept
    /// meanwhile, so nothing of what is said is lost. 0 means at once.
    public var cutsInAfter = 0.0
    /// A sound that is being weighed is offered (`weighed`) once it has been quiet for
    /// this long: long enough that a word is over, far short of the quiet that lets the
    /// sound go. 0, as it is unless the session has an ear, offers nothing.
    public var offersAfter = 0.0
    /// A sound that has not come to that much after this long is let go.
    static let waitsAtMost = 4.0
    /// True between `started` and `stopped`.
    public private(set) var isOpen = false
    /// What sound has to exceed just now: `level`, or more in a noisy room.
    public private(set) var bar: Double

    public static let frameSeconds = 0.02
    static let frameBytes = Int(GeminiLive.microphoneRate * frameSeconds) * 2
    /// How much sound from before an utterance goes with it: 0.3 seconds.
    static let leadInFrames = 15

    private var carried = Data() // less than a frame, left over from the last chunk
    private var recent = [(t: Double, level: Double)]() // how loud the last four seconds were
    private var leadIn = [Data]() // the last frames of quiet
    private var lastLoud = -Double.infinity
    private var loudLately = [Bool]() // the last ten frames: over the bar or not
    private var clearlyLoudLately = [Bool]() // the same, for one and a half times the bar
    /// A sound that began while Stand was speaking and has not yet come to enough: when it
    /// began, how many of its frames were loud, and all of it so far with the quiet before it.
    /// `began` is when its first loud moment was, a little before the weighing started.
    /// `offered`: how many of its frames were loud when it was last offered (`weighed`).
    private var waiting: (id: Int, since: Double, began: Double, loud: Int, frames: [Data], offered: Int)?
    private var sounds = 0 // how many sounds have been weighed

    public init(level: Double = 500, endsAfter: Double = 0.7) {
        self.level = level
        self.endsAfter = endsAfter
        bar = level
    }

    /// Takes the next stretch of the room's sound (mono 16-bit PCM at 16 kHz), which ends
    /// at `time`, and says what happened in it, in order. `standAudible` answers whether
    /// Stand's own voice was coming out of the speakers at a given moment.
    public mutating func take(_ pcm: Data, endingAt time: Double, standAudible: (Double) -> Bool) -> [Event] {
        carried.append(pcm)
        let frames = carried.count / Self.frameBytes
        guard frames > 0 else { return [] }
        var events = [Event]()
        let base = carried.startIndex
        for i in 0..<frames {
            let frame = carried.subdata(in: (base + i * Self.frameBytes)..<(base + (i + 1) * Self.frameBytes))
            step(frame, at: time - Double(frames - 1 - i) * Self.frameSeconds, standAudible: standAudible, into: &events)
        }
        carried = carried.subdata(in: (base + frames * Self.frameBytes)..<carried.endIndex)
        return events
    }

    /// Ends the utterance now, without waiting out the quiet. For when the room has gone
    /// silent and something else needs the model's attention. False if none was open.
    /// The sound being weighed is someone speaking after all: something that understood
    /// it has said so, before enough of it was loud. The utterance is opened from here,
    /// and what was kept of the sound is returned with its `id`, to be sent ahead of the
    /// rest. Nil when no sound is being weighed, or an utterance is open already.
    public mutating func call() -> (id: Int, sound: Data)? {
        guard !isOpen, let held = waiting else { return nil }
        waiting = nil
        isOpen = true
        leadIn.removeAll()
        return (held.id, held.frames.reduce(into: Data()) { $0.append($1) })
    }

    public mutating func stop() -> Bool {
        waiting = nil
        guard isOpen else { return false }
        isOpen = false
        loudLately.removeAll()
        clearlyLoudLately.removeAll()
        return true
    }

    private mutating func step(_ frame: Data, at t: Double, standAudible: (Double) -> Bool, into events: inout [Event]) {
        let loudness = PCM.rms(frame)

        // The bar rises with the room's own steady noise: three times the quietest moment
        // of the last four seconds, and never under `level`. A fan or a hum lifts it. A
        // voice does not, because a voice comes in bursts with quiet between them.
        recent.append((t, loudness))
        while let first = recent.first, t - first.t > 4 { recent.removeFirst() }
        if let first = recent.first, t - first.t > 1 {
            bar = max(level, recent.reduce(Double.infinity) { min($0, $1.level) } * 3)
        } else {
            bar = level
        }

        let isLoud = loudness > bar
        if isLoud {
            lastLoud = t
            events.append(.loud(at: t))
        }
        loudLately.append(isLoud)
        clearlyLoudLately.append(loudness > bar * 1.5)
        if loudLately.count > 10 {
            loudLately.removeFirst()
            clearlyLoudLately.removeFirst()
        }

        if !isOpen {
            let loud = loudLately.filter { $0 }.count
            let starts: Bool
            if standAudible(t) {
                // What is left of Stand's own voice in the microphone must not pass for
                // someone cutting in. That takes a sound that is kept up: seven loud frames
                // among the last ten, two of them clearly loud. A voice dips between
                // syllables, so the frames need not be in a row. Measured on 2026-11-12:
                // Stand's own voice came back at 448 at most, a person at the microphone at
                // 3000 to 8000, and a call's other voices, which macOS turns down while
                // Stand speaks, at 600 to 2500.
                starts = isLoud && loud >= 7 && clearlyLoudLately.filter { $0 }.count >= 2
            } else {
                // A click or a key press is over in a frame or two. A voice is not: four
                // loud frames among the last ten.
                starts = isLoud && loud >= 4
            }
            if var held = waiting {
                // A sound is being weighed. It is someone speaking once enough of it has been
                // loud, or as soon as Stand itself has stopped and it is still going on.
                if isLoud { held.loud += 1 }
                let loudFor = Double(held.loud) * Self.frameSeconds
                let goingOn = t - lastLoud <= 0.3
                if loudFor >= cutsInAfter || (!standAudible(t) && goingOn) {
                    waiting = nil
                    isOpen = true
                    events.append(.started(at: t, leadIn: held.frames.reduce(into: Data()) { $0.append($1) }))
                    leadIn.removeAll()
                } else if t - lastLoud > endsAfter || t - held.since > Self.waitsAtMost {
                    // It stopped, or dragged on without ever amounting to speech: let it go.
                    waiting = nil
                    events.append(.passedOver(id: held.id, from: held.began, to: lastLoud, loud: loudFor))
                    leadIn = Array(held.frames.suffix(Self.leadInFrames - 1))
                    loudLately.removeAll()
                    clearlyLoudLately.removeAll()
                } else {
                    held.frames.append(frame)
                    // Quiet for a moment, and louder than when it was last offered: what there is of it is offered.
                    if offersAfter > 0, !isLoud, t - lastLoud >= offersAfter, held.loud > held.offered {
                        held.offered = held.loud
                        events.append(.weighed(id: held.id, sound: held.frames.reduce(into: Data()) { $0.append($1) },
                                               from: held.began, to: lastLoud, loud: loudFor))
                    }
                    waiting = held
                }
            } else if starts {
                if cutsInAfter > 0, standAudible(t) {
                    // Kept from here on with the quiet before it, this frame included.
                    sounds += 1
                    // The sound began with the first loud frame of the last ten, not with the one that settled it.
                    let before = loudLately.count - 1 - (loudLately.firstIndex(of: true) ?? loudLately.count - 1)
                    waiting = (sounds, t, t - Double(before) * Self.frameSeconds, loud, leadIn + [frame], 0)
                    leadIn.removeAll()
                } else {
                    isOpen = true
                    events.append(.started(at: t, leadIn: leadIn.reduce(into: Data()) { $0.append($1) }))
                    leadIn.removeAll()
                }
            }
        }
        if isOpen {
            events.append(.sound(frame, at: t))
            if t - lastLoud > endsAfter {
                isOpen = false
                loudLately.removeAll()
                clearlyLoudLately.removeAll()
                events.append(.stopped(at: t))
            }
        } else if waiting == nil {
            leadIn.append(frame)
            if leadIn.count > Self.leadInFrames { leadIn.removeFirst() }
        }
    }
}

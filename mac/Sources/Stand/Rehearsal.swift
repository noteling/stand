import Foundation
import StandCore

/// A scripted audience for the native session, with no microphone, no speakers and no
/// person. It plays spoken lines into a `StandSession` at set moments (using the Mac's
/// built-in voices) and writes a report of how Stand reacted. It reads the same scripts
/// as poc/src/heckler.js, so the Swift port can be checked against the JavaScript one.
///
///   Stand --rehearse                                   the north-star script
///   Stand --rehearse poc/heckler/junk.json
///   Stand --rehearse poc/heckler/ending.json --talk poc/heckler/short-talk.md
///   Stand --rehearse poc/heckler/notes-passed.json --brief poc/heckler/brief.md
///   Stand --rehearse poc/heckler/discussion.json        Stand gives no talk: it sits in a discussion
///
/// A script with a "discussion" is a meeting among the audience's own voices. Stand attends
/// it without a talk, and each line says whether Stand should speak after it ("expect").
/// The report counts how often it did as expected, and discussion.json holds the same
/// for adding up over several runs (mac/scripts/tally.py).
///
/// A script line of kind "whisper" is not spoken: it is passed to Stand as a private note
/// from its human, the way the panel's text field does it. --brief gives the run a
/// meeting brief; without it there is none, whatever brief.md holds.
///
/// With --out-loud it uses the real microphone, speakers and system audio tap, wired as
/// the app wires them, and another program plays the audience's lines through the
/// speakers, the way a call's audio arrives. That needs the app's two permissions and a quiet room.
enum Rehearsal {
    struct Script: Decodable {
        struct Item: Decodable {
            var label: String?
            var kind: String?
            var afterSpeechSeconds: Double?
            var atSeconds: Double?
            /// In a talk: a follow-up to the line before, said once Stand has answered that
            /// one and then been quiet for this long. It is how a person says "thanks, go
            /// on", or comes back after asking Stand to wait: into a silence, not over Stand.
            var afterQuietSeconds: Double?
            var voice: String?
            var say: String
            var howlSeconds: Double?
            /// A stretch of a recording to play in place of a spoken line: real people's
            /// laughter and talk, which the Mac's voices cannot do. A path from the repo
            /// root to a 16 kHz WAV file (a kept session's room.wav), and the seconds to
            /// take from it. `say` then only names the line.
            var clip: String?
            var clipFrom: Double?
            var clipTo: Double?
            /// Silence to leave before this line. Stretches a session out, for long-meeting checks.
            var waitSeconds: Double?
            /// For a note passed after the talk: how long to wait for Stand to start speaking because of it.
            var replyWithinSeconds: Double?
            /// A note passed to Stand while this line is being spoken, this long after it starts.
            var noteDuring: String?
            var noteAfterSeconds: Double?
            /// In a discussion: "quiet" when Stand should say nothing after this line, "speaks"
            /// when it should. Left out when either is fine.
            var expect: String?
            /// In a discussion, with "speaks": it also counts if Stand spoke after the line before this one.
            var alsoAfterPrevious: Bool?
            /// In a discussion: silence after this line before the next person speaks.
            var gapSeconds: Double?
            /// In a discussion: this person starts even if Stand is speaking.
            var overStand: Bool?
            /// In a discussion: this person cuts in once Stand has been speaking this long.
            var intoStandSeconds: Double?
            /// In a discussion, with "speaks": what Stand says has to match this, as a pattern, whatever the capitals.
            var mustSay: String?
            /// In a discussion: what Stand must not say after this line, as a pattern, whatever
            /// it was expected to do. A line that has only this is judged on it.
            var mustNotSay: String?
            var isNote: Bool { kind == "whisper" }
        }
        /// Stand's human, for a run in which Stand may put questions to them. A question
        /// that matches `about` (a pattern, whatever the capitals) is answered with `say`
        /// after `afterSeconds`, or with "no answer" when `say` is left out. A question
        /// that matches nothing is never answered. Without `human`, Stand cannot ask.
        struct HumanAnswer: Decodable {
            var about: String
            var say: String?
            var afterSeconds: Double?
        }
        var human: [HumanAnswer]?
        /// A meeting among the audience, which Stand attends without giving a talk. Spoken in order.
        var discussion: [Item]?
        /// The brief for this run, as a path from the repo root. --brief on the command line wins.
        var brief: String?
        /// In a discussion: silence between one person's line and the next, unless the line says otherwise.
        var gapSeconds: Double?
        var during: [Item]?
        var after: [Item]?
        var goodbye: Item?
        var talkIsAtLeastSpeechSeconds: Double?
        /// How this run answers when the brain asks Stand's human for a yes. Left out, nobody answers, which is a no.
        var answerAsks: Bool?
        var talkEndsAfterQuietSeconds: Double?
        var maxMinutes: Double?
    }

    struct Line {
        let item: Script.Item
        let pcm: Data
        var label: String { item.label ?? item.kind ?? "line" }
    }

    final class Utterance {
        let label, text: String
        var kind: String
        let standWasSpeaking: Bool
        let start: Double
        var end = 0.0
        var stoppedAfter: Double?
        var repliedAfter: Double?
        var standSaid = ""
        // In a discussion.
        var voice = ""
        var expect: String?
        var alsoAfterPrevious = false
        var standSpokeSeconds = 0.0
        var standStartedDuring = false
        var mustSay: String?
        var mustNotSay: String?
        var asExpected: Bool?
        init(label: String, kind: String, text: String, standWasSpeaking: Bool, start: Double) {
            self.label = label; self.kind = kind; self.text = text; self.standWasSpeaking = standWasSpeaking; self.start = start
        }
    }

    static let rate = GeminiLive.microphoneRate
    static let chunkSeconds = 0.02

    static func run(scriptPath: String?, arguments: [String]) async throws {
        // A rehearsal's questions are scripted. They should not go looking in this person's own
        // mail and calendar, so this Mac's Claude Code setup stays out unless --own-setup says otherwise.
        if !arguments.contains("--own-setup") { setenv("STAND_CLAUDE_SETUP", "off", 0) }
        let root = try Project.root()
        let scriptURL = URL(fileURLWithPath: scriptPath ?? "poc/heckler/north-star.json", relativeTo: root)
        let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: scriptURL))
        let maxSeconds = (script.maxMinutes ?? 12) * 60
        let quietEndsTalk = script.talkEndsAfterQuietSeconds ?? 12
        let minTalkSpeech = script.talkIsAtLeastSpeechSeconds ?? 45

        // Prepare every line's audio before connecting, so the session clock is not spent on it.
        let when: (Script.Item) -> Double = { $0.afterSpeechSeconds ?? $0.atSeconds ?? 0 }
        // In the order they come due. A follow-up (`afterQuietSeconds`) stays behind the line it follows.
        var dueAt = [Double]()
        for item in script.during ?? [] { dueAt.append(item.afterQuietSeconds == nil ? when(item) : dueAt.last ?? 0) }
        let during = try zip(script.during ?? [], dueAt).enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map { try prepare($0.element.0) }
        let after = try (script.after ?? []).map(prepare)
        let goodbye = try script.goodbye.map(prepare)
        let discussion = try script.discussion.map { try $0.map(prepare) }
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("stand-rehearsal-\(getpid())"))

        let outLoud = arguments.contains("--out-loud")
        var settings = StandSession.Settings()
        if let i = arguments.firstIndex(of: "--talk"), arguments.indices.contains(i + 1) { settings.talk = arguments[i + 1] }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let path = value("--brief") ?? script.brief {
            let url = URL(fileURLWithPath: path, relativeTo: root)
            guard let brief = try? String(contentsOf: url, encoding: .utf8) else { throw StandError("Could not read the brief at \(url.path).") }
            settings.brief = brief
        }
        // Who marks when someone is speaking: this program, unless --service-activity leaves
        // it to the voice service, to compare the two.
        if arguments.contains("--service-activity") { settings.ownActivity = false }
        if let seconds = value("--activity-ends-after").flatMap({ Double($0) }) { settings.ownActivityEndsAfter = seconds }
        if let seconds = value("--ends-after-when-out").flatMap({ Double($0) }) { settings.endsAfterWhenOut = seconds }
        // --turn-finishes-within 0: the service is told at once when someone starts speaking just after an utterance was closed.
        if let seconds = value("--turn-finishes-within").flatMap({ Double($0) }) { settings.turnFinishesWithin = seconds }
        // How much of the session the model keeps, in tokens, to see what a smaller memory costs and loses.
        // --remember-minutes: how much of the meeting the voice model keeps word for word. A small number makes it forget within a short script.
        if let minutes = value("--remember-minutes").flatMap({ Double($0) }) { settings.rememberMinutes = minutes }
        if let tokens = value("--context-tokens").flatMap({ Int($0) }) { settings.contextLimit = tokens }
        if let tokens = value("--context-keeps").flatMap({ Int($0) }) { settings.contextKeeps = tokens }
        // --no-prompter: no second brain follows the meeting, to see what Stand does and forgets without it.
        if arguments.contains("--no-prompter") { settings.hasPrompter = false }
        // --no-watch: no brain keeps watch over the talk, to see what happens without it.
        // --watch-every 3: how often it is asked while nothing else prompts it.
        if arguments.contains("--no-watch") { settings.hasWatch = false }
        // --no-ear: a talk without the ear for short sounds (`Ear`), to compare. A sound then
        // stops Stand only once 0.6 seconds of it has been loud.
        if arguments.contains("--no-ear") { settings.hasEar = false }
        if let every = value("--watch-every").flatMap({ Double($0) }) { settings.watchEvery = every }
        if arguments.contains("--whole-talk") { settings.handsSections = false }
        // --voice Puck: whose voice Stand speaks with (prompts/voices-gemini.txt). Kore unless said.
        if let name = value("--voice") { settings.voice = name }
        if discussion != nil { settings.talk = "" } // a discussion has no talk
        if outLoud { settings.echoSettle = 1.0 } // as the app sets it
        settings.answerAsks = script.answerAsks
        settings.canAskHuman = script.human != nil
        let session = StandSession(root: root, label: outLoud ? "rehearsal-out-loud" : "rehearsal", settings: settings)
        // --screen: the pages the talk names go up in a window of Stand's own. It is kept
        // off the display unless --show-screen puts it there to be watched. --eye picture
        // looks at the window by reading a picture of it, as any other screen would have to
        // be looked at. --screen-fails 2,4: the second and the fourth page asked for do not come up.
        // --in-chrome (or STAND_SCREEN=chrome): the pages go up in a window Stand opens in
        // the person's own Chrome instead, which is on the display whatever else is said.
        var pageScreen: PageScreen?
        if arguments.contains("--screen") || arguments.contains("--show-screen") || arguments.contains("--in-chrome") {
            let eye = PageScreen.Eye(rawValue: value("--eye") ?? "page") ?? .page
            let visible = arguments.contains("--show-screen")
            let place: PageScreen.Where = arguments.contains("--in-chrome") ? .browser : PageScreen.Where.told ?? .window
            let made = await MainActor.run { PageScreen(root: root, visible: visible, eye: eye, in: place) }
            pageScreen = made
            let failing = Set((value("--screen-fails") ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            session.screen = failing.isEmpty ? made : FaultyScreen(made, failing: failing)
        }
        // Closed before this run ends, and waited for: a window in someone's browser would otherwise outlive the rehearsal.
        defer { if let pageScreen { pageScreen.closeAndWait() } }
        let audio = outLoud ? AudioIO() : nil
        if let audio {
            guard await AudioIO.microphoneAllowed() else {
                throw StandError("Microphone access was refused. Allow it for Stand in System Settings > Privacy & Security > Microphone.")
            }
            session.onSpeech = { [weak audio] pcm in audio?.play(pcm) }
            session.onFlush = { [weak audio] in audio?.flush() }
        }
        func stamp(_ text: String) { print(String(format: "%5@  %@", clock(session.now), text)) }
        session.onUpdate = { update in
            switch update {
            case .interrupted: stamp("Stand stopped mid-speech")
            case .carryOn: stamp("the stage manager told Stand to carry on")
            case .lookingUp(let question): stamp("Stand asked its brain: \"\(question)\"")
            case .lookedUp(let answer, let seconds): stamp(String(format: "the brain answered in %.1f s: \"%@\"", seconds, answer))
            case .told(let note): stamp("its human passed Stand a note: \"\(note)\"")
            case .brainBusy(let what): stamp("the brain is \(what)")
            case .asking(_, let what, _): stamp("the brain asks Stand's human for a yes to \(what)")
            case .asked(_, let allowed): stamp("the answer was \(allowed ? "yes" : "no")")
            case .askingHuman(let id, let question):
                stamp("Stand asks its human: \"\(question)\"")
                guard let rule = (script.human ?? []).first(where: { question.range(of: $0.about, options: [.regularExpression, .caseInsensitive]) != nil }) else {
                    stamp("its human does not answer")
                    break
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((rule.afterSeconds ?? 6) * 1_000_000_000))
                    session.answer(question: id, with: rule.say)
                }
            case .humanAnswered(_, let answer): stamp("its human answers: \(answer.map { "\"\($0)\"" } ?? "no answer")")
            case .prompted(_, let cue): if let cue { stamp("the prompter thinks this worth saying: \"\(cue)\"") }
            case .screen(let shown, let what): stamp(what.hasPrefix("for section") ? (shown ? "the screen changed " : "the screen did NOT change ") + what : "the page " + what)
            case .watched(let what): stamp("the watch: \(what)")
            case .earHeard(let what): stamp("the ear: \(what)")
            case .error(let message): stamp("error: \(message)")
            case .closed(let reason, _): stamp("session closed: \(reason)")
            default: break
            }
        }
        try await session.open()
        print("Scripted audience against \(session.model), script \(scriptURL.lastPathComponent), native session\(outLoud ? ", out loud" : "")\(session.voice == Voices.usual ? "" : ", in \(session.voice)'s voice")")
        if let audio {
            audio.onHeard = { [weak session] pcm in session?.hear(pcm) }
            try audio.start()
            print(audio.description)
        }

        // Not out loud: the room's audio is sent without pause, in real time: a line when
        // the audience speaks, silence otherwise.
        let room = Room()
        // For checking how Stand copes with a real room: a steady noise under everything
        // (--room-noise, as a level out of 32768), and Stand's own voice coming back into
        // the microphone (--echo, as a fraction of how loud it is played).
        room.noise = value("--room-noise").flatMap { Double($0) } ?? 0
        room.echo = value("--echo").flatMap { Double($0) } ?? 0
        if !outLoud, room.echo > 0 {
            session.onSpeech = { [weak room] pcm in room?.standSaid(pcm) }
            session.onFlush = { [weak room] in room?.standStopped() }
        }
        // --hear: a person can listen to this rehearsal, and with --show-screen watch it.
        // Stand's voice and the audience's lines come out of the speakers. The microphone is
        // not used, so nothing in the room gets in, and nothing Stand says comes back to it.
        // --hear 0 does the same without a sound, to check it with nobody there.
        var listener: Listener?
        if !outLoud, room.echo == 0, arguments.contains("--hear") {
            let made = Listener(volume: value("--hear").flatMap { Float($0) } ?? 1)
            listener = made
            session.onSpeech = { pcm in made.stand(pcm) }
            session.onFlush = { made.standStopped() }
        }
        defer {
            if let listener {
                print(String(format: "Through the speakers at volume %g: %.0f s of Stand's voice and %.0f s of the audience's.", listener.volume, listener.standSeconds, listener.audienceSeconds))
                listener.stop()
            }
        }
        let pump = outLoud ? nil : Task.detached {
            let chunkBytes = Int(rate * chunkSeconds) * 2
            let started = Date()
            var sent = 0
            while !Task.isCancelled {
                let due = Int(Date().timeIntervalSince(started) / chunkSeconds)
                while sent < due {
                    session.hear(room.nextChunk(bytes: chunkBytes))
                    sent += 1
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        var utterances = [Utterance]()
        func utter(_ line: Line, kind: String) async -> Utterance {
            let u = Utterance(label: line.label, kind: kind, text: line.item.say, standWasSpeaking: session.isStandSpeaking, start: session.now)
            stamp("audience (\(u.label)): \"\(line.item.say)\"")
            if let note = line.item.noteDuring {
                let delay = line.item.noteAfterSeconds ?? 1
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    session.tell(note)
                }
            }
            listener?.audience(line.pcm)
            if outLoud { await playOutLoud(line.pcm) } else { await room.speak(line.pcm) }
            u.end = session.now
            utterances.append(u)
            return u
        }
        // A note from Stand's human: nothing is said out loud.
        func pass(_ line: Line) -> Utterance {
            let u = Utterance(label: line.label, kind: "note", text: line.item.say, standWasSpeaking: session.isStandSpeaking, start: session.now)
            session.tell(line.item.say)
            u.end = session.now
            utterances.append(u)
            return u
        }
        func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        func standStarted(after t: Double) -> Bool { session.log.contains { $0.type == "stand_start" && $0.t >= t - 0.3 } }
        // After "let me check", an audience waits for the answer: while the brain is
        // working, and then a few seconds for Stand to start saying what it found.
        func waitingOnLookUp() -> Bool {
            if session.waitingOnBrain { return true }
            // An answer, or word that it is taking a moment, has just reached Stand, and it has not started to speak yet.
            guard let last = session.log.last(where: { $0.type == "lookup_answer" || $0.type == "lookup_slow" }) else { return false }
            return session.now - last.t < 5 && !session.log.contains { $0.type == "stand_start" && $0.t > last.t }
        }
        // Stand has answered once it starts speaking after the line and then goes quiet.
        func untilAnswered(_ u: Utterance, startWithin: Double = 15) async {
            guard await until(startWithin, { session.closed || standStarted(after: u.end) }), !session.closed else { return }
            _ = await until(90) {
                session.closed || (!session.isStandSpeaking && session.now - session.speechRunsOutAt > 2.5 && !waitingOnLookUp())
            }
        }
        // The talk is over when Stand says so, invites questions and then pauses, or stays
        // quiet longer than a stall-and-nudge would take.
        func talkOver() -> String? {
            guard !session.isStandSpeaking else { return nil }
            let quietFor = session.now - session.speechRunsOutAt
            if session.floorOpen, quietFor > 2 { return "Stand signalled that the floor is open" }
            let lastLine = session.lines.last { $0.who == .stand }
            let invited = (lastLine?.text.suffix(200).lowercased().contains("question") ?? false) && session.spokenSeconds >= minTalkSpeech
            // With sections still to hand over, the talk is not over, whatever Stand's last sentence was about.
            if invited, quietFor > 3, session.sectionsToGive == 0 { return "Stand invited questions" }
            if quietFor > quietEndsTalk { return "Stand went quiet" }
            return nil
        }
        func isDue(_ line: Line) -> Bool {
            if let s = line.item.afterSpeechSeconds { return session.spokenSeconds >= s }
            return session.now - (session.began ?? 0) >= (line.item.atSeconds ?? 0)
        }

        if let discussion {
            session.begin()
            stamp("Stand joined the discussion")
            _ = await until(1.5) { session.closed }
            let usualGap = script.gapSeconds ?? 0.9
            var waitedForAnswer = false
            for line in discussion {
                if session.closed || session.now >= maxSeconds { break }
                if line.item.isNote {
                    // A note is judged like a line: Stand should act on it out loud, or not.
                    let u = pass(line)
                    u.kind = "discussion"
                    u.voice = "(a note)"
                    u.expect = line.item.expect
                    u.mustSay = line.item.mustSay
                    u.mustNotSay = line.item.mustNotSay
                    if u.expect == "speaks" {
                        _ = await until(line.item.replyWithinSeconds ?? 6) { session.closed || standStarted(after: u.end) }
                    } else {
                        _ = await until(line.item.gapSeconds ?? 2.5) { session.closed }
                    }
                    waitedForAnswer = false
                    continue
                }
                // People let whoever is speaking finish, Stand included. Someone who has
                // just asked Stand something also waits while it checks.
                if let into = line.item.intoStandSeconds {
                    if await until(20, { session.closed || session.isStandSpeaking }) { _ = await until(into) { session.closed } }
                } else if line.item.overStand != true {
                    let wasWaiting = waitedForAnswer
                    _ = await until(60) {
                        session.closed || (!session.isStandSpeaking && session.now - session.speechRunsOutAt > 0.6 && !(wasWaiting && waitingOnLookUp()))
                    }
                }
                if session.closed { break }
                let u = await utter(line, kind: "discussion")
                u.voice = line.item.voice ?? ""
                u.expect = line.item.expect
                u.mustSay = line.item.mustSay
                u.mustNotSay = line.item.mustNotSay
                u.alsoAfterPrevious = line.item.alsoAfterPrevious ?? false
                let gap = line.item.gapSeconds ?? usualGap
                waitedForAnswer = line.item.expect == "speaks"
                if waitedForAnswer {
                    // Whoever expects an answer leaves room for one.
                    _ = await until(max(gap, line.item.replyWithinSeconds ?? 6)) { session.closed || standStarted(after: u.end) }
                } else {
                    _ = await until(gap) { session.closed }
                }
            }
            // Let Stand finish whatever the last line set off.
            _ = await until(4) { session.closed || session.isStandSpeaking }
            _ = await until(60) { session.closed || (!session.isStandSpeaking && session.now - session.speechRunsOutAt > 2 && !waitingOnLookUp()) }
            pump?.cancel()
            audio?.stop()
            session.closeAndWait(reason: "the scripted discussion finished")
            try reportDiscussion(session: session, utterances: utterances, script: scriptURL.lastPathComponent, settings: settings)
            print("\nReport: \(session.folder.appendingPathComponent("report.md").path)")
            print("Recording: \(session.folder.appendingPathComponent("recording.wav").path)")
            return
        }

        session.begin()
        stamp("the talk was started")

        // If the talk finishes before a line comes due, questions that were meant to
        // interrupt are asked with the closing questions instead, so they are still tested.
        var missed = [Line]()
        for (i, line) in during.enumerated() {
            if let quiet = line.item.afterQuietSeconds {
                _ = await until(60) {
                    session.closed || (!session.isStandSpeaking && session.now - session.speechRunsOutAt >= quiet && !waitingOnLookUp())
                }
                if session.closed || session.now >= maxSeconds { break }
                let u = await utter(line, kind: line.item.kind ?? "follow-up")
                // Give Stand room to answer or to go on, as the person who said it would.
                _ = await until(8) { session.closed || standStarted(after: u.end) }
                continue
            }
            _ = await until(maxSeconds - session.now) { session.closed || isDue(line) || talkOver() != nil }
            if session.closed || session.now >= maxSeconds { break }
            if !isDue(line) {
                missed = during[i...].filter { $0.item.kind != "noise" && !$0.item.isNote }
                stamp("the talk ended before \(during.count - i) planned line(s); the questions among them move to the end")
                break
            }
            if line.item.isNote {
                _ = pass(line)
                continue
            }
            _ = await until(15) { session.closed || session.isStandSpeaking } // talk over Stand, as a real interruption would
            let u = await utter(line, kind: line.item.kind ?? "question")
            // In a talk a line may say what should become of it: "stops" when Stand should
            // stop for it, "passes" when Stand should talk on.
            u.expect = line.item.expect
            // Let Stand begin its reply before anything else happens. A noise needs no reply.
            if u.kind != "noise" { _ = await until(15) { session.closed || standStarted(after: u.end) } }
        }

        var talkEnded = "the time limit was reached"
        _ = await until(max(0, maxSeconds - session.now)) {
            if session.closed { talkEnded = "the session closed"; return true }
            if let over = talkOver() { talkEnded = over; return true }
            return false
        }
        let talkEndedAt = session.now
        stamp("talk over: \(talkEnded)")

        if !session.closed, session.now < maxSeconds {
            for line in missed + after {
                if let wait = line.item.waitSeconds { _ = await until(wait) { session.closed } }
                if session.closed || session.now >= maxSeconds { break }
                if line.item.isNote {
                    // A note may or may not call for speech. Give Stand a while to start, then let it finish.
                    let u = pass(line)
                    if await until(line.item.replyWithinSeconds ?? 8, { session.closed || standStarted(after: u.end + 0.3) }) {
                        await untilAnswered(u, startWithin: 1)
                    }
                    if session.closed { break }
                    continue
                }
                let u = await utter(line, kind: "closing question")
                await untilAnswered(u)
                if session.closed { break }
            }
            if let goodbye, !session.closed {
                let u = await utter(goodbye, kind: "goodbye")
                await untilAnswered(u, startWithin: 6)
            }
        }

        pump?.cancel()
        audio?.stop()
        session.closeAndWait(reason: "the scripted audience finished")

        try report(session: session, utterances: utterances, script: scriptURL.lastPathComponent, talkEnded: talkEnded, talkEndedAt: talkEndedAt)
        print("\nReport: \(session.folder.appendingPathComponent("report.md").path)")
        print("Recording: \(session.folder.appendingPathComponent("recording.wav").path)")
    }

    // MARK: The audience's voice

    /// What the audience is saying right now, handed out in real-time chunks.
    /// For a person listening to a rehearsal: two players, one for Stand's voice and one
    /// for the audience's lines. Output only.
    final class Listener: @unchecked Sendable {
        let volume: Float
        private let standPlayer: SpeechPlayer
        private let audiencePlayer: SpeechPlayer
        private let lock = NSLock()
        private var stretch: Int
        private(set) var standSeconds = 0.0
        private(set) var audienceSeconds = 0.0

        init(volume: Float) {
            self.volume = volume
            standPlayer = SpeechPlayer(volume: volume)
            audiencePlayer = SpeechPlayer(volume: volume)
            stretch = standPlayer.begin()
        }

        func stand(_ pcm: Data) {
            let now = lock.withLock { () -> Int in
                standSeconds += PCM.seconds(pcm, rate: GeminiLive.speechRate)
                return stretch
            }
            standPlayer.play(pcm, of: now)
        }

        /// Someone cut in: what Stand had ready and had not said is dropped, as in a meeting.
        func standStopped() {
            let next = standPlayer.begin()
            lock.withLock { stretch = next }
        }

        /// One line of the audience's, as it was made for the session: 16 kHz.
        func audience(_ pcm: Data) {
            let line = PCM.data(PCM.resample(PCM.samples(pcm), from: Rehearsal.rate, to: GeminiLive.speechRate))
            lock.withLock { audienceSeconds += PCM.seconds(line, rate: GeminiLive.speechRate) }
            audiencePlayer.play(line, of: audiencePlayer.begin())
        }

        func stop() {
            standPlayer.stop()
            audiencePlayer.stop()
        }
    }

    final class Room {
        var noise = 0.0
        var echo = 0.0
        private let lock = NSLock()
        private var speaking: (pcm: Data, position: Int, done: CheckedContinuation<Void, Never>)?
        private var comingBack = [Int16]() // Stand's own voice, on its way out of the speaker and back into the microphone
        private var hum = 0.0

        /// Stand's speech as it is handed over to be played: it is heard, faintly, a moment later.
        func standSaid(_ pcm: Data) {
            let quiet = PCM.resample(PCM.samples(pcm), from: GeminiLive.speechRate, to: rate).map { Int16(Double($0) * echo) }
            lock.withLock { comingBack.append(contentsOf: quiet) }
        }

        func standStopped() {
            lock.withLock { comingBack.removeAll() }
        }

        /// The room's own sound laid over a chunk: Stand's voice coming back, and a steady noise.
        private func withRoomSound(_ chunk: Data) -> Data {
            guard noise > 0 || !comingBack.isEmpty else { return chunk }
            var samples = PCM.samples(chunk)
            let back = comingBack.prefix(samples.count)
            comingBack.removeFirst(back.count)
            for (i, sample) in back.enumerated() { samples[i] = Int16(clamping: Int(samples[i]) + Int(sample)) }
            if noise > 0 {
                // A low rumble, not a hiss: white noise through a one-pole filter, scaled to the level asked for.
                for i in samples.indices {
                    hum = 0.9 * hum + Double.random(in: -1...1)
                    samples[i] = Int16(clamping: Int(samples[i]) + Int(hum * noise * 0.76))
                }
            }
            return PCM.data(samples)
        }

        func speak(_ pcm: Data) async {
            await withCheckedContinuation { done in lock.withLock { speaking = (pcm, 0, done) } }
        }

        func nextChunk(bytes: Int) -> Data {
            lock.withLock {
                guard var current = speaking else { return withRoomSound(Data(count: bytes)) }
                var chunk = current.pcm.subdata(in: current.position..<min(current.position + bytes, current.pcm.count))
                if chunk.count < bytes { chunk.append(Data(count: bytes - chunk.count)) }
                current.position += bytes
                if current.position >= current.pcm.count {
                    speaking = nil
                    current.done.resume()
                } else {
                    speaking = current
                }
                return withRoomSound(chunk)
            }
        }
    }

    /// Plays a line through the speakers from another program, and returns when it has finished.
    private static func playOutLoud(_ pcm: Data) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stand-rehearsal-line-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? PCM.writeWav(pcm, rate: rate, to: url)) != nil else { return }
        _ = try? await Subprocess.run("/usr/bin/afplay", [url.path], timeout: 60)
    }

    private static var installedVoices: Set<String> = {
        guard let out = try? shell("/usr/bin/say", ["-v", "?"]) else { return [] }
        return Set(out.split(separator: "\n").compactMap { line in
            line.range(of: "  ").map { String(line[..<$0.lowerBound]).trimmingCharacters(in: .whitespaces) }
        })
    }()

    @discardableResult
    private static func shell(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StandError("\(path) failed with status \(process.terminationStatus).") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Turns a script line into audio with the Mac's `say`, plus a harsh rising tone if
    /// the line asks for one (like audio feedback in a call).
    private static func prepare(_ item: Script.Item) throws -> Line {
        if item.isNote { return Line(item: item, pcm: Data()) } // passed as text, never spoken
        if let clip = item.clip {
            let wav = try PCM.readWav(URL(fileURLWithPath: clip, relativeTo: try Project.root()))
            guard wav.rate == rate else { throw StandError("\(clip) is at \(Int(wav.rate)) Hz; a clip has to be at \(Int(rate)).") }
            let from = max(0, Int((item.clipFrom ?? 0) * rate)) * 2
            let to = min(wav.pcm.count, Int((item.clipTo ?? .infinity).clamped(to: 0...Double(wav.pcm.count / 2) / rate) * rate) * 2)
            guard from < to else { throw StandError("\(clip) has nothing between \(item.clipFrom ?? 0) and \(item.clipTo ?? 0) seconds.") }
            return Line(item: item, pcm: wav.pcm.subdata(in: (wav.pcm.startIndex + from)..<(wav.pcm.startIndex + to)))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stand-rehearsal-\(getpid())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let aiff = folder.appendingPathComponent(UUID().uuidString + ".aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }
        let voice = item.voice.flatMap { installedVoices.contains($0) ? ["-v", $0] : nil } ?? []
        try shell("/usr/bin/say", voice + ["-o", aiff.path, item.say])
        try shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@\(Int(rate))", "-c", "1", aiff.path, wav.path])
        var pcm = try PCM.readWav(wav).pcm
        if let seconds = item.howlSeconds, seconds > 0 {
            var howl = [Int16]()
            let count = Int(seconds * rate)
            howl.reserveCapacity(count)
            for i in 0..<count {
                let at = Double(i) / rate
                let hz = 900 + 1800 * (at / seconds)
                howl.append(Int16(sin(2 * .pi * hz * at) * 0.7 * 32767))
            }
            pcm.append(howl.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        return Line(item: item, pcm: pcm)
    }

    // MARK: Report

    private static func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// How a discussion went: after each line, did Stand speak, and was that what the script expected.
    /// How much of the session the voice model was set to keep, for a report's line on cost.
    private static func kept(_ settings: StandSession.Settings) -> String {
        if let limit = settings.contextLimit { return limit > 0 ? ", which kept at most \(limit) tokens of the session" : ", which kept all of the session" }
        return String(format: ", which kept at least the last %g minutes word for word", settings.rememberMinutes)
    }

    private static func reportDiscussion(session: StandSession, utterances: [Utterance], script: String, settings: StandSession.Settings) throws {
        let log = session.log
        let lines = session.lines
        let end = log.last?.t ?? session.now
        let spoken = utterances.filter { $0.kind == "discussion" }
        // Each stretch of Stand's speech, as it was heard.
        var stretches = [(start: Double, end: Double)]()
        for event in log {
            if event.type == "stand_start" { stretches.append((event.t, end)) }
            if event.type == "stand_stop", let last = stretches.indices.last { stretches[last].end = min(stretches[last].end, event.at ?? event.t) }
        }
        for (i, u) in spoken.enumerated() {
            let until = i + 1 < spoken.count ? spoken[i + 1].start : end
            let mine = stretches.filter { $0.start >= u.end - 0.3 && $0.start < until }
            u.standSpokeSeconds = mine.reduce(0) { $0 + max(0, min($1.end, until + 30) - $1.start) }
            u.repliedAfter = mine.first.map { max(0, $0.start - u.end) }
            u.standStartedDuring = stretches.contains { $0.start > u.start + 0.4 && $0.start < u.end - 0.3 }
            let text = lines.filter { $0.who == .stand && $0.t >= u.end - 0.5 && $0.t < until }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            u.standSaid = text.count > 500 ? String(text.prefix(500)) + "…" : text
        }
        for (i, u) in spoken.enumerated() {
            let spoke = u.standSpokeSeconds >= 0.5
            switch u.expect {
            case "quiet": u.asExpected = !spoke
            case "speaks":
                // What it said counts too, where the script names it: here or, if allowed, after the line before.
                let said = u.standSaid + (u.alsoAfterPrevious && i > 0 ? " " + spoken[i - 1].standSaid : "")
                let right = u.mustSay.map { said.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true
                u.asExpected = (spoke || (u.alsoAfterPrevious && i > 0 && spoken[i - 1].standSpokeSeconds >= 0.5)) && right
            default: u.asExpected = nil
            }
            // What it must not say, whatever else was expected of it after this line.
            if let never = u.mustNotSay {
                let saidIt = u.standSaid.range(of: never, options: [.regularExpression, .caseInsensitive]) != nil
                u.asExpected = (u.asExpected ?? true) && !saidIt
            }
        }
        // A line before one that says "alsoAfterPrevious" is not held against Stand either way.
        for (i, u) in spoken.enumerated() where u.alsoAfterPrevious && i > 0 && spoken[i - 1].expect == nil { spoken[i - 1].asExpected = nil }

        let judged = spoken.filter { $0.asExpected != nil }
        let right = judged.filter { $0.asExpected == true }.count
        let quiet = spoken.filter { $0.expect == "quiet" }, speaks = spoken.filter { $0.expect == "speaks" }
        let count: (String) -> Int = { type in log.filter { $0.type == type }.count }
        let talkedOver = spoken.filter(\.standStartedDuring).count
        let s = session.summary
        let facts = [
            "Script: \(script), a discussion Stand attends without giving a talk",
            "Who is speaking is marked by \(session.marksActivity ? String(format: "this program (an utterance ends after %.1f s of quiet", settings.ownActivityEndsAfter) + (settings.endsAfterWhenOut != settings.ownActivityEndsAfter ? String(format: ", %.1f s when Stand has no part in the exchange)", settings.endsAfterWhenOut) : ")") : "the voice service")",
            "Length: \(clock(Double(s["durationSeconds"] as? Int ?? 0))), of which Stand spoke for \(clock(Double(s["standSpeechSeconds"] as? Int ?? 0)))",
            "As expected after \(right) of \(judged.count) lines: stayed quiet after \(quiet.filter { $0.asExpected == true }.count) of \(quiet.count), spoke after \(speaks.filter { $0.asExpected == true }.count) of \(speaks.count)",
            "Stand chose to say nothing \(count("kept_quiet")) times. Stray words not played: \(count("swallowed")). Cut off while speaking: \(count("interrupted")). Began to speak while someone was talking: \(talkedOver)",
            "Stand put \(count("human_asked")) questions to its human, and had \(count("human_answer")) answers",
            "The prompter \(settings.hasPrompter ? "passed Stand its sheet \(count("sheet")) times and \(count("cue")) points worth saying, of which \(count("cue_dropped")) were dropped unsaid" : "was off")",
            "Stand asked its brain \(count("lookup")) things",
            "Cost: $\(s["estimatedCostUsd"] ?? 0) over \(s["turns"] ?? 0) turns of the model\(Self.kept(settings))",
        ]
        let rows = spoken.map { u -> String in
            let did = u.standSpokeSeconds >= 0.5
                ? String(format: "spoke after %.1f s, for %.1f s", u.repliedAfter ?? 0, u.standSpokeSeconds) : "said nothing"
            let verdict = u.asExpected.map { $0 ? "as expected" : "**not as expected**" } ?? ""
            return "| \(clock(u.start)) | \(u.voice) | \(u.text) | \(u.expect ?? "either")\(u.mustSay.map { ", saying \($0.replacingOccurrences(of: "|", with: " or "))" } ?? "")\(u.mustNotSay.map { ", never saying \($0.replacingOccurrences(of: "|", with: " or "))" } ?? "") | \(did)\(u.standStartedDuring ? " (and began while they were talking)" : "") | \(verdict) |"
        }
        let said = spoken.filter { !$0.standSaid.isEmpty }.map { "After \($0.voice) at \(clock($0.start)), \"\($0.text)\"\n\n> \($0.standSaid)" }
        let report = """
        # Discussion rehearsal: \(session.model)

        \(facts.map { "- \($0)" }.joined(separator: "\n"))

        ## The discussion

        | When | Who | Said | Stand should | Stand | |
        |---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        ## What Stand said

        Text is grouped by when it arrived, which can run slightly ahead of when it was heard.

        \(said.isEmpty ? "(nothing)" : said.joined(separator: "\n\n"))

        """
        try report.write(to: session.folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print("\n" + facts.map { "- \($0)" }.joined(separator: "\n"))
        for u in spoken where u.asExpected == false {
            print("  not as expected after \(u.voice): \"\(u.text)\" (should: \(u.expect ?? "")) \(u.standSaid.isEmpty ? "" : "→ \(u.standSaid)")")
        }

        let json: [String: Any] = [
            "script": script,
            "ownActivity": session.marksActivity,
            "humanAsked": count("human_asked"), "cues": count("cue"), "lookups": count("lookup"), "keptQuiet": count("kept_quiet"), "swallowed": count("swallowed"), "interrupted": count("interrupted"), "talkedOver": talkedOver,
            "cost": s["estimatedCostUsd"] ?? 0,
            "turns": s["turns"] ?? 0,
            "lines": spoken.enumerated().map { i, u -> [String: Any] in
                var line: [String: Any] = ["n": i + 1, "voice": u.voice, "say": u.text, "expect": u.expect ?? "either",
                                           "spoke": u.standSpokeSeconds >= 0.5, "seconds": (u.standSpokeSeconds * 10).rounded() / 10, "said": u.standSaid]
                if let after = u.repliedAfter { line["after"] = (after * 10).rounded() / 10 }
                if let ok = u.asExpected { line["ok"] = ok }
                return line
            },
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: session.folder.appendingPathComponent("discussion.json"))
    }

    private static func report(session: StandSession, utterances: [Utterance], script: String, talkEnded: String, talkEndedAt: Double) throws {
        let log = session.log
        let lines = session.lines
        for (i, u) in utterances.enumerated() {
            if u.kind == "note" {
                // A note stops nothing. What matters is whether Stand, if silent, spoke because of it.
                if !u.standWasSpeaking {
                    u.repliedAfter = log.first { $0.type == "stand_start" && $0.t >= u.end && $0.t <= u.end + 10 }.map { $0.t - u.end }
                }
            } else if u.standWasSpeaking {
                let cut = log.first { $0.type == "interrupted" && $0.t >= u.start && $0.t <= u.end + 3 }?.t
                let ranOut = log.first { $0.type == "stand_stop" && ($0.at ?? -1) >= u.start - 0.05 && ($0.at ?? -1) <= u.end + 3 }?.at
                u.stoppedAfter = (cut ?? ranOut).map { max(0, $0 - u.start) }
                // Judged on being stopped for it, not on its speech running out by itself just
                // then. A call the ear heard as Stand's speech ran out stops nothing, and counts.
                let called = log.contains { $0.type == "ear_call" && $0.t >= u.start && $0.t <= u.end + 4 }
                if u.expect == "stops" { u.asExpected = cut != nil || called }
                if u.expect == "passes" { u.asExpected = cut == nil && !called }
            }
            if u.kind != "note", !u.standWasSpeaking || u.stoppedAfter != nil {
                u.repliedAfter = log.first { $0.type == "stand_start" && $0.t >= u.end - 0.3 }.map { max(0, $0.t - u.end) }
            }
            // What Stand said next: up to 40 seconds of it, or until the audience speaks again.
            let until = min(i + 1 < utterances.count ? utterances[i + 1].start : .infinity, u.end + 40)
            let text = lines.filter { $0.who == .stand && $0.updated >= u.end && $0.t < until }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            u.standSaid = text.count > 700 ? String(text.prefix(700)) + "…" : text
        }

        let s = session.summary
        let nudges = log.filter { $0.type == "nudge" }
        let facts = [
            "Script: \(script), run by the native session",
            "Length: \(clock(Double(s["durationSeconds"] as? Int ?? 0))), of which Stand spoke for \(clock(Double(s["standSpeechSeconds"] as? Int ?? 0)))",
            "Talk over at \(clock(talkEndedAt)): \(talkEnded)",
            "The stage manager told Stand to carry on \(nudges.filter { ($0.detail ?? "").hasPrefix("stand") }.count) times after Stand's own turn, and \(nudges.filter { !($0.detail ?? "").hasPrefix("stand") }.count) times after a silence nobody filled",
            (s["sections"] as? Int ?? 0) > 0 ? "The talk was handed to Stand a section at a time: \(s["sectionsGiven"] ?? 0) of its \(s["sections"] ?? 0) sections were handed over. In the sections it gave unstopped, \(s["pointsMatched"] ?? 0) of \(s["pointsGiven"] ?? 0) points could be found in its own words" : "Stand kept its own place in the talk",
            "Memory: \(log.first { $0.type == "memory" }?.detail ?? "not recorded"). Its brain passed it the sheet that stands in for the rest \(log.filter { $0.type == "sheet" }.count) times",
            "Estimated cost: $\(s["estimatedCostUsd"] ?? 0) (\(s["costBasis"] ?? "no basis"))",
        ] + (s["pagesShown"] == nil ? [] : [
            "The screen: \(s["pagesShown"] ?? 0) pages came up and \(s["pagesFailed"] ?? 0) did not. The audience asked for a page \(s["pagesAsked"] ?? 0) times, and for the page to be scrolled \(s["scrollsAsked"] ?? 0) times. Inside sections the page moved down with the voice \(s["pageMovedWithTheVoice"] ?? 0) times (\(s["pageMovesFailed"] ?? 0) failed). The talk's own page went back up under Stand's voice \(s["pagesBackWithTheVoice"] ?? 0) times",
        ]) + [
            s["watchAsked"] == nil ? "No brain kept watch over the talk"
                : "A brain kept watch over the talk: asked \(s["watchAsked"] ?? 0) times, it said something other than \"nothing\" \(log.filter { ["watch_said", "talk_held", "talk_released", "watch_stale"].contains($0.type) }.count) times, of which \(s["watchTooLate"] ?? 0) came too late to act on. Its slowest answer took \(s["watchSlowestSeconds"] ?? 0) s",
            !log.contains { $0.type == "ear" } ? "No ear listened to the short sounds made while Stand spoke: a sound stopped it once 0.6 seconds of it was loud, and not otherwise"
                : "An ear listened to the short sounds made while Stand spoke: \(s["earShortSounds"] ?? 0) of them. It took \(s["earNoises"] ?? 0) for a noise, put \(s["earAsked"] ?? 0) to its listening model as words, and heard a call for Stand in \(s["earCalls"] ?? 0), for which Stand was stopped. The model's slowest answer took \(s["earSlowestSeconds"] ?? 0) s",
        ] + (utterances.contains { $0.asExpected != nil }
            ? ["\(utterances.filter { $0.asExpected == true }.count) of the \(utterances.filter { $0.asExpected != nil }.count) lines that say what should become of them went as they say"] : [])
        // The screen, against Stand's own sound: a page has to be up before Stand speaks about
        // it, and must not change under a sentence.
        func speaking(at t: Double) -> Bool {
            let started = log.last { $0.type == "stand_start" && $0.t <= t }?.t
            let stopped = log.last { $0.type == "stand_stop" && ($0.at ?? $0.t) <= t }.map { $0.at ?? $0.t }
            return started.map { $0 > (stopped ?? -1) } ?? false
        }
        var screenTable = [(t: Double, row: String)]()
        for e in log where ["screen_shown", "screen_failed"].contains(e.type) {
            let asked = log.last { $0.type == "screen_moving" && $0.t <= e.t }?.t ?? e.t
            let onRequest = log.contains { $0.type == "page_asked" && $0.t <= asked && asked - $0.t < 0.05 }
            let back = log.contains { $0.type == "screen_back" && $0.t <= asked && asked - $0.t < 0.05 }
            let next = log.first { $0.type == "stand_start" && $0.t >= e.t }.map { String(format: "%.1f s after it", $0.t - e.t) } ?? "not again"
            screenTable.append((asked, "| \(clock(asked)) | \(onRequest ? "the audience" : back ? "the talk, going back to its own page" : "the talk") | \(e.type == "screen_shown" ? "came up" : "DID NOT come up") | \(e.detail ?? "") | \(speaking(at: asked) ? "yes" : "no") | \(next) |"))
        }
        // Inside a section the page follows the voice down. A move is recorded once it has been looked at, about 0.7 s after it began.
        for e in log where ["screen_scrolled", "screen_scroll_failed"].contains(e.type) {
            let began = e.t - 0.7
            screenTable.append((began, "| \(clock(began)) | the voice, inside a section | \(e.type == "screen_scrolled" ? "moved down" : "DID NOT move") | \(e.detail ?? "") | \(speaking(at: began) ? "yes" : "no") | was speaking |"))
        }
        for e in log where e.type == "scroll_asked" {
            let answer = log.first { $0.type == "scroll_answer" && $0.t >= e.t }
            let moved = answer.map { !($0.detail ?? "").hasPrefix("The page did not move") } ?? false
            let next = answer.flatMap { a in log.first { $0.type == "stand_start" && $0.t >= a.t }.map { String(format: "%.1f s after it", $0.t - a.t) } } ?? "not again"
            screenTable.append((e.t, "| \(clock(e.t)) | the audience | \(moved ? "scrolled \(e.detail ?? "")" : "DID NOT scroll") | \(String((answer?.detail ?? "").prefix(110))) | \(speaking(at: e.t) ? "yes" : "no") | \(next) |"))
        }
        let screenRows = screenTable.sorted { $0.t < $1.t }.map(\.row)
        let screenPart = screenRows.isEmpty ? "" : """

        ## The screen

        | Asked for at | By | What happened | What | Was Stand speaking? | Stand next spoke |
        |---|---|---|---|---|---|
        \(screenRows.joined(separator: "\n"))

        A page the talk asks for goes up between sections, so Stand should not be speaking then.
        A page the audience asks for, or a scroll, may happen while Stand is saying that it will do it.
        Inside a section the page follows the voice down, while Stand speaks.
        "Going back to its own page": Stand went on with the talk under a page someone had asked for, and the talk's page was put back under its voice.
        The pictures of the screen, as it was each time, are in this folder.

        """
        // What the watch and the hand that follows the mouth did, in order.
        let watchRows = log.filter { ["watch_said", "watch_stale", "watch_unclear", "talk_held", "talk_released", "talk_stopped", "place_moved", "screen_back"].contains($0.type) }.map { e -> String in
            let what = ["watch_said": "the watch said", "watch_stale": "the watch was too late with", "watch_unclear": "the watch could not be followed",
                        "talk_held": "the talk waits", "talk_released": "the talk goes on", "talk_stopped": "Stand was stopped", "place_moved": "the place in the talk moved",
                        "screen_back": "the talk's own page went back up"][e.type] ?? e.type
            return "| \(clock(e.t)) | \(what) | \(e.detail ?? "") | \(speaking(at: e.t) ? "yes" : "no") |"
        }
        let watchPart = watchRows.isEmpty ? "" : """

        ## The watch, and the hand that follows the mouth

        | At | What | | Was Stand speaking? |
        |---|---|---|---|
        \(watchRows.joined(separator: "\n"))

        """
        let rows = utterances.map { u -> String in
            if u.kind == "note" {
                let then = u.standWasSpeaking ? "n/a" : u.repliedAfter.map { String(format: "spoke after %.1f s", $0) } ?? "said nothing"
                return "| \(clock(u.start)) | \(u.label) (a note, not spoken) | \(u.standWasSpeaking ? "was talking" : "was not talking") | \(then) | |"
            }
            let stopped = !u.standWasSpeaking ? "was not talking"
                : u.stoppedAfter.map { String(format: "stopped after %.1f s", $0) } ?? "kept talking"
            let replied = u.standWasSpeaking && u.stoppedAfter == nil ? "n/a"
                : u.repliedAfter.map { String(format: "replied after %.1f s", $0) } ?? "no reply"
            let expected = u.asExpected.map { $0 ? "yes: \(u.expect ?? "")" : "NO: it should have been \"\(u.expect ?? "")\"" } ?? ""
            return "| \(clock(u.start)) | \(u.label) | \(stopped) | \(replied) | \(expected) |"
        }
        // What the ear made of each short sound, in order.
        let earRows = log.filter { ["ear_noise", "ear_nothing", "ear_unclear", "ear_call", "ear_overtaken", "ear_slow", "ear_failed", "ear_off"].contains($0.type) }.map { e -> String in
            let what = ["ear_noise": "a noise", "ear_nothing": "words, and no call for Stand", "ear_unclear": "its listening model could not be followed",
                        "ear_call": "someone calling for Stand: Stand was stopped", "ear_overtaken": "a call, but the sound had gone on and stopped Stand by itself",
                        "ear_slow": "a call, heard too late to act on", "ear_failed": "its listening model could not be asked", "ear_off": "the talk goes on without the ear"][e.type] ?? e.type
            return "| \(clock(e.t)) | \(what) | \(e.detail ?? "") |"
        }
        let earPart = earRows.isEmpty ? "" : """

        ## The ear

        | At | What it made of a short sound | |
        |---|---|---|
        \(earRows.joined(separator: "\n"))

        A short sound is one made while Stand was speaking that was loud for less than 0.6 seconds, so that it did not stop Stand by itself.

        """
        let said = utterances.map { "**\($0.label)** at \(clock($0.start)): \"\($0.text)\"\n\n> \($0.standSaid.isEmpty ? "(nothing)" : $0.standSaid)" }

        let report = """
        # North-star rehearsal: \(session.model)

        \(facts.map { "- \($0)" }.joined(separator: "\n"))

        ## What the audience did

        | When | What | Stand | Then | As the script expects? |
        |---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        For a listening noise such as "mm-hm", "kept talking" is the right result. A note is
        text passed to Stand by its human; the audience hears nothing of it.
        \(screenPart)\(watchPart)\(earPart)
        ## What Stand said next

        Text is grouped by when it arrived, which can run slightly ahead of when it was heard.

        \(said.joined(separator: "\n\n"))

        ## Pass test

        Judge these by reading `transcript.md` and listening to `recording.wav`.

        - [ ] Gave the whole talk, every section
        - [ ] Returned to the talk after each interruption, without restarting
        - [ ] Kept talking through the listening noise
        - [ ] Dealt with the off-topic question in a sentence
        - [ ] Said it did not know when asked something outside its background
        - [ ] Finished the talk within about seven minutes
        - [ ] Answered the closing questions and ended cleanly
        - [ ] Invented nothing
        - [ ] The recording is good enough to show someone

        """
        try report.write(to: session.folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

import CoreAudio
import Foundation
import StandCore

/// Checks one piece of the app at a time, with no person needed. Run through the app's own
/// binary, so macOS attributes the microphone and system audio permissions to Stand:
///
///   build/Stand.app/Contents/MacOS/Stand --probe connect     no sound: does the Gemini connection work?
///   build/Stand.app/Contents/MacOS/Stand --probe selfhear    Stand talks through the speakers, nobody else: does it cut itself off?
///   build/Stand.app/Contents/MacOS/Stand --probe otherapp    another app speaks, as a call would: does Stand hear it?
///   build/Stand.app/Contents/MacOS/Stand --probe tap         no voice model: how loud does another app's audio arrive?
///   build/Stand.app/Contents/MacOS/Stand --probe sources     no sound: where the notes come from, with linked repositories checked
///   build/Stand.app/Contents/MacOS/Stand --probe brain "…"   no sound: one question to the brain, timed
///   build/Stand.app/Contents/MacOS/Stand --probe prepare "…" no sound: the brain writes a talk for the meeting described, from the notes and the code
///   build/Stand.app/Contents/MacOS/Stand --probe panel       no sound: the real window for three seconds, driven with nobody at the keyboard (see main.swift)
///
/// --raw turns macOS voice processing (its echo cancellation) off; --no-system-audio turns
/// the system audio tap off. Both exist to show what each contributes.
enum Probe {
    static let modes = ["connect", "selfhear", "otherapp", "tap", "brain", "sources", "doctor", "report", "marker", "spend", "prompter", "prepare", "voice"]

    static func run(mode: String, arguments args: [String]) async throws {
        guard modes.contains(mode) else {
            throw StandError("usage: Stand --probe connect | selfhear | otherapp | tap | sources | doctor | report | spend | marker <run> | prompter <run> | panel | brain \"question\" | prepare \"what the meeting is\" | voice [name …]  [--raw] [--no-system-audio] [--seconds N]")
        }
        if mode == "doctor" {
            print(Doctor.report(root: try Project.root()))
            return
        }
        if mode == "marker" {
            guard let i = args.firstIndex(of: "marker"), args.indices.contains(i + 1) else {
                throw StandError("usage: Stand --probe marker <run folder or room.wav> [--chunk-ms 100]")
            }
            let chunk = args.firstIndex(of: "--chunk-ms").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 20
            // --cuts-in-after 0.6: as in a talk, a sound made while Stand speaks counts only once that much of it was loud.
            let cutsIn = args.firstIndex(of: "--cuts-in-after").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 0
            try marker(path: args[i + 1], chunkSeconds: chunk / 1000, cutsInAfter: cutsIn)
            return
        }
        if mode == "spend" {
            spend(root: try Project.root())
            return
        }
        if mode == "prompter" {
            guard let i = args.firstIndex(of: "prompter"), args.indices.contains(i + 1) else {
                throw StandError("usage: Stand --probe prompter <run folder or transcript.md> [--brief file] [--lull 6]")
            }
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            try await prompter(path: args[i + 1], briefPath: value("--brief"), lull: value("--lull").flatMap { Double($0) } ?? 6)
            return
        }
        if mode == "report" {
            print("made \(try ProblemReport.make(root: Project.root()).path)")
            return
        }
        if mode == "tap" {
            try await tap(voiceProcessing: !args.contains("--raw"), root: Project.root())
            return
        }
        if mode == "sources" {
            try await sources(root: Project.root())
            return
        }
        if mode == "voice" {
            try await voice(arguments: args, root: Project.root())
            return
        }
        if mode == "prepare" {
            // The brain alone, before a meeting: it reads the notes and the code and writes the talk.
            // The lines about the meeting are the next argument, or the file --brief names.
            let root = try Project.root()
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            var request = try value("--brief").map { try String(contentsOf: URL(fileURLWithPath: $0, relativeTo: root), encoding: .utf8) } ?? ""
            if request.isEmpty, let i = args.firstIndex(of: "prepare"), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") { request = args[i + 1] }
            guard !request.isEmpty else { throw StandError("usage: Stand --probe prepare \"what the meeting is, who is there, how long\"  or  --probe prepare --brief file.md") }
            let started = Date()
            let talk = try await Preparation.prepare(root: root, request: request) { what in
                print(String(format: "%5.0f s  … %@", Date().timeIntervalSince(started), what))
            }
            print(String(format: "\nprepared in %.0f s: %@ (\"%@\", %d sections, %d words)\n", talk.seconds, talk.path, talk.title, talk.sections,
                         talk.text.split(whereSeparator: { $0 == " " || $0.isNewline }).count))
            print(talk.text)
            return
        }
        if mode == "brain" {
            // The brain alone: no voice model, no audio. Ask it one question after another and time each answer.
            // --allow says yes whenever it asks its human for something; without it the answer is no.
            let root = try Project.root()
            let library = NotesLibrary(root: root, settings: BrainSettings.load(root: root))
            _ = await LinkedRepos.refresh(root: root, sources: library.sources)
            guard let brain = try BrainFactory.make(root: root) else {
                throw StandError("The brain has nothing to answer from: there are no notes, and brain.json gives it no other way to find things out.")
            }
            guard let i = args.firstIndex(of: "brain") else { throw StandError("usage: Stand --probe brain \"question\" [\"another\" …] [--allow]") }
            let questions = args[(i + 1)...].filter { !$0.hasPrefix("--") }
            guard !questions.isEmpty else { throw StandError("usage: Stand --probe brain \"question\" [\"another\" …] [--allow]") }
            let allow = args.contains("--allow")
            print("brain: \(brain.summary)")
            brain.onActivity = { print("   … \($0)") }
            brain.onAsk = { ask in
                print("   it asks to \(ask.what): \(allow ? "yes" : "no")")
                return allow
            }
            var started = Date()
            if let problem = await brain.start() { print("could not get ready: \(problem)") }
            print(String(format: "ready in %.1f s", Date().timeIntervalSince(started)))
            for question in questions {
                started = Date()
                do {
                    let answer = try await brain.answer(question)
                    print(String(format: "answered in %.1f s: %@", Date().timeIntervalSince(started), answer))
                } catch {
                    print(String(format: "failed after %.1f s: %@", Date().timeIntervalSince(started), "\(error)"))
                }
            }
            brain.stop()
            return
        }
        let voiceProcessing = !args.contains("--raw")
        let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }

        let root = try Project.root()
        let session = try ProbeSession(
            key: Project.geminiKey(root: root),
            instructions: Project.instructions(root: root),
            begin: Project.stageManagerBegin(root: root),
            carryOn: Project.stageManagerCarryOn(root: root))

        session.systemAudio = !args.contains("--no-system-audio")
        switch mode {
        case "connect": try await session.connectOnly(seconds: seconds ?? 12)
        case "selfhear": try await session.selfHear(seconds: seconds ?? 40, voiceProcessing: voiceProcessing)
        default: try await session.otherApp(voiceProcessing: voiceProcessing)
        }
    }
}

extension Probe {
    /// A sample of a voice, or of several: the lines in prompts/voice-sample.md, fetched the
    /// way the panel's "Hear it" fetches them and kept as WAV files. No microphone, and
    /// no sound unless --play is given. About a quarter of a cent a voice.
    ///
    ///   Stand --probe voice Puck Charon [--out folder] [--play]
    ///   Stand --probe voice --all
    ///   Stand --probe voice Puck --silently
    ///
    /// --silently puts the sample through the panel's own player as it arrives, at no
    /// volume, and says how much of it came out. --as-the-panel presses "Hear it" on the
    /// controller the panel uses, at no volume, and checks what follows.
    static func voice(arguments args: [String], root: URL) async throws {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let known = Voices.all(root: root)
        var names = [String]()
        if let i = args.firstIndex(of: "voice") {
            for argument in args[(i + 1)...] {
                if argument.hasPrefix("--") { break }
                names.append(argument)
            }
        }
        if args.contains("--all") { names = known.map(\.name) }
        if names.isEmpty { names = [Voices.usual] }
        let out = value("--out").map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("stand-voices")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let lines = Voices.sampleLines(root: root)
        let words = lines.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        print("\(names.count == 1 ? "one voice" : "\(names.count) voices") of the \(known.count) on the list, saying: \(lines)")

        if args.contains("--as-the-panel") {
            let failures = await hearAsThePanel()
            for failure in failures { print("FAIL  \(failure)") }
            if failures.isEmpty { print("PASS  Hear it: the sample plays as it arrives, stops when another voice is chosen, and is kept for the next press") }
            else { throw StandError("\(failures.count) thing(s) wrong with Hear it.") }
            return
        }
        if args.contains("--silently") {
            for name in names {
                let voice = try Voices.named(name, root: root)
                let player = SpeechPlayer(volume: 0)
                let stretch = player.begin()
                let began = Date()
                let first = FirstSound()
                let pcm = try await Voices.sample(voice.name, root: root) { piece in
                    first.note()
                    player.play(piece, of: stretch)
                }
                let seconds = Double(pcm.count / 2) / GeminiLive.speechRate
                // The sound arrives about as fast as it is spoken, so most of it has played by now. Wait out the rest.
                let left = seconds - (first.at.map { Date().timeIntervalSince($0) } ?? 0)
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64((left + 0.3) * 1_000_000_000)) }
                print(String(format: "%@ first sound after %.1f s, %.1f s of speech, %.1f s of it played (at no volume)",
                             voice.name.padding(toLength: 14, withPad: " ", startingAt: 0),
                             first.at.map { $0.timeIntervalSince(began) } ?? -1, seconds, player.played))
                player.stop()
            }
            return
        }

        // Six at a time, printed in the order asked for.
        var failed = 0
        for start in stride(from: 0, to: names.count, by: 6) {
            let batch = Array(names[start..<min(start + 6, names.count)])
            let results = await withTaskGroup(of: (Int, String).self) { group -> [String] in
                for (offset, name) in batch.enumerated() {
                    group.addTask {
                        let began = Date()
                        do {
                            let voice = try Voices.named(name, root: root)
                            let pcm = try await Voices.sample(voice.name, root: root)
                            let seconds = Double(pcm.count / 2) / GeminiLive.speechRate
                            let file = out.appendingPathComponent("\(voice.name).wav")
                            try PCM.writeWav(pcm, rate: GeminiLive.speechRate, to: file)
                            return (offset, String(format: "%@ %4.1f s of speech (%3.0f words a minute), fetched in %4.1f s  %@",
                                                   voice.name.padding(toLength: 14, withPad: " ", startingAt: 0), seconds,
                                                   seconds > 0 ? Double(words) / seconds * 60 : 0, Date().timeIntervalSince(began), file.path))
                        } catch {
                            return (offset, "FAILED \(name): \(error)")
                        }
                    }
                }
                var lines = [String](repeating: "", count: batch.count)
                for await (offset, line) in group { lines[offset] = line }
                return lines
            }
            for (name, line) in zip(batch, results) {
                print(line)
                if line.hasPrefix("FAILED") { failed += 1; continue }
                if args.contains("--play"), let voice = try? Voices.named(name, root: root) {
                    _ = try? shell("/usr/bin/afplay", [out.appendingPathComponent("\(voice.name).wav").path])
                }
            }
        }
        if failed > 0 { throw StandError("\(failed) of \(names.count) could not be fetched.") }
    }

    /// "Hear it" pressed with nobody at the Mac: the controller the panel uses, its player at
    /// no volume. Charon's voice is chosen and heard; Kore is chosen and Charon again while
    /// Charon's sample is still arriving; then Charon is heard a third time, from what is kept.
    @MainActor
    static func hearAsThePanel() async -> [String] {
        let controller = SessionController(live: false, sampleVolume: 0)
        var failures = [String]()
        func wait(for what: String, atMost seconds: Double, until done: () -> Bool) async -> Double? {
            let began = Date()
            while !done() {
                if Date().timeIntervalSince(began) > seconds {
                    failures.append("\(what): not within \(Int(seconds)) s")
                    return nil
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return Date().timeIntervalSince(began)
        }
        controller.voice = "Charon"
        controller.hearVoice()
        if controller.hearing != "Charon" { failures.append("pressing Hear it did not show that a sample is on its way") }
        if let t = await wait(for: "the first sound", atMost: 6, until: { controller.hearing == nil }) {
            print(String(format: "first sound %.1f s after the press", t))
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        if controller.samplePlayed <= 0 { failures.append("nothing was playing 0.7 s after the first sound") }

        controller.voice = "Kore"
        if controller.samplePlayed != 0 { failures.append("choosing another voice did not stop the sample") }
        controller.voice = "Charon"
        controller.hearVoice()
        if controller.hearing != "Charon" { failures.append("asked for again while still arriving: nothing shows that it is on its way") }
        if let t = await wait(for: "the sample asked for again", atMost: 14, until: { controller.hearing == nil && controller.samplePlayed > 0 }) {
            print(String(format: "asked for again while still arriving: played from the start %.1f s later, once all of it was here", t))
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        controller.hearVoice()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let played = controller.samplePlayed
        if played <= 0 || played > 1.0 { failures.append(String(format: "a kept sample did not start again at once (%.1f s played, 0.4 s after the press)", played)) }
        else { print(String(format: "a third press: playing again from the start at once (%.1f s played, 0.4 s after the press)", played)) }
        if let message = controller.message { failures.append("the panel says: \(message)") }
        return failures
    }

    /// When the first piece of a sample arrived.
    private final class FirstSound: @unchecked Sendable {
        private let lock = NSLock()
        private var when: Date?
        var at: Date? { lock.withLock { when } }
        func note() { lock.withLock { if when == nil { when = Date() } } }
    }

    /// Plays the transcript of a meeting that has already happened to the prompter, a
    /// stretch at a time, and prints the sheet it would have kept at each point, with how
    /// long each took. No voice model and no sound, so it costs nothing on the voice side.
    /// It shows what the prompter would have put in front of Stand, and when.
    static func prompter(path: String, briefPath: String?, lull: Double) async throws {
        let root = try Project.root()
        var url = URL(fileURLWithPath: path, relativeTo: root)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue { url = url.appendingPathComponent("transcript.md") }
        let brief = try briefPath.map { try String(contentsOf: URL(fileURLWithPath: $0, relativeTo: root), encoding: .utf8) } ?? ""
        // "- 1:23 **Room:** what was said" and "- 1:25 **Stand:** what it said"; everything else in the file is commentary.
        var said = [(t: Double, text: String)]()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "-", parts[2] == "**Room:**" || parts[2] == "**Stand:**" else { continue }
            let clock = parts[1].split(separator: ":").compactMap { Double($0) }
            guard clock.count == 2 else { continue }
            said.append((clock[0] * 60 + clock[1], "\(parts[2] == "**Stand:**" ? "Stand" : "In the meeting"): \(parts[3])"))
        }
        guard !said.isEmpty else { throw StandError("\(url.path) has no lines of a meeting in it.") }
        guard let brain = try BrainFactory.makePrompter(root: root) else { throw StandError("There is no prompter: the brain is not the Claude Code CLI on this Mac.") }
        print("prompter: \(brain.summary)")
        var started = Date()
        if let problem = await brain.start() { throw StandError("The prompter could not get ready: \(problem)") }
        print(String(format: "ready in %.1f s", Date().timeIntervalSince(started)))
        var sheet: PrompterSheet?
        var passed = [String]()
        var fresh = [String]()
        for (i, line) in said.enumerated() {
            fresh.append(line.text)
            // The session asks when enough has been said, or when the room has gone quiet.
            // A transcript gives each line the moment it arrived, so a long gap before the
            // next line is taken for a few seconds of quiet after this one.
            let gap = i + 1 < said.count ? said[i + 1].t - line.t : Double.infinity
            let quiet = gap >= lull
            guard fresh.reduce(0, { $0 + $1.count }) >= 160 || quiet else { continue }
            started = Date()
            let reply = try await brain.answer(PrompterSheet.request(root: root, brief: brief, last: sheet, passed: passed,
                                                                     said: fresh.joined(separator: "\n"), quietFor: quiet ? 3 : 0))
            let seconds = Date().timeIntervalSince(started)
            let clock = String(format: "%d:%02d", Int(line.t) / 60, Int(line.t) % 60)
            guard let new = PrompterSheet(reply: reply) else {
                print("\n--- up to \(clock), \(String(format: "%.1f", seconds)) s: not a sheet: \(reply)")
                continue
            }
            fresh.removeAll()
            print("\n--- up to \(clock)\(quiet ? ", in a quiet moment" : ""), written in \(String(format: "%.1f", seconds)) s")
            if new.inPlay != sheet?.inPlay { print("  IN PLAY: \(new.inPlay.isEmpty ? "nothing" : new.inPlay)") }
            if !new.worthSaying.isEmpty {
                print("  WORTH SAYING: \(new.worthSaying)")
                passed.append(new.worthSaying)
            }
            if new.owed != (sheet?.owed ?? "") { print("  OWED: \(new.owed.isEmpty ? "nothing" : new.owed)") }
            print("  SO FAR: \(new.soFar)")
            sheet = new
        }
        brain.stop()
    }

    /// What the sessions kept here cost, by kind of run: how many there were, how long and
    /// how many turns of the model one takes, and what one costs. It is what to look at
    /// before starting a batch of runs.
    static func spend(root: URL) {
        let total = Spend.total(root: root)
        var groups = [String: [Spend.Session]]()
        for session in total.sessions { groups[session.script ?? "(the app, or a run with no report)", default: []].append(session) }
        print("kind of run                          runs  minutes  turns   each   an hour")
        for (name, sessions) in groups.sorted(by: { $0.value.reduce(0) { $0 + $1.dollars } > $1.value.reduce(0) { $0 + $1.dollars } }) {
            let n = Double(sessions.count)
            let minutes = sessions.reduce(0) { $0 + $1.minutes } / n, dollars = sessions.reduce(0) { $0 + $1.dollars } / n
            let turns = Double(sessions.reduce(0) { $0 + $1.turns }) / n
            print(String(format: "%@ %4d  %7.1f  %5.0f  $%.2f    $%.2f", name.padding(toLength: 36, withPad: " ", startingAt: 0), sessions.count,
                         minutes, turns, dollars, minutes > 0 ? dollars / minutes * 60 : 0))
        }
        print(String(format: "\n%d sessions, %.0f minutes, %d turns of the model: about $%.2f, which is $%.2f an hour and %.1f cents a turn",
                     total.sessions.count, total.minutes, total.turns, total.dollars, total.minutes > 0 ? total.dollars / total.minutes * 60 : 0,
                     total.turns > 0 ? total.dollars / Double(total.turns) * 100 : 0))
    }

    /// Plays a recording of a room through the speech marker, with no session and no
    /// sound, and prints the utterances it would have handed to the voice service. Given
    /// a run folder it reads that run's room.wav, and takes from its events when Stand's
    /// own voice was coming out of the speakers. `chunkSeconds` is the size the sound is
    /// fed in: 0.02 as the scripted audience delivers it, 0.1 as a real microphone does.
    /// The two should mark the same utterances.
    static func marker(path: String, chunkSeconds: Double, cutsInAfter: Double = 0) throws {
        var url = URL(fileURLWithPath: path)
        var audible = [(from: Double, to: Double)]()
        var isFolder: ObjCBool = false
        var length: Double?
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            let events = ((try? String(contentsOf: url.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            var start: Double?
            var unheard = 0.0
            for event in events {
                let t = (event["t"] as? Double ?? 0) / 1000
                if event["type"] as? String == "stand_start" { start = t }
                // Trying the rule that lets short sounds pass: in the run itself Stand was
                // stopped at once, so its voice is taken to have gone on for as long as it
                // had speech ready, which the cut-off note says.
                if cutsInAfter > 0, event["type"] as? String == "cut_off_note", let detail = event["detail"] as? String {
                    unheard = Double(detail.prefix { $0.isNumber || $0 == "." }) ?? 0
                }
                if event["type"] as? String == "stand_stop", let from = start {
                    audible.append((from, ((event["at"] as? Double).map { $0 / 1000 } ?? t) + unheard))
                    start = nil
                    unheard = 0
                }
                length = t
            }
            if let from = start, let length { audible.append((from, length)) }
            url = url.appendingPathComponent("room.wav")
        }
        let wav = try PCM.readWav(url)
        guard wav.rate == GeminiLive.microphoneRate else { throw StandError("\(url.lastPathComponent) is at \(Int(wav.rate)) Hz; the room is recorded at 16000.") }
        let seconds = PCM.seconds(wav.pcm, rate: wav.rate)
        // The recording starts when the session first heard the room, a moment after the session's own clock.
        let offset = max(0, (length ?? seconds) - seconds)
        var marker = SpeechMarker()
        marker.cutsInAfter = cutsInAfter
        var passed = [(from: Double, to: Double, loud: Double)]()
        var utterances = [(from: Double, to: Double?, leadIn: Double, overStand: Bool)]()
        var loudest = 0.0
        let chunkBytes = max(2, Int(wav.rate * chunkSeconds) * 2)
        var position = 0
        while position < wav.pcm.count {
            let end = min(position + chunkBytes, wav.pcm.count)
            let chunk = wav.pcm.subdata(in: (wav.pcm.startIndex + position)..<(wav.pcm.startIndex + end))
            position = end
            let t = offset + Double(position / 2) / wav.rate
            for event in marker.take(chunk, endingAt: t, standAudible: { moment in audible.contains { $0.from <= moment && moment <= $0.to + 0.2 } }) {
                switch event {
                case .started(let at, let leadIn):
                    utterances.append((at, nil, PCM.seconds(leadIn, rate: wav.rate), audible.contains { $0.from <= at && at <= $0.to + 0.2 }))
                case .stopped(let at):
                    if !utterances.isEmpty { utterances[utterances.count - 1].to = at }
                case .passedOver(let from, let to, let loud):
                    passed.append((from, to, loud))
                case .loud, .sound:
                    break
                }
            }
            loudest = max(loudest, marker.bar)
        }
        print(String(format: "%@: %.0f s of room sound, fed %.0f ms at a time; Stand audible for %.0f s; the bar reached %.0f",
                     url.deletingLastPathComponent().lastPathComponent, seconds, chunkSeconds * 1000, audible.reduce(0) { $0 + $1.to - $1.from }, loudest))
        for u in utterances {
            // An utterance is marked a moment after its first sound, and that moment is in the lead-in that goes with it.
            print(String(format: "  marked at %6.2f, ended %@, with %.2f s from before it%@", u.from, u.to.map { String(format: "%6.2f", $0) } ?? "  never",
                         u.leadIn, u.overStand ? ", while Stand was speaking" : ""))
        }
        for p in passed {
            print(String(format: "  let pass at %6.2f: %.2f s of sound while Stand was speaking, %.2f s of it loud", p.from, p.to - p.from, p.loud))
        }
        print("  \(utterances.count) utterances\(cutsInAfter > 0 ? String(format: ", %d short sounds let pass (a sound counts once %.1f s of it was loud)", passed.count, cutsInAfter) : "")")
    }

    /// Where the notes come from, with no voice model and no brain: every linked repository
    /// is checked, then every source is read, and what was found is printed.
    static func sources(root: URL) async throws {
        // --add <folder or repository address> and --remove <number> change brain.json
        // the way the panel's Notes list does, then everything is checked and listed as usual.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--add"), args.indices.contains(i + 1) {
            let source = try BrainSettings.source(from: args[i + 1], root: root)
            try BrainSettings.add(source: source, root: root)
            print("added: \(source.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        }
        if let i = args.firstIndex(of: "--remove"), args.indices.contains(i + 1), let number = Int(args[i + 1]) {
            try BrainSettings.removeSource(at: number - 1, root: root)
            print("removed source \(number)")
        }
        let settings = BrainSettings.load(root: root)
        let library = NotesLibrary(root: root, settings: settings)
        print("settings: \(BrainSettings.file(root: root).path)")
        for problem in library.problems { print("PROBLEM  \(problem)") }

        let started = Date()
        let statuses = await LinkedRepos.refresh(root: root, sources: library.sources)
        if !statuses.isEmpty {
            print(String(format: "linked repositories, checked in %.1f s:", Date().timeIntervalSince(started)))
            for status in statuses { print("  \(status.error == nil ? "ok " : "FAIL") \(status.line())\(status.changed ? " (new copy)" : "")") }
        }

        let read = Date()
        let notes = library.current()
        print(String(format: "sources, read in %.0f ms: %@, %d characters of notes, %@", Date().timeIntervalSince(read) * 1000,
                     notes.summary, notes.totalCharacters, notes.isEmpty ? "nothing to look up" : !notes.hasDocuments ? "searched in place" : notes.fits(within: settings.docsStuffLimitChars) ? "sent whole with each question" : "too many to send whole: read through tools"))
        for (source, count) in zip(library.sources, notes.counts) {
            let number = source.index.map { "\($0 + 1). " } ?? "   "
            print("  \(number)\(count.name): \(count.files) note(s), \(count.characters) characters\(count.others > 0 ? ", and \(count.others) other file(s) the brain can search" : ""), from \(source.repo == nil ? source.folder.path : source.place)")
        }
        for line in notes.leftOut { print("  left out: \(line)") }
        if CommandLine.arguments.contains("--list") {
            for file in notes.files { print("    \(file.path) (\(file.text.count))") }
        }
        if !notes.map.isEmpty { print("what the folders hold besides the notes, as the brain is told:\n\(notes.map)") }
    }

    /// The audio inputs alone, with no voice model. Another program plays a recording whose
    /// level is known, and this reports how loud it arrived through the system audio tap
    /// and through the microphone. Both captures are kept as WAV files.
    static func tap(voiceProcessing: Bool, root: URL) async throws {
        let sentence = "Excuse me, Stand. Can you tell me where your name comes from?"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let folder = root.appendingPathComponent("runs/\(formatter.string(from: Date()))-probe-tap")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let aiff = folder.appendingPathComponent("played.aiff"), wav = folder.appendingPathComponent("played.wav")
        try shell("/usr/bin/say", ["-o", aiff.path, sentence])
        try shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        let played = try PCM.readWav(wav).pcm

        guard await AudioIO.microphoneAllowed() else {
            throw StandError("Microphone access was refused. Allow it for Stand in System Settings > Privacy & Security > Microphone.")
        }
        let audio = AudioIO()
        let lock = NSLock()
        var system = Data(), microphone = Data()
        audio.onSystemOnly = { pcm in lock.withLock { system.append(pcm) } }
        audio.onMicrophoneOnly = { pcm in lock.withLock { microphone.append(pcm) } }
        try audio.start(AudioIO.Options(voiceProcessing: voiceProcessing, systemAudio: true))
        print(audio.description)
        print(outputVolume())

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let (quietSystem, quietMicrophone) = lock.withLock { () -> (Data, Data) in
            defer { system.removeAll(); microphone.removeAll() }
            return (system, microphone)
        }
        _ = audio.takeSystemRawPeak()
        print("\nanother program plays: \"\(sentence)\"")
        let playedFrom = Date()
        try shell("/usr/bin/afplay", [aiff.path])
        try await Task.sleep(nanoseconds: 300_000_000)
        let window = Date().timeIntervalSince(playedFrom)
        let rawPeak = audio.takeSystemRawPeak()
        let (heardSystem, heardMicrophone) = lock.withLock { (system, microphone) }
        audio.stop()
        try PCM.writeWav(heardSystem, rate: GeminiLive.microphoneRate, to: folder.appendingPathComponent("system.wav"))
        try PCM.writeWav(heardMicrophone, rate: GeminiLive.microphoneRate, to: folder.appendingPathComponent("microphone.wav"))

        func peak(_ pcm: Data) -> Int {
            pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) } }
        }
        func line(_ what: String, _ pcm: Data) -> String {
            let p = peak(pcm), reference = peak(played)
            let below = p > 0 && reference > 0 ? String(format: "%.0f dB below the recording", 20 * log10(Double(reference) / Double(p))) : "silent"
            return String(format: "%@ peak %5d, average %6.1f  (%@)", what.padding(toLength: 34, withPad: " ", startingAt: 0), p, PCM.rms(pcm), below)
        }
        print(String(format: "\nthe recording itself:              peak %5d, average %6.1f", peak(played), PCM.rms(played)))
        print(line("system audio tap, while it played:", heardSystem))
        print(String(format: "  the tap's own loudest sample before conversion: %.4f of full scale", rawPeak))
        print(line("microphone, while it played:", heardMicrophone))
        print(line("system audio tap, quiet before:", quietSystem))
        print(line("microphone, quiet before:", quietMicrophone))
        print("\ncaptures: \(folder.path)")

        // Two ways this has gone wrong: no audio at all (permission refused), and the wrong
        // buffer read, which arrived three times too long and thirty decibels too quiet.
        let captured = PCM.seconds(heardSystem, rate: GeminiLive.microphoneRate)
        let level = peak(heardSystem) > 0 ? 20 * log10(Double(peak(played)) / Double(peak(heardSystem))) : Double.infinity
        if abs(captured - window) > 0.25 * window {
            print(String(format: "\nFAIL  the tap delivered %.1f s of audio in %.1f s, so it is being read wrongly", captured, window))
        } else if level > 20 {
            print("\nFAIL  another app's audio arrives too quiet to be heard")
        } else {
            print(String(format: "\nPASS  another app's audio arrives %.0f dB below its own level (voice processing %@)", level, voiceProcessing ? "on" : "off"))
        }
    }

    /// The default output device's name and volume, as the system reports them.
    static func outputVolume() -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return "output device: unknown"
        }
        func number(_ selector: AudioObjectPropertySelector) -> Float32? {
            for element in [kAudioObjectPropertyElementMain, 1] {
                var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                var value: Float32 = 0
                var s = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &s, &value) == noErr { return value }
            }
            return nil
        }
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0) }
        let scalar = number(kAudioDevicePropertyVolumeScalar).map { String(format: "%.0f%%", $0 * 100) } ?? "?"
        let decibels = number(kAudioDevicePropertyVolumeDecibels).map { String(format: "%.1f dB", $0) } ?? "? dB"
        return "output device: \(name), volume \(scalar) (\(decibels))"
    }

    @discardableResult
    static func shell(_ path: String, _ arguments: [String]) throws -> String {
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
}

/// One probe run: the connection, the audio, and a tally of what happened.
final class ProbeSession {
    private let key, instructions, begin, carryOn: String
    private let audio = AudioIO()
    private var live: GeminiLive!
    private let lock = NSLock()
    private let started = Date()

    // The tally. Guarded by `lock`: events arrive on background queues.
    private var speechSeconds = 0.0
    private var firstSpeechAt: Double?
    private var interruptions = 0
    private var heard = ""
    private var said = ""
    private var floorOpen = false
    private var playUntil = 0.0 // seconds since start at which queued speech runs out
    private var turnDone = false
    private var nudged = false
    private var closedReason: String?
    private var playsAudio = false
    var systemAudio = true

    init(key: String, instructions: String, begin: String, carryOn: String) {
        self.key = key
        self.instructions = instructions
        self.begin = begin
        self.carryOn = carryOn
    }

    private var now: Double { Date().timeIntervalSince(started) }
    private func stamp(_ text: String) { print(String(format: "%5.1fs  %@", now, text)) }

    private func connect() async throws {
        live = GeminiLive { [weak self] event in self?.handle(event) }
        let t = Date()
        try await live.connect(apiKey: key, instructions: instructions)
        stamp("connected to gemini-3.8-live in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .audio(let pcm):
            let t = now
            lock.withLock {
                if firstSpeechAt == nil { firstSpeechAt = t }
                let duration = Double(pcm.count / 2) / GeminiLive.speechRate
                speechSeconds += duration
                playUntil = max(t, playUntil) + duration
                turnDone = false
                nudged = false
            }
            if playsAudio { audio.play(pcm) }
        case .heard(let text): lock.withLock { heard += text }
        case .said(let text): lock.withLock { said += text }
        case .interrupted:
            let t = now
            lock.withLock { interruptions += 1; playUntil = min(playUntil, t) }
            if playsAudio { audio.flush() }
            stamp("Stand stopped mid-speech")
        case .turnComplete: lock.withLock { turnDone = true }
        case .floorOpened:
            lock.withLock { floorOpen = true }
            stamp("Stand signalled that the floor is open")
        case .keptQuiet: break // the probes pass no notes
        case .askHuman: break // and offer no human to ask
        case .lookUp(let id, _):
            live.respond(lookUp: id, answer: "NOT FOUND. The probe has no brain.")
        case .reconnected(let why):
            stamp("reconnected: \(why)")
        case .usage(let promptText, let promptAudio, let responseAudio, _, let thoughts):
            stamp("the service counted \(promptText) text and \(promptAudio) audio tokens given, \(responseAudio) audio tokens produced, \(thoughts) of thinking")
        case .closed(let reason):
            lock.withLock { closedReason = reason }
            stamp("connection closed: \(reason)")
        }
    }

    /// Keeps a talk moving the way the rig's stage manager does: when a turn has finished
    /// and its speech has played, say "carry on", unless Stand has opened the floor.
    private func runFor(_ seconds: Double, keepTalking: Bool) async throws {
        let end = now + seconds
        while now < end, lock.withLock({ closedReason == nil }) {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard keepTalking else { continue }
            let t = now
            let shouldNudge = lock.withLock { () -> Bool in
                guard turnDone, !nudged, !floorOpen, t > playUntil + 0.2 else { return false }
                nudged = true
                return true
            }
            if shouldNudge { live.nudge(carryOn) }
        }
    }

    private func startAudio(voiceProcessing: Bool) async throws {
        guard await AudioIO.microphoneAllowed() else {
            throw StandError("Microphone access was refused. Allow it for the app running this command in System Settings > Privacy & Security > Microphone.")
        }
        playsAudio = true
        audio.onHeard = { [weak self] pcm in self?.live.sendMicrophone(pcm) }
        try audio.start(AudioIO.Options(voiceProcessing: voiceProcessing, systemAudio: systemAudio))
        stamp(audio.description)
    }

    private func finish() {
        audio.stop()
        live.close()
    }

    // MARK: connect

    func connectOnly(seconds: Double) async throws {
        try await connect()
        let asked = now
        live.instruct(begin)
        try await runFor(seconds, keepTalking: false)
        finish()
        let (first, speech, text) = lock.withLock { (firstSpeechAt, speechSeconds, said) }
        print("\nfirst speech after \(first.map { String(format: "%.1f s", $0 - asked) } ?? "never"); \(String(format: "%.1f", speech)) s of speech received")
        print("Stand said: \(text.trimmingCharacters(in: .whitespaces))")
        print(speech > 2 && !text.isEmpty ? "\nPASS  the native connection works" : "\nFAIL  no speech came back")
    }

    // MARK: selfhear

    func selfHear(seconds: Double, voiceProcessing: Bool) async throws {
        print("Stand will talk through the speakers for \(Int(seconds)) seconds. Keep the room quiet: anything it \"hears\" should be nothing.\n")
        try await connect()
        try await startAudio(voiceProcessing: voiceProcessing)
        live.instruct(begin)
        try await runFor(seconds, keepTalking: true)
        finish()
        let (cuts, room, speech) = lock.withLock { (interruptions, heard, speechSeconds) }
        print("\nStand spoke for \(String(format: "%.0f", speech)) s; it cut itself off \(cuts) time(s)")
        print("what it thought it heard: \(room.isEmpty ? "(nothing)" : room.trimmingCharacters(in: .whitespaces))")
        if speech < 5 {
            print("\nFAIL  Stand barely spoke, so this says nothing about echo")
        } else if cuts == 0 && room.trimmingCharacters(in: .whitespaces).isEmpty {
            print("\nPASS  Stand does not hear itself (voice processing \(voiceProcessing ? "on" : "off"), system audio tap \(systemAudio ? "on" : "off"))")
        } else {
            print("\nFAIL  Stand hears itself, or the room was not quiet (voice processing \(voiceProcessing ? "on" : "off"), system audio tap \(systemAudio ? "on" : "off"))")
        }
    }

    // MARK: otherapp

    func otherApp(voiceProcessing: Bool) async throws {
        let question = "Excuse me, Stand. Can you tell me where your name comes from?"
        print("Another program will speak through the speakers, the way a call's audio does. Keep the room quiet.\n")
        try await connect()
        try await startAudio(voiceProcessing: voiceProcessing)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        stamp("another app says: \"\(question)\"")
        _ = try await Subprocess.run("/usr/bin/say", [question], timeout: 30)
        let asked = now
        stamp("it finished speaking")
        try await runFor(12, keepTalking: false)
        let peaks = audio.takePeaks()
        finish()

        print("\nloudest sample while it ran, out of 32767: microphone \(peaks.microphone), system audio \(peaks.system)")
        let (room, reply, first) = lock.withLock { (heard, said, firstSpeechAt) }
        let heardIt = room.lowercased().contains("name")
        print("\nStand heard: \(room.isEmpty ? "(nothing)" : room.trimmingCharacters(in: .whitespaces))")
        print("Stand replied: \(reply.isEmpty ? "(nothing)" : reply.trimmingCharacters(in: .whitespaces))")
        if let first { print("its reply began \(String(format: "%.1f", first - asked)) s after the question ended") }
        if heardIt && !reply.isEmpty {
            print("\nPASS  Stand hears audio played by another app (voice processing \(voiceProcessing ? "on" : "off"), system audio tap \(systemAudio ? "on" : "off"))")
        } else if !heardIt {
            print("\nFAIL  Stand did not hear the other app, so it would not hear a call on this Mac (voice processing \(voiceProcessing ? "on" : "off"), system audio tap \(systemAudio ? "on" : "off"))")
        } else {
            print("\nFAIL  Stand heard the question but did not reply")
        }
    }
}

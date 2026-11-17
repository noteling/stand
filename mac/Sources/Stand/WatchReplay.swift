import Foundation
import StandCore

/// Plays a talk that has already happened to the brain's watch (`Watch`), and prints what
/// it would have said at each moment it would have been asked, with how long each answer
/// took. No voice model and no sound, so it costs nothing on the voice side.
///
/// What the run did stays as it was: the watch's answers are printed, not acted on. So
/// this shows whether it would have seen a fault, and when, and whether it would have
/// left alone what was fine.
///
/// A run made since the watch was built keeps every piece of Stand's speech with the
/// moment it arrived and the moment its sound began, and is replayed exactly. An older
/// run is rebuilt from its transcript: Stand's words are spread over the time it spoke,
/// which is near enough to see what the watch makes of it.
enum WatchReplay {
    private struct Recorded {
        let t: Double
        let type: String
        let detail: String
        let at: Double?
    }

    private struct Piece {
        var arrived: Double
        var startsAt: Double
        var text: String
    }

    static func run(arguments args: [String], root: URL) async throws {
        guard let i = args.firstIndex(of: "watch"), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else {
            throw StandError("usage: Stand --probe watch <run folder> [--talk file.md] [--every 5] [--from seconds] [--to seconds] [--show-asks]")
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let folder = URL(fileURLWithPath: args[i + 1], relativeTo: root)
        let every = value("--every").flatMap { Double($0) } ?? 5
        let showAsks = args.contains("--show-asks")

        var events = [Recorded]()
        for line in try String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = json["type"] as? String,
                  let t = json["t"] as? Double else { continue }
            events.append(Recorded(t: t / 1000, type: type, detail: json["detail"] as? String ?? "", at: (json["at"] as? Double).map { $0 / 1000 }))
        }
        guard let opened = events.first(where: { $0.type == "opened" }), let began = events.first(where: { $0.type == "begin" }) else {
            throw StandError("\(folder.path) is not the run of a talk.")
        }
        // "gemini-3.8-live, talks/introducing-stand.md, no brief, brain: …"
        let named = opened.detail.split(separator: ",").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let talk = value("--talk") ?? named
        let plan = try String(contentsOf: URL(fileURLWithPath: talk, relativeTo: root), encoding: .utf8)
        let sections = TalkPlan.sections(in: plan)
        guard sections.count >= 2 else { throw StandError("\(talk) has no numbered sections for a stage manager to keep a place in.") }
        let end = events.last?.t ?? began.t
        let from = max(began.t, value("--from").flatMap { Double($0) } ?? began.t)
        let to = min(end, value("--to").flatMap { Double($0) } ?? end)

        // The room's lines, and Stand's when the run kept no pieces, from the transcript.
        var roomLines = [(t: Double, text: String)]()
        var standLines = [(t: Double, text: String)]()
        for line in ((try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "-" else { continue }
            let clock = parts[1].split(separator: ":").compactMap { Double($0) }
            guard clock.count == 2 else { continue }
            if parts[2] == "**Room:**" { roomLines.append((clock[0] * 60 + clock[1], parts[3])) }
            if parts[2] == "**Stand:**" { standLines.append((clock[0] * 60 + clock[1], parts[3])) }
        }

        var pieces = events.filter { $0.type == "piece" }.map { Piece(arrived: $0.t, startsAt: $0.at ?? $0.t, text: $0.detail) }
        let exact = !pieces.isEmpty
        if !exact {
            // Stand's words spread over the time it spoke, a few words to a piece. The model
            // makes speech several times faster than it is spoken, so a piece is taken to
            // have arrived an eighth of the way to its own sound.
            let starts = events.filter { $0.type == "stand_start" }.map(\.t)
            for line in standLines {
                let start = starts.first { $0 >= line.t - 1.5 && $0 <= line.t + 4 } ?? line.t
                var offset = 0
                var group = [Substring]()
                func flush() {
                    guard !group.isEmpty else { return }
                    let text = group.joined(separator: " ") + " "
                    let startsAt = start + Double(offset) / 17.5
                    pieces.append(Piece(arrived: start + (startsAt - start) / 8, startsAt: startsAt, text: text))
                    offset += text.count
                    group.removeAll()
                }
                for word in line.text.split(separator: " ") {
                    group.append(word)
                    if group.count == 4 { flush() }
                }
                flush()
            }
            pieces.sort { $0.startsAt < $1.startsAt }
        }
        // What was cut off was never heard: at each interruption, the pieces whose sound had not begun are gone.
        let cuts = events.filter { $0.type == "interrupted" }.map(\.t)
        func known(at t: Double) -> [Piece] {
            pieces.filter { piece in
                piece.arrived <= t && !cuts.contains { cut in cut <= t && piece.arrived <= cut && piece.startsAt > cut - 0.4 }
            }
        }

        // When the room was speaking. A stop is marked 0.6 seconds after the last sound.
        var spells = [(from: Double, to: Double)]()
        for event in events where event.type == "room_start" || event.type == "room_stop" {
            if event.type == "room_start" { spells.append((event.t, .infinity)) } else if !spells.isEmpty, spells[spells.count - 1].to == .infinity {
                spells[spells.count - 1].to = event.t
            }
        }
        func roomSpeaking(at t: Double) -> Bool { spells.contains { $0.from <= t && t < $0.to } }
        func lastRoomVoice(at t: Double) -> Double {
            spells.filter { $0.from <= t }.map { $0.to <= t ? $0.to - 0.6 : t }.max() ?? -.infinity
        }

        func number(in detail: String, after word: String = "section ") -> String? {
            guard let range = detail.range(of: word) else { return nil }
            let digits = detail[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }

        func state(at t: Double) -> (state: WatchState, heardTo: Double, screenChanges: Int, handOvers: Int) {
            var state = WatchState()
            state.clock = t
            var place: String?
            var handedAt = began.t
            var stopped = false
            var onScreen: (section: String, showing: String, why: WatchState.Why, at: Double, came: Bool)?
            var askedAt = -Double.infinity
            var lookingUp = 0
            var held: Double?
            var screenChanges = 0, handOvers = 0
            var standSpeaking = false
            var standStopped = -Double.infinity
            for event in events where event.t <= t {
                switch event.type {
                case "begin", "nudge":
                    handOvers += 1
                    if let section = number(in: event.detail) {
                        if section != place { handedAt = event.t }
                        place = section
                    }
                    stopped = false
                    if let now = onScreen, now.why != .talk { onScreen?.why = .talk }
                case "place_moved":
                    if let section = number(in: event.detail) {
                        place = section
                        handedAt = event.t
                    }
                case "interrupted": stopped = true
                case "page_asked": askedAt = event.t
                case "screen_shown", "screen_failed":
                    screenChanges += 1
                    guard let section = number(in: event.detail) else { break }
                    // for section 2: "The product we intend to replace" in docs/product-direction.md, 0.2 s, seen by the page itself
                    let quoted = event.detail.split(separator: "\"", omittingEmptySubsequences: false)
                    onScreen = (section, quoted.count >= 3 ? String(quoted[1]) : "", event.t - askedAt < 3 ? .asked : .talk, event.t, event.type == "screen_shown")
                case "scroll_answer":
                    screenChanges += 1
                    if onScreen != nil {
                        onScreen?.why = .scrolled
                        onScreen?.at = event.t
                    }
                case "screen_scrolled": screenChanges += 1
                case "lookup": lookingUp += 1
                case "lookup_answer": lookingUp = max(0, lookingUp - 1)
                case "talk_held": held = event.t
                case "talk_released": held = nil
                case "stand_start": standSpeaking = true
                case "stand_stop":
                    standSpeaking = false
                    standStopped = event.at ?? event.t
                default: break
                }
            }
            let have = known(at: t)
            if let place, let section = sections.first(where: { $0.number == place }) {
                state.section = place
                state.sectionTitle = section.title
                state.handedAt = handedAt
                state.stoppedInIt = stopped
                let made = section.pointsMade(in: have.filter { $0.startsAt >= handedAt && $0.startsAt <= t }.map(\.text).joined(separator: " "))
                state.points = made.count
                state.pointsHeard = made.filter { $0 }.count
            }
            if let onScreen, let section = sections.first(where: { $0.number == onScreen.section }) {
                state.screen = WatchState.OnScreen(section: section.number, title: section.title, showing: onScreen.showing, why: onScreen.why,
                                                   seconds: t - onScreen.at, came: onScreen.came)
            }
            var parts = [(at: Double, stand: Bool, text: String)]()
            for line in roomLines where line.t > t - 60 && line.t + 0.8 <= t { parts.append((line.t, false, line.text)) }
            for piece in have where piece.startsAt > t - 60 && piece.startsAt <= t { parts.append((piece.startsAt, true, piece.text)) }
            for part in parts.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
                if part.stand, let last = state.said.last, last.stand {
                    state.said[state.said.count - 1].text += part.text
                } else {
                    state.said.append(WatchState.Line(t: part.at, stand: part.stand, text: part.text))
                }
            }
            state.said = state.said.map { WatchState.Line(t: $0.t, stand: $0.stand, text: $0.text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")) }
            state.coming = have.filter { $0.startsAt > t }.map(\.text).joined().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")
            state.standSpeaking = standSpeaking
            state.roomSpeaking = roomSpeaking(at: t)
            state.quietFor = standSpeaking ? 0 : max(0, t - max(lastRoomVoice(at: t), standStopped))
            state.heldFor = held.map { t - $0 }
            state.lookingUp = lookingUp > 0
            return (state, have.last { $0.startsAt <= t }?.startsAt ?? -.infinity, screenChanges, handOvers)
        }

        guard let watch = try BrainFactory.makeWatch(root: root, talk: talk) else {
            throw StandError("There is no watch: the brain is not the Claude Code CLI on this Mac.")
        }
        print("watch: \(watch.summary)")
        print("\(folder.lastPathComponent): \(talk), \(sections.count) sections, \(Watch.clock(from)) to \(Watch.clock(to)), "
            + (exact ? "replayed exactly" : "rebuilt from its transcript (this run kept no pieces of Stand's speech)"))
        var started = Date()
        if let problem = await watch.start() { throw StandError("The watch could not get ready: \(problem)") }
        print(String(format: "ready in %.1f s\n", Date().timeIntervalSince(started)))

        var askedAt = -Double.infinity, sawRoomAt = -Double.infinity, sawHeardTo = -Double.infinity
        var sawScreen = -1, sawHandOvers = -1
        var asks = 0, acted = 0, slowest = 0.0, total = 0.0
        var t = from
        while t <= to {
            defer { t += 0.25 }
            guard !roomSpeaking(at: t), t - askedAt > 1 else { continue }
            let now = state(at: t)
            let voice = lastRoomVoice(at: t)
            var afterSomeoneSpoke = false
            if voice > sawRoomAt, voice > began.t {
                // As the session does it: once their words have had a moment to reach the transcript.
                guard t - voice >= 1.2 else { continue }
                afterSomeoneSpoke = true
            } else {
                guard t - askedAt >= every, now.heardTo > sawHeardTo + 2 || now.screenChanges != sawScreen || now.handOvers != sawHandOvers || now.state.heldFor != nil else { continue }
            }
            let ask = try Watch.request(root: root, state: now.state, afterSomeoneSpoke: afterSomeoneSpoke)
            askedAt = t
            sawRoomAt = voice
            sawHeardTo = now.heardTo
            sawScreen = now.screenChanges
            sawHandOvers = now.handOvers
            started = Date()
            let reply = (try? await watch.answer(ask)) ?? "(no answer)"
            let seconds = Date().timeIntervalSince(started)
            asks += 1
            total += seconds
            slowest = max(slowest, seconds)
            let commands = Watch.commands(reply: reply)
            let said = commands.map { $0.isEmpty ? "NOTHING" : $0.map(\.description).joined(separator: ", ") } ?? "not understood: \(reply.split(whereSeparator: \.isNewline).joined(separator: " "))"
            if let commands, !commands.isEmpty { acted += 1 }
            let screen = now.state.screen.map { "screen \($0.section)\($0.why == .asked ? " (asked for)" : $0.why == .scrolled ? " (scrolled)" : "")" } ?? "no screen"
            let line = String(format: "%@  %@  place %@, %@  ->  %@  (%.1f s)", Watch.clock(t), afterSomeoneSpoke ? "someone spoke " : "a few seconds ",
                              now.state.section ?? "-", screen, said, seconds)
            print(commands?.isEmpty == false ? line + "   <<<" : line)
            if showAsks || commands?.isEmpty == false {
                print(ask.split(separator: "\n", omittingEmptySubsequences: false).map { "      | \($0)" }.joined(separator: "\n"))
            }
        }
        watch.stop()
        print(String(format: "\nasked %d times, answered with something other than NOTHING %d times; %.1f s on average, %.1f s at the slowest", asks, acted,
                     asks > 0 ? total / Double(asks) : 0, slowest))
    }
}

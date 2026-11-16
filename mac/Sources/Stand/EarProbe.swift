import Foundation
import StandCore

/// `Stand --probe ear`: the ear by itself, with no session and no sound.
///
///   --probe ear <run folder or room.wav> [--listen] [--chunk-ms 100] [--cuts-in-after 0.6]
///       Plays a recording of a room through the speech marker as a talk has it, and for
///       each short sound the marker weighs says what the ear makes of it: words or a noise
///       by the Mac's own classifier and, with --listen, a call for Stand or not by the
///       listening model. Nothing is acted on: what the run did stays as it was.
///
///   --probe ear --sounds <list> [--listen] [--times 3]
///       A list of sounds, each with what it should be taken for, and how many came out
///       right. A line is `CALL` or `NOTHING`, then either `say <voice> <words>` (made
///       with the Mac's voices, without a sound) or `clip <wav> <from> <to> <what it is>`
///       (a stretch of a kept recording, by its own clock). A clip whose recording is not
///       on this Mac is left out.
///
/// The classifier costs nothing. --listen asks the listening model once for each sound
/// the classifier took for words: about a hundredth of a cent each.
enum EarProbe {
    static func run(arguments args: [String], root: URL) async throws {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let listens = args.contains("--listen")
        var ear: Ear?
        if listens {
            let settings = StandSession.Settings()
            guard let made = Ear.make(root: root, key: try Project.geminiKey(root: root), model: settings.earModel) else {
                throw StandError("The ear's rules are not there: prompts/ear.md and prompts/ear-request.txt.")
            }
            ear = made
            print("ear: \(made.summary)")
        } else {
            print("ear: the Mac's own sound classifier only (--listen also asks the listening model)")
        }
        _ = Ear.classify(PCM.silence(seconds: 0.6, rate: GeminiLive.microphoneRate)) // loads the classifier's model
        if let list = value("--sounds") {
            try await sounds(list: list, root: root, ear: ear, times: value("--times").flatMap { Int($0) } ?? 1, shows: args.contains("--all"))
            return
        }
        guard let i = args.firstIndex(of: "ear"), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else {
            throw StandError("usage: Stand --probe ear <run folder or room.wav> [--listen] [--chunk-ms 100]  or  --probe ear --sounds <list> [--listen] [--times 3]")
        }
        try await replay(path: args[i + 1], ear: ear, chunkSeconds: (value("--chunk-ms").flatMap { Double($0) } ?? 100) / 1000,
                         cutsInAfter: value("--cuts-in-after").flatMap { Double($0) } ?? StandSession.Settings().talkCutsInAfter)
    }

    /// What became of one short sound.
    private struct Row {
        var from: Double
        var offeredAt: Double
        var loud: Double
        var seconds: Double
        var kind: Ear.Kind?
        var verdict: Ear.Verdict?
        var listened = 0.0
        var ended = "still being weighed when the recording ended"
    }

    private static func replay(path: String, ear: Ear?, chunkSeconds: Double, cutsInAfter: Double) async throws {
        let settings = StandSession.Settings()
        let room = try Probe.recordedRoom(path: path, speechReady: cutsInAfter > 0)
        var marker = SpeechMarker()
        marker.cutsInAfter = cutsInAfter
        marker.offersAfter = settings.earOffersAfter
        var rows = [Int: Row]()
        var order = [Int]()
        let chunkBytes = max(2, Int(room.rate * chunkSeconds) * 2)
        var position = 0
        while position < room.pcm.count {
            let end = min(position + chunkBytes, room.pcm.count)
            let chunk = room.pcm.subdata(in: (room.pcm.startIndex + position)..<(room.pcm.startIndex + end))
            position = end
            let t = room.offset + Double(position / 2) / room.rate
            for event in marker.take(chunk, endingAt: t, standAudible: { moment in room.audible.contains { $0.from <= moment && moment <= $0.to + 0.2 } }) {
                switch event {
                case .weighed(let id, let sound, let from, let to, let loud):
                    // Offered again when more of it came: the later, longer one is what counts.
                    var row = Row(from: from, offeredAt: to + settings.earOffersAfter, loud: loud, seconds: PCM.seconds(sound, rate: room.rate))
                    row.kind = Ear.classify(sound)
                    if let ear, (row.kind?.speech ?? 1) >= settings.earWordAtLeast {
                        let (verdict, seconds) = await ear.listen(to: sound)
                        row.verdict = verdict
                        row.listened = seconds
                    }
                    // A call heard in the first part stands, whatever the longer one is taken for.
                    if let before = rows[id], before.verdict == .call, row.verdict != .call { break }
                    if rows[id] == nil { order.append(id) }
                    rows[id] = row
                case .passedOver(let id, _, _, let loud):
                    rows[id]?.ended = String(format: "let pass, %.2f s of it loud", loud)
                case .started(let at, _):
                    // The sound that was being weighed went on, and came to enough by itself.
                    if let id = order.last, rows[id]?.ended.hasPrefix("still") == true {
                        rows[id]?.ended = String(format: "it went on, and stopped Stand by itself at %.2f", at)
                    }
                case .loud, .sound, .stopped:
                    break
                }
            }
        }
        print(String(format: "%@: %.0f s of room sound, fed %.0f ms at a time; a sound stops Stand by itself once %.1f s of it was loud",
                     room.url.deletingLastPathComponent().lastPathComponent, PCM.seconds(room.pcm, rate: room.rate), chunkSeconds * 1000, cutsInAfter))
        var noises = 0, words = 0, calls = 0
        for id in order {
            guard let row = rows[id] else { continue }
            let isWords = (row.kind?.speech ?? 1) >= settings.earWordAtLeast
            if isWords { words += 1 } else { noises += 1 }
            var line = String(format: "  %7.2f  %.2f s loud  %@ (%@)", row.from, row.loud, isWords ? "words" : "a noise",
                              row.kind?.described ?? "the classifier could not be run")
            if let verdict = row.verdict {
                switch verdict {
                case .call:
                    calls += 1
                    // As a session has it: offered, classified, listened to, and then acted on.
                    let stops = row.offeredAt - row.from + (row.kind?.seconds ?? 0) + row.listened
                    line += String(format: "  CALL in %.1f s: Stand would stop %.1f s after the sound began", row.listened, stops)
                case .nothing: line += String(format: "  NOTHING in %.1f s", row.listened)
                case .unclear(let said): line += String(format: "  unclear (\"%@\") in %.1f s", said, row.listened)
                case .failed(let why): line += "  could not be asked: \(why)"
                }
            }
            print(line + "  [without an ear: \(row.ended)]")
        }
        print("  \(order.count) short sounds weighed: \(noises) taken for a noise, \(words) for words" + (ear != nil ? ", \(calls) of those for a call" : ""))
    }

    private static func sounds(list: String, root: URL, ear: Ear?, times: Int, shows: Bool) async throws {
        let settings = StandSession.Settings()
        let rate = GeminiLive.microphoneRate
        let text = try String(contentsOf: URL(fileURLWithPath: list, relativeTo: root), encoding: .utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stand-ear-\(getpid())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var right = 0, wrong = 0, falseCalls = 0, missed = 0, leftOut = 0, gated = 0
        var took = [Double]()
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 3, !words[0].hasPrefix("#") else { continue }
            let want = words[0].uppercased()
            guard want == "CALL" || want == "NOTHING" else { throw StandError("\(list): a line starts with CALL or NOTHING, not \"\(words[0])\".") }
            var pcm: Data
            let label: String
            if words[1] == "say", words.count >= 4 {
                let say = words[3...].joined(separator: " ")
                let wav = folder.appendingPathComponent(UUID().uuidString + ".wav")
                _ = try await Subprocess.run("/usr/bin/say", ["-v", words[2], "-o", wav.path, "--data-format=LEI16@\(Int(rate))", say], timeout: 30)
                // Framed as the marker hands a sound over: a little quiet before it, and the quiet that ends it.
                pcm = PCM.silence(seconds: 0.16, rate: rate) + (try PCM.readWav(wav).pcm) + PCM.silence(seconds: 0.25, rate: rate)
                label = "\(words[2]): \(say)"
            } else if words[1] == "clip", words.count >= 5, let from = Double(words[3]), let to = Double(words[4]) {
                let url = URL(fileURLWithPath: words[2], relativeTo: root)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    leftOut += 1
                    continue
                }
                let wav = try PCM.readWav(url)
                let a = max(0, Int(from * wav.rate)) * 2, b = min(wav.pcm.count, Int(to * wav.rate) * 2)
                guard wav.rate == rate, a < b else { throw StandError("\(words[2]): nothing at 16 kHz between \(from) and \(to) seconds.") }
                pcm = wav.pcm.subdata(in: (wav.pcm.startIndex + a)..<(wav.pcm.startIndex + b))
                label = "recorded: " + words[5...].joined(separator: " ")
            } else {
                throw StandError("\(list): cannot read the line \"\(line)\".")
            }
            let kind = Ear.classify(pcm)
            let isWords = (kind?.speech ?? 1) >= settings.earWordAtLeast
            var got = [String]()
            if !isWords {
                gated += 1
                got = ["NOTHING"]
            } else if let ear {
                for _ in 0..<max(1, times) {
                    let (verdict, seconds) = await ear.listen(to: pcm)
                    took.append(seconds)
                    switch verdict {
                    case .call: got.append("CALL")
                    case .nothing: got.append("NOTHING")
                    case .unclear(let said): got.append("unclear (\(said))")
                    case .failed(let why): got.append("failed (\(why))")
                    }
                }
            } else {
                got = ["words"]
            }
            // Without the listening model only the classifier is judged: a call has to come out as words.
            let verdicts = ear == nil ? got.map { $0 == "words" ? want : $0 } : got
            for verdict in verdicts {
                if verdict == want { right += 1 } else {
                    wrong += 1
                    if verdict == "CALL" { falseCalls += 1 } else if want == "CALL" { missed += 1 }
                }
            }
            if shows || verdicts.contains(where: { $0 != want }) {
                print(String(format: "  %@ %@  %.2f s  should be %@, was %@  (%@)", verdicts.allSatisfy { $0 == want } ? "  " : "!!", label.padding(toLength: 44, withPad: " ", startingAt: 0),
                             PCM.seconds(pcm, rate: rate), want, got.joined(separator: ","), kind?.described ?? "no classifier"))
            }
        }
        took.sort()
        print("  \(right) right, \(wrong) wrong: \(falseCalls) taken for a call that were none, \(missed) calls not heard"
            + (ear == nil ? " as words" : "") + "; \(gated) taken for a noise by the classifier"
            + (leftOut > 0 ? "; \(leftOut) recorded sounds left out, their recordings are not on this Mac" : ""))
        if !took.isEmpty {
            print(String(format: "  the listening model answered in %.2f s at the median, %.2f s for nine in ten, %.2f s at the slowest, over %d asks",
                         took[took.count / 2], took[min(took.count - 1, took.count * 9 / 10)], took[took.count - 1], took.count))
        }
    }
}

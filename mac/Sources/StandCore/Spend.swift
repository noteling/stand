import Foundation

/// What sessions cost.
///
/// The voice service bills every turn of the model for everything in its context at
/// that moment: the instructions, as text, and all the speech of the session so far, its
/// own and the room's, as audio at 25 tokens a second. Then it bills what the model says.
/// So a session does not cost so much a minute. It costs so much a turn, and a turn costs
/// more the longer the session has been going.
///
/// Until 2026-11-12 the sessions estimated themselves at so much a minute of sound in
/// and out, which is how the price list reads, and came out about four times too low:
/// $5.57 against the $20 that 264 sessions had actually used up. Rebuilt turn by turn
/// from the same sessions' event logs, as here, they come to $21.29.
///
/// The service says what it counted, one message for each turn the model completed
/// (`Reported`). A session that has those counts is priced from them. An older one is
/// rebuilt from its events (`rebuilt`), which is an estimate: it takes the instructions
/// for fewer tokens than the service counts (2,800 against about 3,800, which include
/// the tools) and counts more turns than the model completed, and over the 264 sessions
/// the two errors nearly cancel. Do not correct one without the other.
public enum Spend {
    // gemini-3.8-live, dollars a token (aistudio.google.com/docs/pricing, read 2026-11-12).
    static let textIn = 0.75e-6, audioIn = 3.00e-6, audioOut = 12.00e-6, textOut = 4.50e-6
    /// Speech in the model's context: what the service reported at the end of 24 sessions fits 25 tokens a second.
    static let audioTokensPerSecond = 25.0
    /// 10,700 characters of instructions were reported as 2,437 text tokens.
    static let charactersPerToken = 4.4
    /// The model thinks a little before each turn, and that is billed as text it wrote: 25 to 142 tokens were reported.
    static let thoughtsPerTurn = 70.0

    /// What the service itself said it counted, added up over a session.
    public struct Reported {
        public var messages = 0
        public var promptText = 0, promptAudio = 0, responseAudio = 0, responseText = 0, thoughts = 0
        public init() {}

        /// What that comes to if each message is one turn's count.
        public var dollars: Double {
            Double(promptText) * textIn + Double(promptAudio) * audioIn + Double(responseAudio) * audioOut
                + Double(responseText + thoughts) * textOut
        }

        var json: [String: Any] {
            ["messages": messages, "promptTextTokens": promptText, "promptAudioTokens": promptAudio, "responseAudioTokens": responseAudio,
             "responseTextTokens": responseText, "thoughtsTokens": thoughts, "dollarsIfOneMessageATurn": (dollars * 10000).rounded() / 10000]
        }
    }

    /// What a session cost, rebuilt from its events: `turns` is how many times the model
    /// was given a turn, each billed for the context as it stood.
    public static func rebuilt(events: [StandSession.Event], instructionsCharacters: Int) -> (dollars: Double, turns: Int) {
        var text = Double(instructionsCharacters) / charactersPerToken // text tokens in the context
        var speech = 0.0 // seconds of speech in the context
        var said = 0.0 // seconds of speech the model produced
        var input = 0.0
        var turns = 0
        var standFrom: Double?, roomFrom: Double?
        func turn() {
            turns += 1
            input += text * textIn + speech * audioTokensPerSecond * audioIn
        }
        for event in events {
            switch event.type {
            case "stand_start":
                standFrom = event.t
            case "stand_stop":
                if let from = standFrom {
                    let spoke = max(0, (event.at ?? event.t) - from)
                    speech += spoke
                    said += spoke
                    standFrom = nil
                }
            case "room_start":
                roomFrom = event.t
            case "room_stop":
                // Someone finished speaking, which is recorded 0.6 seconds after their last sound: the model takes a turn.
                if let from = roomFrom {
                    speech += max(0, event.t - 0.6 - from)
                    roomFrom = nil
                    turn()
                    text += 15
                }
            case "cut_off_note":
                // What it had produced and sent but nobody heard is in its context too, and was paid for as speech.
                let unheard = Double((event.detail ?? "").components(separatedBy: " s unheard").first ?? "") ?? 0
                speech += unheard
                said += unheard
            default:
                break
            }
            // A message from the stage manager, or an answer from the brain: another turn.
            if ["begin", "nudge", "note_landed", "lookup_answer", "lookup_slow", "cut_off_note"].contains(event.type) {
                turn()
                text += 60 + Double((event.detail ?? "").count) / charactersPerToken
            }
        }
        let output = said * audioTokensPerSecond * audioOut + Double(turns) * thoughtsPerTurn * textOut
        return (input + output, turns)
    }

    /// One kept session.
    public struct Session {
        public let name: String
        /// The rehearsal script it ran, from its report, if it has one.
        public let script: String?
        public let minutes: Double
        public let turns: Int
        public let dollars: Double
    }

    public struct Total {
        public let sessions: [Session]
        public var minutes: Double { sessions.reduce(0) { $0 + $1.minutes } }
        public var turns: Int { sessions.reduce(0) { $0 + $1.turns } }
        public var dollars: Double { sessions.reduce(0) { $0 + $1.dollars } }

        /// "240 sessions so far, about $19.38", or nil when there are none.
        public var line: String? {
            guard !sessions.isEmpty else { return nil }
            return String(format: "%d %@ so far, about $%.2f", sessions.count, sessions.count == 1 ? "session" : "sessions", dollars)
        }
    }

    /// Every session kept under `runs`, each at what it cost: its own figure if it was
    /// made by this way of counting, and rebuilt from its events if it is older.
    public static func total(root: URL) -> Total {
        let runs = root.appendingPathComponent("runs")
        let manager = FileManager.default
        var sessions = [Session]()
        for name in ((try? manager.contentsOfDirectory(atPath: runs.path)) ?? []).sorted() {
            let folder = runs.appendingPathComponent(name)
            guard let log = try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8) else { continue }
            let events = log.split(separator: "\n").compactMap { line -> StandSession.Event? in
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = json["type"] as? String, let t = json["t"] as? Double else { return nil }
                return StandSession.Event(t: t / 1000, type: type, at: (json["at"] as? Double).map { $0 / 1000 }, detail: json["detail"] as? String)
            }
            guard let last = events.last else { continue }
            let summary = (try? Data(contentsOf: folder.appendingPathComponent("summary.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let size = (try? manager.attributesOfItem(atPath: folder.appendingPathComponent("instructions.md").path))?[.size] as? Int
            let again = rebuilt(events: events, instructionsCharacters: size ?? 11_000)
            let own = summary["costModel"] as? Int == 2 ? summary["estimatedCostUsd"] as? Double : nil
            var script: String?
            if let report = try? String(contentsOf: folder.appendingPathComponent("report.md"), encoding: .utf8),
               let found = report.prefix(400).range(of: #"Script: [\w.-]+"#, options: .regularExpression) {
                script = String(report[found].dropFirst("Script: ".count))
            }
            sessions.append(Session(name: name, script: script, minutes: last.t / 60, turns: again.turns, dollars: own ?? again.dollars))
        }
        return Total(sessions: sessions)
    }
}

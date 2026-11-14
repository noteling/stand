import Foundation

/// The sheet a second brain keeps in front of Stand during a discussion, the way a prompter
/// keeps a line ready for an actor. That brain follows the meeting through the transcript
/// and knows the notes; Stand hears the room and does the speaking. The sheet carries what
/// Stand cannot hold or cannot see: the thread of the meeting before the last few minutes,
/// the facts from the notes that bear on what is being discussed, what Stand has promised,
/// and now and then one point worth making, which Stand may make or let go.
///
/// The rules for the brain are in prompts/brain-prompter.md. This is the form of its
/// reply, and of what is asked of it, shared by the session and by `Stand --probe prompter`.
public struct PrompterSheet: Equatable {
    public var soFar = "", inPlay = "", worthSaying = "", owed = ""

    /// Reads the four labelled lines of a reply. A part that says "nothing" is empty. Nil
    /// when the reply is not a sheet at all.
    public init?(reply: String) {
        var found = 0
        for line in reply.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            for (label, path) in [("SO FAR:", \PrompterSheet.soFar), ("IN PLAY:", \.inPlay), ("WORTH SAYING:", \.worthSaying), ("OWED:", \.owed)]
            where line.uppercased().hasPrefix(label) {
                var value = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")
                let bare = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if bare == "nothing" || bare == "none" || bare.hasPrefix("nothing ") { value = "" }
                self[keyPath: path] = value
                found += 1
            }
        }
        guard found >= 2 else { return nil }
    }

    /// The four lines, as the brain is shown them again next time.
    public var lines: String {
        "SO FAR: \(soFar.isEmpty ? "nothing" : soFar)\nIN PLAY: \(inPlay.isEmpty ? "nothing" : inPlay)\n"
            + "WORTH SAYING: \(worthSaying.isEmpty ? "nothing" : worthSaying)\nOWED: \(owed.isEmpty ? "nothing" : owed)"
    }

    /// What Stand is shown: everything but the point worth making, which travels separately,
    /// as a note does, because acting on it takes a turn of Stand's own.
    public var forStand: String {
        var parts = [String]()
        if !soFar.isEmpty { parts.append("The meeting so far: \(soFar)") }
        // Not "facts that bear on what is being discussed now": under that label Stand took a
        // fact for a point to make, and reminded a meeting of its head count unasked.
        if !inPlay.isEmpty { parts.append("Facts to have ready: \(inPlay)") }
        if !owed.isEmpty { parts.append("What you said you would come back to: \(owed)") }
        return parts.joined(separator: " ")
    }

    /// The message to the brain that asks for the sheet to be brought up to date.
    /// `passed` is every point already given to Stand as worth saying: the brain must not give one twice.
    /// `quietFor` is how long nobody has spoken, which is how it can tell a question left hanging.
    public static func request(root: URL, brief: String, last: PrompterSheet?, passed: [String], said: String, quietFor: Double = 0) throws -> String {
        try Project.read("prompts/brain-prompter-request.txt", root: root)
            .replacingOccurrences(of: "{brief}", with: brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : brief)
            .replacingOccurrences(of: "{sheet}", with: last?.lines ?? "(none yet: the meeting has just begun)")
            .replacingOccurrences(of: "{passed}", with: passed.isEmpty ? "(nothing yet)" : passed.map { "- \($0)" }.joined(separator: "\n"))
            .replacingOccurrences(of: "{said}", with: said.isEmpty ? "(nothing more)" : said)
            .replacingOccurrences(of: "{quiet}", with: quietFor >= 2 ? String(format: "Nobody has spoken for about %d seconds now.", Int(quietFor.rounded()))
                                                                       : "Someone is speaking, or has only just stopped.")
    }
}

import Foundation

/// Getting a talk ready before the meeting. Stand's human writes a few lines about the
/// meeting; the brain reads the notes and the code it has been given and writes the talk:
/// a plan of points for Stand to make, and the facts worth having ready for questions.
///
/// The plan is a file under talks/, like the one that introduces Stand, so its human can
/// read it, change it, and choose it in the panel. Stand speaks from it in its own words.
public enum Preparation {
    /// How long the brain may take. It reads documents and code, which is minutes, not seconds.
    public static let limit = 900.0

    public struct Talk: Sendable {
        /// "talks/introducing-the-ledger.md", from the project folder.
        public let path: String
        public let title: String
        public let text: String
        public let seconds: Double
        /// The sections of the talk, and how long it says they take in all.
        public var sections: Int { text.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.dropFirst(3).first?.isNumber == true }.count }
    }

    /// Writes a talk for the meeting `request` describes and saves it under talks/.
    /// `onActivity` is told what the brain is doing while it works.
    public static func prepare(root: URL, request: String, onActivity: (@Sendable (String) -> Void)? = nil) async throws -> Talk {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            throw StandError("Write a line or two about the meeting first: what Stand should present, to whom, and for how long.")
        }
        let library = NotesLibrary(root: root, settings: BrainSettings.load(root: root))
        _ = await LinkedRepos.refresh(root: root, sources: library.sources, waitingAtMost: 20)
        guard !library.current().isEmpty else {
            throw StandError("There is nothing to prepare a talk from. Under Notes, add the folder or the repository that holds what the talk is about.")
        }
        guard let brain = try BrainFactory.makePreparer(root: root) else {
            throw StandError(BrainFactory.missing(root: root) ?? "Preparing a talk needs the Claude Code CLI as the brain, and this Mac is set to use something else.")
        }
        defer { brain.stop() }
        brain.onActivity = onActivity
        let day = DateFormatter()
        day.dateFormat = "EEEE d MMMM yyyy"
        day.locale = Locale(identifier: "en_GB")
        let ask = try Project.read("prompts/brain-prepare-request.txt", root: root)
            .replacingOccurrences(of: "{date}", with: day.string(from: Date()))
            .replacingOccurrences(of: "{request}", with: request)
        let started = Date()
        let reply = try await brain.answer(ask)
        guard let text = plan(in: reply) else {
            let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.hasPrefix("NOT ENOUGH") {
                let why = said.dropFirst("NOT ENOUGH".count).trimmingCharacters(in: CharacterSet(charactersIn: ".: \n"))
                throw StandError("Stand's brain could not prepare this talk from what it has\(why.isEmpty ? "." : ": \(why)")")
            }
            throw StandError("Stand's brain did not come back with a talk. It said: \(said.prefix(300))")
        }
        let title = String(text.split(separator: "\n").first ?? "").replacingOccurrences(of: "# Talk:", with: "").trimmingCharacters(in: .whitespaces)
        let path = try save(text, title: title, root: root)
        return Talk(path: path, title: title, text: text, seconds: Date().timeIntervalSince(started))
    }

    /// The plan in what the brain replied: from the "# Talk:" line on, without anything it put around it.
    static func plan(in reply: String) -> String? {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { $0.hasPrefix("# Talk:") }) else { return nil }
        lines = Array(lines[first...])
        // A model sometimes wraps a file in a code fence.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("```") { lines.removeLast() }
        guard lines.contains(where: { $0.hasPrefix("## ") }) else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Saves the plan under talks/ with a name made from its title. A talk that is already
    /// there is never written over: its human may have changed it. The new one gets a number.
    static func save(_ text: String, title: String, root: URL) throws -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber, character.isASCII { slug.append(character) } else if slug.last != "-" { slug.append("-") }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
        if slug.isEmpty { slug = "talk" }
        let folder = root.appendingPathComponent("talks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = "\(slug).md"
        var n = 2
        while FileManager.default.fileExists(atPath: Project.location(of: "talks/\(name)", root: root).path) {
            name = "\(slug)-\(n).md"
            n += 1
        }
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "talks/\(name)"
    }
}

/// A talk's plan, cut into the sections it numbers ("## 3. Why voice (about 60 seconds)"),
/// so that the stage manager can hand them to Stand one at a time and keep the place itself.
public enum TalkPlan {
    public struct Section: Sendable {
        /// "3", as the plan numbers it.
        public let number: String
        /// "Why voice", without the time the plan allots.
        public let title: String
        /// "about 60 seconds", when the heading says so.
        public let time: String?
        /// The points under the heading, as the plan has them.
        public let points: String
    }

    /// The numbered sections, in order. A part with a heading that is not numbered, such
    /// as the facts kept ready for questions, is not a section of the talk.
    public static func sections(in plan: String) -> [Section] {
        var found = [Section]()
        var open: (number: String, heading: String, lines: [String])?
        func close() {
            guard let section = open else { return }
            open = nil
            var title = section.heading
            var time: String?
            if title.hasSuffix(")"), let bracket = title.lastIndex(of: "(") {
                time = String(title[title.index(after: bracket)...].dropLast())
                title = title[..<bracket].trimmingCharacters(in: .whitespaces)
            }
            let points = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !points.isEmpty { found.append(Section(number: section.number, title: title, time: time, points: points)) }
        }
        for line in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("#") else {
                open?.lines.append(String(line))
                continue
            }
            close()
            let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            let number = heading.prefix { $0.isNumber }
            if !number.isEmpty, heading.dropFirst(number.count).hasPrefix(".") {
                open = (String(number), heading.dropFirst(number.count + 1).trimmingCharacters(in: .whitespaces), [])
            }
        }
        close()
        return found
    }
}

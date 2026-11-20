import Foundation

public struct StandError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Stand's plain-text files: who Stand is, the talk, how it behaves, and the API key.
///
/// There are two ways they are laid out.
/// - In the repo, where the app is built: everything is in the repo folder, and the Mac app
///   and the JavaScript rig read the same files.
/// - On any other Mac, from an app that was packaged for it (mac/scripts/package.sh): what
///   Stand is and how it behaves comes inside the app (`defaults`), and what belongs to the
///   person (keys, brain.json, the brief, notes, runs) is in a folder of their own, `~/Stand`.
///   A file put in that folder at the same path wins over the one inside the app, which is
///   how a prompt is changed on such a Mac without rebuilding.
public enum Project {
    private static func holdsStand(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("identity/stand.md").path)
    }

    /// The text files that come inside a packaged app, or nil in a build made for the repo.
    public static let defaults: URL? = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("defaults"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("identity/stand.md").path) else { return nil }
        return folder
    }()

    /// The person's own folder on a Mac that has no repo: `~/Stand`, or what STAND_HOME names.
    public static var home: URL {
        if let named = ProcessInfo.processInfo.environment["STAND_HOME"], !named.isEmpty {
            return URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Stand", isDirectory: true)
    }

    /// The folder holding identity/, talks/ and prompts/. In order: the STAND_PROJECT_ROOT
    /// setting, the nearest folder at or above the current one that has identity/stand.md,
    /// then the repo path the build script recorded in the app's Info.plist.
    public static func root(from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["STAND_PROJECT_ROOT"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override)
            if holdsStand(dir) { return dir }
            throw StandError("STAND_PROJECT_ROOT is \(override), which has no identity/stand.md.")
        }
        var dir = start.standardizedFileURL
        while true {
            if holdsStand(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        if let recorded = Bundle.main.object(forInfoDictionaryKey: "StandProjectRoot") as? String {
            let dir = URL(fileURLWithPath: recorded)
            if holdsStand(dir) { return dir }
        }
        // A packaged app, away from the repo: the person's own folder, made on first use.
        if let defaults {
            let manager = FileManager.default
            let folder = home
            try manager.createDirectory(at: folder.appendingPathComponent("context"), withIntermediateDirectories: true)
            for seed in ["brain.json", "context/README.md", "README.md"] {
                let target = folder.appendingPathComponent(seed)
                if !manager.fileExists(atPath: target.path) { try? manager.copyItem(at: defaults.appendingPathComponent(seed), to: target) }
            }
            // Said to be a folder in so many words: a path such as "context" is worked out
            // against it, and against a URL that does not end in a slash it would land beside it.
            return URL(fileURLWithPath: folder.path, isDirectory: true)
        }
        throw StandError("Could not find Stand's text files (identity/stand.md). Run from inside the Stand repo, or set STAND_PROJECT_ROOT.")
    }

    /// Where a file is read from: the project folder if it has it, else the copy inside the app.
    static func location(of relative: String, root: URL) -> URL {
        let own = root.appendingPathComponent(relative)
        if let defaults, !FileManager.default.fileExists(atPath: own.path) { return defaults.appendingPathComponent(relative) }
        return own
    }

    /// The same, for the app: where a talk's file is, to open it.
    public static func file(_ relative: String, root: URL) -> URL { location(of: relative, root: root) }

    /// The talks there are to give, as paths such as "talks/introducing-stand.md".
    public static func talks(root: URL) -> [String] {
        var names = Set<String>()
        for folder in [root, defaults].compactMap({ $0?.appendingPathComponent("talks") }) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".md") { names.insert(name) }
        }
        return names.sorted().map { "talks/\($0)" }
    }

    /// Writes one setting to .env in the project folder, which only this person can read.
    public static func save(setting name: String, value: String, root: URL) throws {
        let url = root.appendingPathComponent(".env")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(name)=") }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines.append("\(name)=\(value.trimmingCharacters(in: .whitespacesAndNewlines))")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A setting from the environment, or from .env at the repo root.
    public static func setting(_ name: String, root: URL) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        guard let text = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals].trimmingCharacters(in: .whitespaces) == name {
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    public static func geminiKey(root: URL) throws -> String {
        guard let key = setting("GEMINI_API_KEY", root: root) ?? setting("GOOGLE_API_KEY", root: root) else {
            throw StandError("There is no Gemini API key yet. Paste one into the panel, or put GEMINI_API_KEY in \(root.appendingPathComponent(".env").path).")
        }
        return key
    }

    /// STAND_SWAP names other files to read in place of the usual ones, for one run:
    /// "prompts/attendee.md=poc/heckler/variants/attendee-b.md,…". It is how two wordings
    /// of a prompt are compared in runs that happen at the same time.
    private static let swaps: [String: String] = {
        var swaps = [String: String]()
        for pair in (ProcessInfo.processInfo.environment["STAND_SWAP"] ?? "").split(separator: ",") {
            let sides = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if sides.count == 2 { swaps[sides[0]] = sides[1] }
        }
        return swaps
    }()

    static func read(_ relative: String, root: URL) throws -> String {
        let relative = swaps[relative] ?? relative
        do {
            return try String(contentsOf: location(of: relative, root: root), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw StandError("Could not read \(relative): \(error.localizedDescription)")
        }
    }

    /// Pushes every Markdown heading one level down, so a file can sit under a top-level
    /// section of the combined instructions.
    static func demote(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("#") ? "#" + $0 : String($0) }
            .joined(separator: "\n")
    }

    /// What the stage manager says to Stand to start the talk, and to keep it going.
    public static func stageManagerBegin(root: URL) throws -> String { try read("prompts/stage-manager-begin.txt", root: root) }
    public static func stageManagerCarryOn(root: URL) throws -> String { try read("prompts/stage-manager-carry-on.txt", root: root) }

    /// The note Stand's human wrote for the next meeting: `brief.md` at the repo root, which
    /// the panel edits. Empty when there is none.
    public static func brief(root: URL) -> String {
        ((try? String(contentsOf: root.appendingPathComponent("brief.md"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func saveBrief(_ text: String, root: URL) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try (trimmed.isEmpty ? "" : trimmed + "\n").write(to: root.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
    }

    /// The instructions Stand runs on. poc/src/prompt.js assembles the same for Gemini, without
    /// the brief and the lookup section. `brief` is the human's note about this meeting, if they wrote one.
    /// `canLookUp` adds how to use the brain; leave it off when there is no brain to ask.
    /// An empty `talk` means Stand gives none and takes part in a discussion: another role
    /// (prompts/attendee.md) and another character, the same Stand.
    /// `notesOutline` is the brain's own sentence or two on what the notes cover, when it
    /// gave one: Stand cannot see the notes, and looks things up more readily when it knows
    /// what is in them.
    /// `canAskHuman` adds how to put a question to its human; leave it off when nobody is there to answer.
    /// `screen` says the talk is given with its pages on a screen (`Screen`). Without one,
    /// the lines of the talk that name pages are left out: Stand should not read of pages nobody will see.
    public static func instructions(root: URL, talk: String = "talks/introducing-stand.md", brief: String = "", canLookUp: Bool = false,
                                    notesOutline: String? = nil, canAskHuman: Bool = false, screen: Bool = false,
                                    identity: EmployeeVoiceIdentity? = nil) throws -> String {
        if let identity {
            guard talk.isEmpty else { throw StandError("Synthetics mode currently joins a discussion; choose Attend, without a prepared Stand talk.") }
            return try read("prompts/synthetics-voice.md", root: root)
                .replacingOccurrences(of: "{name}", with: identity.name)
                .replacingOccurrences(of: "{persona}", with: identity.persona)
                .replacingOccurrences(of: "{aliases}", with: identity.aliases.joined(separator: ", "))
        }
        let outline = try notesOutline.map { "\n\n" + (try read("prompts/notes-outline.md", root: root)).replacingOccurrences(of: "{outline}", with: $0) } ?? ""
        if talk.isEmpty {
            // What Stand does about a question it cannot answer depends on whether it has a brain to ask.
            let beyond = try read(canLookUp ? "prompts/attend-beyond-look-it-up.txt" : "prompts/attend-beyond.txt", root: root)
            var parts = try [
                read("prompts/attendee.md", root: root).replacingOccurrences(of: "{beyond}", with: beyond),
                "# Your character\n\n" + demote(read("identity/character-attendee.md", root: root)),
                "# Who you are\n\n" + demote(read("identity/stand.md", root: root)),
            ]
            let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
            if !brief.isEmpty {
                parts.append(try read("prompts/attend-brief.md", root: root).replacingOccurrences(of: "{brief}", with: demote(brief)))
            }
            if canLookUp { parts.append(try read("prompts/attend-look-it-up.md", root: root) + outline) }
            if canAskHuman { parts.append(try read("prompts/voice-ask-your-human.md", root: root)) }
            return parts.joined(separator: "\n\n")
        }
        let plan = try read(talk, root: root)
        var parts = try [
            read("prompts/presenter.md", root: root),
            "# Your character\n\n" + demote(read("identity/character.md", root: root)),
            "# Who you are\n\n" + demote(read("identity/stand.md", root: root)),
            "# The talk\n\n" + demote(screen ? plan : TalkPlan.withoutPages(plan)),
        ]
        if screen {
            // What Stand does about a question on what a page says depends, as with any question, on whether it has a brain to ask.
            let about = try read(canLookUp ? "prompts/voice-screen-look-it-up.txt" : "prompts/voice-screen-no-notes.txt", root: root)
            parts.append(try read("prompts/voice-screen.md", root: root).replacingOccurrences(of: "{about}", with: about.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty {
            // Its headings go below this section's own, so the note cannot pass for a section of the instructions.
            parts.append(try read("prompts/voice-brief.md", root: root).replacingOccurrences(of: "{brief}", with: demote(brief)))
        }
        parts.append(try read("prompts/provider-gemini.md", root: root))
        if canLookUp { parts.append(try read("prompts/voice-look-it-up.md", root: root) + outline) }
        if canAskHuman { parts.append(try read("prompts/voice-ask-your-human.md", root: root)) }
        return parts.joined(separator: "\n\n")
    }
}

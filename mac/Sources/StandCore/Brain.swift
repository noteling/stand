import Foundation

/// The thinking behind Stand's voice. When Stand is asked something it does not know, it
/// passes the question here; the answer comes back as the point to make, and Stand says it
/// in its own words. Text never sits on the live path between hearing and speaking.
public protocol Brain: AnyObject {
    /// How it is connected, for the log.
    var summary: String { get }
    func answer(_ question: String) async throws -> String
    /// Gets ready before the first question, where that saves time. Returns what went
    /// wrong, in a sentence, if it could not; the brain is then tried again at the first question.
    func start() async -> String?
    func stop()
    /// Stops work on the question it is answering. That question fails.
    func giveUp()
    /// Before it uses a tool that needs a yes, the brain asks here. No answer means no.
    var onAsk: (@Sendable (BrainAsk) async -> Bool)? { get set }
    /// What it is doing while it works on an answer, in a few words: "searching the web".
    var onActivity: (@Sendable (String) -> Void)? { get set }
}

/// A question the brain puts to its human before it uses a tool that needs a yes.
public struct BrainAsk: Sendable {
    public let id: String
    public let tool: String
    /// What it wants to do, in words a person can take in at a glance.
    public let what: String
}

/// How the brain reaches its model. The same choices and key names as Noteling: the
/// Messages API (Anthropic directly, or your own gateway through a base URL and headers),
/// or the local Claude Code CLI with its own login.
public struct BrainSettings {
    /// "api", "claudeCode", or "auto": the API when a key or a gateway is configured, the CLI otherwise.
    public var connectionMode = "auto"
    public var model = "claude-sonnet-5-5"
    /// low, medium, high, xhigh or max. Low, because people are waiting.
    public var effort = "low"
    /// The model and effort for preparing a talk before a meeting, when nobody is waiting
    /// and what it writes is what Stand will say in front of people.
    public var prepareModel = "claude-opus-5-5"
    public var prepareEffort = "high"
    /// The model that keeps watch over a talk (`Watch`). It is asked every few seconds and
    /// answers in one line, so it has to be quick. Empty means the same model as `model`.
    /// STAND_WATCH_MODEL names another for one run.
    public var watchModel = ""
    /// A gateway that speaks the Messages API. Empty means api.anthropic.com. "/v1/messages" is added to it.
    public var apiBaseURL = ""
    /// Extra headers for the gateway. A value written $NAME is the setting of that name, from the environment or .env.
    public var apiHeaders = [String: String]()
    /// The Claude Code executable. Empty means find it.
    public var claudePath = ""
    /// Where the project's own notes are, relative to the repo root.
    public var contextFolder = "context"
    /// Notes up to this many characters in all are sent whole with every question, which
    /// takes one request. Bigger than that, and the model reads files through tools, which
    /// takes several. Noteling's name for the same setting.
    public var docsStuffLimitChars = 400_000
    /// May the brain use the web when the notes do not have the answer? Only the Claude Code brain can.
    public var web = true
    /// A file of MCP servers for the brain, in Claude Code's own format ({"mcpServers": {…}}),
    /// relative to the repo root. Empty for none. Only the Claude Code brain uses it.
    public var mcpConfig = ""
    /// Bring this Mac's whole Claude Code setup into the brain: the MCP servers it has, and
    /// its settings. Off unless turned on. Whoever speaks in the meeting can ask Stand
    /// things, and with this on its answers can come from the person's own mail, calendar
    /// and whatever else that setup reaches. Off, the brain has only what is listed here.
    public var claudeCodeSetup = false
    /// When the brain asks Stand's human before it does something:
    /// - "always" (the default): before anything beyond reading the notes, searching the
    ///   folders it was given and searching the web.
    /// - "irreversible": only before a tool whose name says it sends, deletes, pays or the
    ///   like (prompts/ask-before.txt has the words). Everything else it just does. This is
    ///   "ask as little as possible", for a person who has decided they want that.
    /// - "never": it never asks.
    /// The defaults here are what a new copy of Stand starts with. Keep them the same as
    /// mac/Resources/brain.default.json.
    public var ask = "always"
    /// Tools the brain may use without asking even then, as Claude Code names them:
    /// "mcp__orders__cancel_order".
    public var allowWithoutAsking = [String]()
    /// More places to read notes from, as brain.json lists them. Each is a folder on this
    /// Mac ({"folder": "~/Documents/notes"}) or a GitHub repository ({"repo": "https://github.com/team/handbook",
    /// and optionally "branch", "path", "token", "name"}). `NotesSource.all` makes sense of them.
    public var sources = [[String: String]]()

    /// The settings file: brain.json at the repo root, or the file STAND_BRAIN names for one run.
    public static func file(root: URL) -> URL {
        Project.setting("STAND_BRAIN", root: root).map { URL(fileURLWithPath: NotesSource.expand($0), relativeTo: root).standardizedFileURL }
            ?? root.appendingPathComponent("brain.json")
    }

    /// Reads the settings file, if there is one. STAND_CONTEXT, for a test run, makes that
    /// one folder the only notes.
    public static func load(root: URL) -> BrainSettings {
        var settings = BrainSettings()
        if let data = try? Data(contentsOf: file(root: root)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func text(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            settings.connectionMode = text("connectionMode") ?? settings.connectionMode
            settings.model = text("model") ?? settings.model
            settings.effort = text("effort") ?? settings.effort
            settings.prepareModel = text("prepareModel") ?? settings.prepareModel
            settings.prepareEffort = text("prepareEffort") ?? settings.prepareEffort
            settings.watchModel = text("watchModel") ?? settings.watchModel
            settings.apiBaseURL = text("apiBaseURL") ?? ""
            settings.apiHeaders = json["apiHeaders"] as? [String: String] ?? [:]
            settings.claudePath = text("claudePath") ?? ""
            settings.contextFolder = text("contextFolder") ?? settings.contextFolder
            settings.sources = (json["sources"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
            if let limit = json["docsStuffLimitChars"] as? Int, limit >= 0 { settings.docsStuffLimitChars = limit }
            settings.web = json["web"] as? Bool ?? settings.web
            settings.mcpConfig = text("mcpConfig") ?? ""
            settings.claudeCodeSetup = json["claudeCodeSetup"] as? Bool ?? settings.claudeCodeSetup
            if let ask = text("ask"), ["irreversible", "never", "always"].contains(ask) { settings.ask = ask }
            settings.allowWithoutAsking = json["allowWithoutAsking"] as? [String] ?? []
        }
        if let folder = Project.setting("STAND_CONTEXT", root: root) {
            // A test run: these notes and nothing else, on this Mac or beyond it.
            settings.contextFolder = folder
            settings.sources = []
            settings.mcpConfig = ""
            settings.claudeCodeSetup = false
        }
        // A rehearsal leaves this Mac's own Claude Code setup out unless told otherwise: its
        // scripted questions should not go looking in the person's own mail and calendar.
        if let setup = Project.setting("STAND_CLAUDE_SETUP", root: root) { settings.claudeCodeSetup = setup != "off" }
        return settings
    }

    /// What to write in "sources" for something a person pasted or chose: a folder on this
    /// Mac when the text is the path of one, a GitHub repository otherwise. A browser
    /// address such as …/tree/main/docs also gives the branch and the folder inside it.
    public static func source(from text: String, root: URL) throws -> [String: String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isFolder: ObjCBool = false
        let path = URL(fileURLWithPath: NotesSource.expand(text), relativeTo: root).standardizedFileURL.path
        if !text.isEmpty, !text.contains("://"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw StandError("\(text) is a file. Give the folder it is in.") }
            // A folder inside the project is kept as written, so the project can be moved.
            let inProject = path.hasPrefix(root.standardizedFileURL.path + "/")
            return ["folder": inProject ? String(path.dropFirst(root.standardizedFileURL.path.count + 1)) : (path as NSString).abbreviatingWithTildeInPath]
        }
        let parsed: (address: RepoAddress, branch: String?, path: String?)
        do { parsed = try RepoAddress.parse(text) } catch {
            throw StandError("\"\(text)\" is neither a folder on this Mac nor a repository address. Give a folder's path, or paste the address of the repository's page, like \(RepoAddress.example).")
        }
        var source = ["repo": parsed.address.webURL]
        if let branch = parsed.branch { source["branch"] = branch }
        if let path = parsed.path { source["path"] = path }
        return source
    }

    /// Adds a place to read notes from to the settings file, keeping everything else in it.
    public static func add(source: [String: String], root: URL) throws {
        try edit(root: root) { sources in sources.append(source) }
    }

    /// Takes the source at `index` out of the settings file. A repository's copy goes with it, and a page's.
    public static func removeSource(at index: Int, root: URL) throws {
        let before = NotesSource.all(root: root, settings: load(root: root)).sources.first { $0.index == index }
        try edit(root: root) { sources in
            if sources.indices.contains(index) { sources.remove(at: index) }
        }
        if let link = before?.repo {
            let folder = LinkedRepos.folder(root: root)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(link.slug))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(link.slug).json"))
        }
        // A page's copy goes with it too: what was read from someone's browser is not kept once they take the page away.
        if let page = before?.page { try? FileManager.default.removeItem(at: PageCopies.folder(for: page, root: root)) }
    }

    private static func edit(root: URL, _ change: (inout [[String: Any]]) -> Void) throws {
        let url = file(root: root)
        var json = [String: Any]()
        if let data = try? Data(contentsOf: url) {
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StandError("\(url.lastPathComponent) is not readable as JSON, so it was left alone. Fix it by hand, then try again.")
            }
            json = read
        }
        var sources = json["sources"] as? [[String: Any]] ?? []
        change(&sources)
        json["sources"] = sources
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

public enum BrainFactory {
    /// The brain for this project, or nil when it would have nothing to answer from: no
    /// notes, and no other way to find things out.
    /// Which connection the brain uses on this Mac: "api" or "claudeCode", or whatever
    /// brain.json says if it is neither. Left to "auto", it is the Messages API when there
    /// is a key or a gateway for it, and the Claude Code CLI otherwise.
    public static func mode(root: URL) -> String {
        let settings = BrainSettings.load(root: root)
        guard settings.connectionMode == "auto" else { return settings.connectionMode }
        return Project.setting("ANTHROPIC_API_KEY", root: root) != nil || !settings.apiBaseURL.isEmpty ? "api" : "claudeCode"
    }

    public static func make(root: URL) throws -> Brain? {
        let settings = BrainSettings.load(root: root)
        let library = NotesLibrary(root: root, settings: settings)
        let key = Project.setting("ANTHROPIC_API_KEY", root: root)
        let mode = Self.mode(root: root)
        // The Claude Code brain can look beyond the notes; the Messages API brain cannot.
        let reachesBeyondNotes = mode == "claudeCode" && (settings.web || !settings.mcpConfig.isEmpty || settings.claudeCodeSetup)
        guard !library.current().isEmpty || reachesBeyondNotes else { return nil }
        let instructions = try Project.read(mode == "claudeCode" ? "prompts/brain-operator.md" : "prompts/brain.md", root: root)
        switch mode {
        case "api":
            guard key != nil || !settings.apiBaseURL.isEmpty else {
                throw StandError("The brain is set to the Messages API but there is no ANTHROPIC_API_KEY in .env and no apiBaseURL in brain.json.")
            }
            let headers = try resolve(settings.apiHeaders, root: root)
            return MessagesBrain(settings: settings, apiKey: key, headers: headers, library: library, instructions: instructions)
        case "claudeCode":
            guard let executable = ClaudeCodeBrain.executable(path: settings.claudePath) else {
                // Not asked for by name, and not on this Mac: Stand goes without a brain, and says it does not know.
                if settings.connectionMode == "auto" { return nil }
                throw StandError("The brain is set to the Claude Code CLI, which was not found. Install it and run `claude auth login`, set claudePath in brain.json, or add ANTHROPIC_API_KEY to .env to use the Messages API.")
            }
            return ClaudeCodeBrain(settings: settings, executable: executable, library: library, instructions: instructions, root: root)
        default:
            throw StandError("brain.json: connectionMode must be \"api\", \"claudeCode\" or \"auto\", not \"\(settings.connectionMode)\".")
        }
    }

    /// What stands in the way of Stand having a brain on this Mac, in a sentence, or nil if nothing does.
    /// A second brain for a discussion: the prompter (`PrompterSheet`). It has the notes and
    /// nothing else: no web, none of the person's tools, nothing it could ask permission
    /// for. It is a process of its own so that following the meeting never keeps one of
    /// Stand's own questions waiting. Nil when the brain is not the Claude Code CLI.
    public static func makePrompter(root: URL, talk: String? = nil) throws -> Brain? {
        var settings = BrainSettings.load(root: root)
        guard mode(root: root) == "claudeCode", let executable = ClaudeCodeBrain.executable(path: settings.claudePath) else { return nil }
        settings.web = false
        settings.mcpConfig = ""
        settings.claudeCodeSetup = false
        settings.ask = "always"
        let library = NotesLibrary(root: root, settings: settings)
        // In a talk it is given the plan of the talk, so that it can say where the talk stands.
        let instructions = try talk.map { try Project.read("prompts/brain-prompter-talk.md", root: root).replacingOccurrences(of: "{talk}", with: try Project.read($0, root: root)) }
            ?? Project.read("prompts/brain-prompter.md", root: root)
        return ClaudeCodeBrain(settings: settings, executable: executable, library: library, instructions: instructions, root: root)
    }

    /// The brain that keeps watch over a talk (`Watch`): a process of its own, with the
    /// plan of the talk and nothing else. No notes, no folders, no web, so that what it is
    /// sent each time is small and its one line comes back fast. Nil when the brain is not
    /// the Claude Code CLI.
    public static func makeWatch(root: URL, talk: String) throws -> Brain? {
        var settings = BrainSettings.load(root: root)
        guard mode(root: root) == "claudeCode", let executable = ClaudeCodeBrain.executable(path: settings.claudePath) else { return nil }
        settings.web = false
        settings.mcpConfig = ""
        settings.claudeCodeSetup = false
        settings.ask = "always"
        settings.sources = []
        if let model = ProcessInfo.processInfo.environment["STAND_WATCH_MODEL"], !model.isEmpty {
            settings.model = model
        } else if !settings.watchModel.isEmpty {
            settings.model = settings.watchModel
        }
        let instructions = try Project.read("prompts/brain-watch.md", root: root).replacingOccurrences(of: "{talk}", with: try Project.read(talk, root: root))
        return ClaudeCodeBrain(settings: settings, executable: executable, library: NotesLibrary(sources: []), instructions: instructions, root: root,
                               limit: 20, bare: true)
    }

    /// A third brain, for before the meeting: it reads the notes and the code and writes
    /// the talk Stand will give (`Preparation`). The same sources as the brain that answers
    /// questions, a stronger model, and as long as it needs. It does not use the web: what
    /// it writes has to come from what Stand's human gave it. Nil when the brain is not
    /// the Claude Code CLI.
    static func makePreparer(root: URL) throws -> ClaudeCodeBrain? {
        var settings = BrainSettings.load(root: root)
        guard mode(root: root) == "claudeCode", let executable = ClaudeCodeBrain.executable(path: settings.claudePath) else { return nil }
        settings.model = settings.prepareModel
        settings.effort = settings.prepareEffort
        settings.web = false
        let library = NotesLibrary(root: root, settings: settings)
        return ClaudeCodeBrain(settings: settings, executable: executable, library: library,
                               instructions: try Project.read("prompts/brain-prepare.md", root: root), root: root, limit: Preparation.limit)
    }

    /// Where the Claude Code CLI is on this Mac, if it is anywhere Stand looks.
    public static func claudeCLI(root: URL) -> String? {
        ClaudeCodeBrain.executable(path: BrainSettings.load(root: root).claudePath)
    }

    public static func missing(root: URL) -> String? {
        let settings = BrainSettings.load(root: root)
        let hasKey = Project.setting("ANTHROPIC_API_KEY", root: root) != nil || !settings.apiBaseURL.isEmpty
        guard settings.connectionMode != "api", !(settings.connectionMode == "auto" && hasKey) else { return nil }
        return ClaudeCodeBrain.executable(path: settings.claudePath) == nil
            ? "Claude Code is not on this Mac, so Stand will not look anything up. Install it and sign in (claude.ai/code), then start again."
            : nil
    }

    /// Fills in header values written as $NAME from the environment or .env. `$$` starts a literal dollar sign.
    static func resolve(_ headers: [String: String], root: URL) throws -> [String: String] {
        var resolved = [String: String]()
        for (name, value) in headers {
            if value.hasPrefix("$$") {
                resolved[name] = String(value.dropFirst())
            } else if value.hasPrefix("$") {
                let secret = String(value.dropFirst())
                guard let found = Project.setting(secret, root: root) else {
                    throw StandError("brain.json: the header \(name) needs a secret that is not set: \(secret). Add it to .env.")
                }
                resolved[name] = found
            } else {
                resolved[name] = value
            }
        }
        return resolved
    }
}

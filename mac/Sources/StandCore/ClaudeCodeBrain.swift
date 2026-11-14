import Foundation

/// The brain as an operator on this computer: the Claude Code CLI, run with no window, kept
/// open for the whole meeting and asked one thing after another.
///
/// For this phase only. The user's words on 2026-11-12: an external tool as the brain is
/// "a compromise, not design". What the brain should finally be is not settled by this.
///
/// Why one process and not one per question: kept open, it answered from notes in its
/// prompt in 0.8 to 0.9 seconds, against 1.4 to 2.1 for a process each (CLAUDE.md has the
/// measurements). It also remembers the questions before, so a follow-up makes sense.
///
/// What it may do. The user's rule for this phase (2026-11-12) is to ask the person as
/// little as possible: "useful but creepy" before "useless and annoying".
/// - Each source is a folder, and the folder is the boundary (the user's design,
///   2026-11-13): inside it the brain reads and searches with its own tools, grep included,
///   whatever the files are. Nothing is copied, indexed or chosen for it.
/// - It reads other files on this Mac, and with `web` on the web, and it uses
///   the tools of whatever MCP servers it is given, without asking.
/// - It asks its human first, through `onAsk`, only before a tool whose name says that it
///   sends, deletes, pays or the like (prompts/ask-before.txt). No answer is a no.
///   `ask` in brain.json makes that "never" or "always".
/// - It never reads a file that looks like it holds secrets, and outside its folders it
///   does not search inside files (a search reads hidden files such as .env too): a key
///   spoken into a meeting cannot be taken back. Both are refused without a question.
///   Inside its folders no question is ever raised, so there the same files are kept from
///   it by Claude Code's own rules for what may not be read (`neverRead`), which its
///   search obeys as well.
/// - It has no tool that runs a command or changes a file.
final class ClaudeCodeBrain: Brain, @unchecked Sendable {
    var onAsk: (@Sendable (BrainAsk) async -> Bool)?
    var onActivity: (@Sendable (String) -> Void)?

    /// One question may take this long before the process is stopped. The session gives
    /// up on its own, sooner; this is so that a stuck process does not stay around.
    /// Preparing a talk before a meeting is one long question, and is given longer.
    static let questionLimit = 120.0
    private let limit: Double

    private let settings: BrainSettings
    private let executable: String
    private let library: NotesLibrary
    private let instructions: String
    private let abilities: [String: String]
    private let askBefore: Set<String>
    private let root: URL
    private let emptyMCPConfig: URL
    /// The source folders, by the names the brain knows them by.
    private let places: [(name: String, path: String)]

    /// Files the brain is never to read, wherever they are in a folder it may use: keys,
    /// passwords, logins. Given to Claude Code as rules against reading, which its search
    /// obeys too. Names only: a key written into an ordinary file of code is not caught
    /// here, and the brain is told never to give one out.
    static let neverRead: [String] = {
        var names = [".env", ".env.*", "*.pem", "*.p12", "*.pfx", "*.key", "*.keystore", "*.jks", "*.kdbx", "*.mobileprovision",
                     "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*", ".netrc", ".npmrc", ".pypirc", ".htpasswd",
                     "secrets.*", "credentials", "credentials.*", "*.tfvars", "*.tfstate",
                     ".ssh/**", ".aws/**", ".gnupg/**", ".kube/**", ".docker/**", ".git/**"]
        // Configuration whose own name says what it holds. Code is left alone: a file called PasswordReset.swift is not a password.
        for word in ["secret", "credential", "password", "passwd", "service-account", "serviceaccount", "apikey", "api-key", "api_key", "keys"] {
            for ending in ["json", "yaml", "yml", "toml", "plist", "properties", "ini", "conf", "cfg", "txt"] { names.append("*\(word)*.\(ending)") }
        }
        return names
    }()
    private let queue = DispatchQueue(label: "stand.brain")

    private final class Pending {
        let question: String
        let done: CheckedContinuation<String, Error>
        var finished = false
        init(_ question: String, _ done: CheckedContinuation<String, Error>) {
            self.question = question
            self.done = done
        }
    }

    // Everything below is touched only on `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var launch = 0 // counts processes, so that what a finished one still sends is ignored
    private var launchedWith: Int? // the notes as they were when the process started
    private var partial = Data()
    private var errors = Data()
    private var current: Pending?
    private var waiting = [Pending]()
    private var stopped = false

    var summary: String {
        let notes = library.current()
        let whole = notes.fits(within: settings.docsStuffLimitChars)
        let how = notes.isEmpty ? "no notes" : !notes.hasOtherFiles ? "\(notes.summary) \(whole ? "sent whole" : "read through tools")"
            : "\(notes.summary), \(!notes.hasDocuments ? "searched in place" : whole ? "the notes sent whole and the rest searched in place" : "all read in place")"
        var reach = [String]()
        if settings.web { reach.append("the web") }
        if !settings.mcpConfig.isEmpty { reach.append("the MCP servers in \(settings.mcpConfig)") }
        if settings.claudeCodeSetup { reach.append("this Mac's Claude Code setup") }
        return "the Claude Code CLI kept open, \(settings.model.isEmpty ? "its default model" : settings.model), effort \(settings.effort), \(how)"
            + (reach.isEmpty ? "" : ", and may use \(reach.joined(separator: ", "))")
    }

    /// The executable at `path`, or the first `claude` found: on PATH, in the usual places,
    /// where the installers for Node put a command, and failing all of those, wherever the
    /// person's own shell finds it. An app opened from Finder gets a bare PATH and none of
    /// what a shell profile sets up, so on someone else's Mac all of this matters.
    static func executable(path: String) -> String? {
        let manager = FileManager.default
        if !path.isEmpty {
            let path = (path as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: path) ? path : nil
        }
        let home = manager.homeDirectoryForCurrentUser.path
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
            + ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
               "\(home)/.npm-global/bin/claude", "\(home)/.volta/bin/claude", "\(home)/.bun/bin/claude", "\(home)/Library/pnpm/claude",
               "\(home)/.asdf/shims/claude", "\(home)/.local/share/mise/shims/claude", "\(home)/.yarn/bin/claude"]
        // nvm and fnm keep a folder for each version of Node: the newest first.
        for versions in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions", "\(home)/Library/Application Support/fnm/node-versions"] {
            let names = ((try? manager.contentsOfDirectory(atPath: versions)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += names.flatMap { ["\(versions)/\($0)/bin/claude", "\(versions)/\($0)/installation/bin/claude"] }
        }
        return candidates.first { manager.isExecutableFile(atPath: $0) } ?? whereTheShellFindsIt
    }

    /// Where the person's own login shell finds `claude`, with everything their profile sets
    /// up. Asked once, and only when it is in none of the known places. Four seconds at most.
    private static let whereTheShellFindsIt: String? = { askShell() }()

    /// What the shell prints goes to a file, not a pipe, and after four seconds the shell
    /// is killed outright. An interactive shell ignores a polite request to stop, and a
    /// profile can leave something running that holds a pipe open long after the shell
    /// itself has gone: either would hang whoever asked, which is a session trying to start.
    static func askShell(_ shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", seconds: Double = 4) -> String? {
        let manager = FileManager.default
        let file = manager.temporaryDirectory.appendingPathComponent("stand-which-\(UUID().uuidString)")
        manager.createFile(atPath: file.path, contents: nil)
        defer { try? manager.removeItem(at: file) }
        guard let printed = try? FileHandle(forWritingTo: file) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v claude"]
        process.standardOutput = printed
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? printed.close()
        // A profile may print things of its own: the answer is the last line that is a program.
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && manager.isExecutableFile(atPath: $0) }
    }

    init(settings: BrainSettings, executable: String, library: NotesLibrary, instructions: String, root: URL, limit: Double = ClaudeCodeBrain.questionLimit) {
        self.limit = limit
        self.settings = settings
        self.executable = executable
        self.library = library
        self.instructions = instructions
        self.root = root
        places = library.sources.map { ($0.name, $0.folder.standardizedFileURL.path) }
        // prompts/brain-abilities.txt: one line for each thing the brain may be given, each
        // behind a tag in square brackets. Only the lines that apply go into its instructions.
        var lines = [String: String]()
        for line in ((try? Project.read("prompts/brain-abilities.txt", root: root)) ?? "").split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            lines[String(line[line.index(after: line.startIndex)..<close])] = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        abilities = lines
        // prompts/ask-before.txt: the words in a tool's name that mean it should ask first.
        askBefore = Set(((try? Project.read("prompts/ask-before.txt", root: root)) ?? "send\ndelete\npay")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        // One small file, the same every time, so nothing piles up in the temporary folder.
        emptyMCPConfig = FileManager.default.temporaryDirectory.appendingPathComponent("stand-brain-no-mcp.json")
        try? Data(#"{"mcpServers":{}}"#.utf8).write(to: emptyMCPConfig)
    }

    // MARK: Asking it

    func start() async -> String? {
        // One small exchange: the process is up, the login works, and the notes are in the
        // model's cache, before anyone in the meeting is waiting.
        do {
            _ = try await answer("This is a check before the meeting starts, not a question from it. Reply with the single word: ready")
            return nil
        } catch {
            return "\(error)"
        }
    }

    func answer(_ question: String) async throws -> String {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
            queue.async {
                let pending = Pending(question, done)
                guard !self.stopped else { self.finish(pending, .failure(StandError("The brain has been stopped."))); return }
                if self.current != nil { self.waiting.append(pending) } else { self.begin(pending) }
            }
        }
    }

    func giveUp() {
        queue.async {
            guard let pending = self.current else { return }
            self.current = nil
            self.finish(pending, .failure(StandError("The brain was told to stop looking.")))
            self.endProcess() // the only sure way to stop a turn that is under way
            self.next()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            let all = [self.current].compactMap { $0 } + self.waiting
            self.current = nil
            self.waiting = []
            for pending in all { self.finish(pending, .failure(StandError("The brain has been stopped."))) }
            self.endProcess()
        }
    }

    private func begin(_ pending: Pending) {
        current = pending
        do {
            // The notes as they are now. If a file has changed since the process started,
            // it starts again with the new ones, and forgets the questions before.
            let notes = library.current()
            if process == nil || launchedWith != notes.signature {
                endProcess()
                try start(with: notes)
            }
            try send(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": pending.question]]]])
        } catch {
            current = nil
            finish(pending, .failure(error))
            endProcess()
            next()
            return
        }
        queue.asyncAfter(deadline: .now() + limit) { [weak self, weak pending] in
            guard let self, let pending, self.current === pending else { return }
            self.current = nil
            self.finish(pending, .failure(StandError("The brain did not answer within \(Int(self.limit)) seconds.")))
            self.endProcess()
            self.next()
        }
    }

    private func next() {
        guard current == nil, !waiting.isEmpty else { return }
        begin(waiting.removeFirst())
    }

    private func finish(_ pending: Pending, _ result: Result<String, Error>) {
        guard !pending.finished else { return }
        pending.finished = true
        pending.done.resume(with: result)
    }

    // MARK: The process

    private func start(with notes: Notes) throws {
        let inline = notes.fits(within: settings.docsStuffLimitChars)
        var can = [String]()
        if let line = abilities[!notes.hasDocuments ? "no-notes" : inline ? "notes-inline" : "notes-files"] { can.append(line) }
        if notes.hasOtherFiles, let line = abilities["folders"] { can.append(line) }
        if settings.ask != "always", let line = abilities["files"] { can.append(line) }
        if settings.web, let line = abilities["web"] { can.append(line) }
        if !settings.mcpConfig.isEmpty || settings.claudeCodeSetup, let line = abilities["mcp"] { can.append(line) }
        var system = instructions + "\n\n# What you can use\n\n" + can.map { "- \($0)" }.joined(separator: "\n")
        // The folders are the boundary. The brain is told where they are, and what they hold
        // besides the notes: none of that is shown to it, it goes and searches for what a question needs.
        let folders = places.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !folders.isEmpty, notes.hasOtherFiles || (notes.hasDocuments && !inline) {
            system += "\n\n# The folders you can use\n\n" + folders.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
            if !notes.map.isEmpty { system += "\n\nWhat they hold besides the notes, by the names above:\n\n" + notes.map }
        }
        if inline, notes.hasDocuments { system += "\n\n# The notes\n\n" + notes.inlined }

        // The program starts in an empty folder of its own, and is given the sources by
        // name. Inside them its file tools need no permission. A file anywhere else comes
        // to `handle` below, like everything else that needs permission.
        let folder = try NotesLibrary.standingPlace()
        let tools = ["Read", "Grep", "Glob"] + (settings.web ? ["WebSearch", "WebFetch"] : [])
        let allowed = (settings.web ? ["WebSearch"] : []) + settings.allowWithoutAsking
        var arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence",
            // Permission questions come to this process, which passes them to Stand's human.
            "--permission-prompt-tool", "stdio",
            "--tools", tools.joined(separator: ","),
            "--system-prompt", system,
        ]
        if !allowed.isEmpty { arguments += ["--allowedTools", allowed.joined(separator: ",")] }
        if !folders.isEmpty {
            arguments += ["--add-dir"] + folders.map(\.path)
            // What is never read, in any of them. Read rules hold for searches too.
            var never = folders.flatMap { place in Self.neverRead.map { "Read(/\(place.path)/**/\($0))" } }
            // And what a project's own .gitignore leaves out, the brain leaves out: what was
            // built, downloaded or recorded there is not what anyone is asking about. Its
            // search does this by itself in a git repository, and not in a plain folder.
            for place in folders {
                var ignore = Ignore()
                ignore.read(URL(fileURLWithPath: place.path).appendingPathComponent(".gitignore"), under: "")
                never += ignore.globs.prefix(200).map { "Read(/\(place.path)/\($0))" }
            }
            let rules = try JSONSerialization.data(withJSONObject: ["permissions": ["deny": never]])
            let file = folder.appendingPathComponent("never-read-\(launch + 1).json")
            try rules.write(to: file)
            arguments += ["--settings", file.path]
        }
        let mcpConfig = settings.mcpConfig.isEmpty ? nil
            : URL(fileURLWithPath: NotesSource.expand(settings.mcpConfig), relativeTo: root).standardizedFileURL.path
        if settings.claudeCodeSetup {
            // This Mac's own Claude Code settings and MCP servers come along.
            if let mcpConfig { arguments += ["--mcp-config", mcpConfig] }
        } else {
            arguments += ["--disable-slash-commands", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", mcpConfig ?? emptyMCPConfig.path]
        }
        if !settings.model.isEmpty { arguments += ["--model", settings.model] }
        if !settings.effort.isEmpty {
            arguments += ["--effort", ["low", "medium"].contains(settings.effort) ? settings.effort : "high"]
        }

        // Its own login, whatever this process was started with. An app opened from Finder
        // has a bare PATH, and an MCP server is often started by a program that is not on it.
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The CLI's own folder comes first: installed through Node, it is a script that needs the `node` beside it.
        let usual = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (usual.prefix(1).filter { !path.contains($0) } + path + usual.dropFirst().filter { !path.contains($0) }).joined(separator: ":")
        environment["STAND_ROOT"] = root.path // for an MCP config that names a program inside the project
        // The CLI finds its login by the user's name. Without USER it says "Not logged in".
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        if environment["HOME"] == nil { environment["HOME"] = home }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        launch += 1
        let mine = launch
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.received(data, from: mine) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self, self.launch == mine else { return }
                self.errors = (self.errors + data).suffix(2_000)
            }
        }
        // The exit is waited for through the handler, never `waitUntilExit` on another thread (see Subprocess).
        process.terminationHandler = { [weak self] ended in
            self?.queue.async { self?.ended(mine, status: ended.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            throw StandError("Could not start the Claude Code CLI at \(executable): \(error.localizedDescription)")
        }
        self.process = process
        input = stdin.fileHandleForWriting
        launchedWith = notes.signature
        partial = Data()
        errors = Data()
    }

    private func endProcess() {
        launch += 1 // whatever the old one still sends is ignored
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        launchedWith = nil
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw StandError("The brain's process is not running.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw StandError("The brain's process stopped taking input: \(error.localizedDescription)")
        }
    }

    private func ended(_ which: Int, status: Int32) {
        guard which == launch else { return }
        process = nil
        input = nil
        launchedWith = nil
        guard let pending = current else { return }
        current = nil
        let said = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        finish(pending, .failure(StandError("The Claude Code CLI stopped (status \(status))\(said.isEmpty ? "" : ": \(said.suffix(300))")")))
        next()
    }

    // MARK: What it sends back

    private func received(_ data: Data, from which: Int) {
        guard which == launch else { return }
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial = partial[partial.index(after: newline)...]
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(event, from: which)
        }
    }

    private func handle(_ event: [String: Any], from which: Int) {
        switch event["type"] as? String {
        case "assistant":
            // What it is reaching for, as it reaches: the session uses this to say that the answer is taking a moment.
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                onActivity?(describe(use: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:]))
            }
        case "control_request":
            guard let id = event["request_id"] as? String, let request = event["request"] as? [String: Any] else { return }
            guard request["subtype"] as? String == "can_use_tool" else {
                // Nothing else is expected. Say so, so that the process does not wait for ever.
                try? send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Stand does not handle this request."]])
                return
            }
            let tool = request["tool_name"] as? String ?? ""
            let toolInput = request["input"] as? [String: Any] ?? [:]
            func answer(_ decision: [String: Any]) {
                try? send(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": decision]])
            }
            if tool == "Grep" {
                // Inside its own folders a search needs no permission and never comes here. Anywhere
                // else it reads hidden files too: a search of a folder gave up a key in an .env file.
                onActivity?("refused to search inside files outside its folders")
                answer(["behavior": "deny", "message": "Searching inside files works only in the folders you can use. Outside them, read one file by its full path, or list a folder with Glob. Do not try another way to search."])
                return
            }
            if Self.looksSecret(toolInput) {
                onActivity?("refused a file that looks like it holds secrets")
                answer(["behavior": "deny", "message": "That file may hold secrets, and Stand never reads those out. Do not try another way to read it. Reply NOT FOUND and say only that it cannot be checked."])
                return
            }
            // Ask as little as possible: only when the tool's own name says it cannot be taken back.
            let mustAsk = settings.ask == "always" || (settings.ask != "never" && cannotBeUndone(tool))
            guard mustAsk else {
                answer(["behavior": "allow", "updatedInput": toolInput])
                return
            }
            let ask = BrainAsk(id: id, tool: tool, what: Self.describe(ask: tool, input: toolInput, description: request["description"] as? String))
            let onAsk = self.onAsk
            // The input goes back exactly as it came. It is only ever read on `queue` again.
            let box = UncheckedBox(toolInput)
            Task { [weak self] in
                let yes = await onAsk?(ask) ?? false
                self?.queue.async {
                    guard let self, self.launch == which else { return }
                    let decision: [String: Any] = yes ? ["behavior": "allow", "updatedInput": box.value]
                        : ["behavior": "deny", "message": "Stand's human did not allow this. Do not try another way to do the same thing. Answer from what you have. If you cannot, reply NOT FOUND and say only that it cannot be checked just now: do not mention permission."]
                    try? self.send(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": decision]])
                }
            }
        case "result":
            guard let pending = current else { return }
            current = nil
            let text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if event["is_error"] as? Bool == true || text.isEmpty {
                finish(pending, .failure(StandError("The Claude Code CLI could not answer: \(text.isEmpty ? (event["subtype"] as? String ?? "no text came back") : String(text.prefix(300)))")))
            } else {
                finish(pending, .success(text))
            }
            next()
        default:
            break
        }
    }

    /// True when a tool's name has one of the words in prompts/ask-before.txt: send_email, deleteEvent, cancel-order.
    private func cannotBeUndone(_ tool: String) -> Bool {
        // The tool's own name, without the server's: mcp__mail__send_email is "send_email".
        let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").dropFirst(2).joined(separator: "_")) : tool
        var words = [String]()
        var word = ""
        for character in name {
            if character.isLetter {
                if character.isUppercase, word.last?.isLowercase == true { words.append(word); word = "" } // camelCase
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.contains { askBefore.contains($0.lowercased()) }
    }

    /// True when a file tool is pointed at something that looks like it holds keys or passwords.
    static func looksSecret(_ input: [String: Any]) -> Bool {
        let marks = ["/.env", ".env.", "/.ssh", "id_rsa", "id_ed25519", "id_ecdsa", ".pem", ".p12", ".pfx", ".keychain", "/keychains/",
                     "/.aws/", "/.gnupg", ".netrc", "/.config/gh/", "secrets.json", "credentials", "password", ".kdbx",
                     ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".npmrc", ".pypirc", "/.docker/", "/.kube/",
                     ".claude.json", "/.claude/", "/.noteling/config", "token"]
        for key in ["file_path", "path", "pattern", "glob"] {
            guard let value = (input[key] as? String)?.lowercased() else { continue }
            if value == ".env" || value.hasSuffix("/.env") || marks.contains(where: { value.contains($0) }) { return true }
        }
        return false
    }

    private final class UncheckedBox: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    /// What it is doing, for the log and the panel: "searching the web for …".
    func describe(use tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read", "Grep", "Glob":
            let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
            // In one of its own folders: a note, or something else that is kept there.
            guard let place = places.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
                return path.hasPrefix("/") && !path.contains("/stand-brain-") ? "reading \((path as NSString).abbreviatingWithTildeInPath)" : "reading the notes"
            }
            let named = [path, input["glob"] as? String ?? "", tool == "Glob" ? input["pattern"] as? String ?? "" : ""]
            let isNote = named.contains { Notes.kinds.contains(($0 as NSString).pathExtension.lowercased()) }
            return isNote ? "reading the notes" : "looking in \(place.name)"
        case "WebSearch": return "searching the web for “\((input["query"] as? String ?? "").prefix(80))”"
        case "WebFetch": return "reading \(Self.host(input["url"] as? String))"
        default:
            let parts = tool.components(separatedBy: "__")
            if tool.hasPrefix("mcp__"), parts.count >= 3 { return "using \(parts[2...].joined(separator: "__")) from \(parts[1])" }
            return "using \(tool)"
        }
    }

    /// What it wants a yes for, in words a person can take in at a glance in the middle of a meeting.
    static func describe(ask tool: String, input: [String: Any], description: String?) -> String {
        func compact(_ input: [String: Any]) -> String {
            let pairs = input.sorted { $0.key < $1.key }.map { "\($0.key): \(String(describing: $0.value).prefix(60))" }
            return pairs.isEmpty ? "" : " (\(pairs.joined(separator: ", ").prefix(140)))"
        }
        switch tool {
        case "WebFetch": return "read a web page at \(host(input["url"] as? String))"
        case "Read": return "read the file \(((input["file_path"] as? String ?? "") as NSString).abbreviatingWithTildeInPath)"
        case "Grep", "Glob": return "search files in \(((input["path"] as? String ?? "a folder outside the notes") as NSString).abbreviatingWithTildeInPath)"
        default:
            let parts = tool.components(separatedBy: "__")
            if tool.hasPrefix("mcp__"), parts.count >= 3 {
                return "use \(parts[2...].joined(separator: "__")) from \(parts[1])\(compact(input))"
            }
            return "use \(tool)\(description.map { ": \($0.prefix(120))" } ?? compact(input))"
        }
    }

    private static func host(_ url: String?) -> String {
        guard let url, let parsed = URL(string: url), let host = parsed.host else { return url ?? "a web page" }
        return host
    }
}

import Foundation

/// One place Stand's notes come from: a folder on this Mac, a GitHub repository kept as a
/// copy on this Mac (`LinkedRepos`), or a page read from its human's browser and kept as a
/// copy (`PageCopies`). brain.json lists them under "sources"; the project's own
/// `context/` folder is always the first.
public struct NotesSource: Sendable {
    /// What the brain sees in front of each file's path, and what the panel shows.
    public var name: String
    /// Where its files are on this Mac. For a repository: its copy under linked/, plus the folder asked for.
    public var folder: URL
    /// Set when it is a GitHub repository.
    public var repo: RepoLink?
    /// Set when it is the copy of a page read from a browser: the page's address.
    public var page: URL?
    /// The project's own notes folder. Its top-level README.md describes the folder and is not a note.
    public var isBuiltIn = false
    /// Where it is, in words, for the panel: "~/Documents/notes" or "github.com/acme/handbook, docs".
    public var place: String
    /// Its position in brain.json's "sources", for removing it. Nil for the built-in folder.
    public var index: Int?

    /// The sources the settings name, and what could not be used, said in a sentence each.
    public static func all(root: URL, settings: BrainSettings) -> (sources: [NotesSource], problems: [String]) {
        var sources = [NotesSource]()
        var problems = [String]()
        var taken = Set<String>()
        func unique(_ wanted: String) -> String {
            let base = wanted.isEmpty ? "notes" : wanted
            var name = base
            var n = 2
            while taken.contains(name.lowercased()) { name = "\(base)-\(n)"; n += 1 }
            taken.insert(name.lowercased())
            return name
        }

        let builtIn = URL(fileURLWithPath: expand(settings.contextFolder), relativeTo: root).standardizedFileURL
        sources.append(NotesSource(name: unique(builtIn.lastPathComponent), folder: builtIn, isBuiltIn: true,
                                   place: settings.contextFolder))

        for (index, entry) in settings.sources.enumerated() {
            if let folder = entry["folder"], !folder.isEmpty {
                let url = URL(fileURLWithPath: expand(folder), relativeTo: root).standardizedFileURL
                // Listing the built-in folder again would only show every note twice.
                guard url.path != builtIn.path else { continue }
                sources.append(NotesSource(name: unique(entry["name"] ?? url.lastPathComponent), folder: url, place: folder, index: index))
            } else if let repo = entry["repo"], !repo.isEmpty {
                do {
                    let parsed = try RepoAddress.parse(repo)
                    let branch = entry["branch"] ?? parsed.branch ?? ""
                    let path = (entry["path"] ?? parsed.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    let link = RepoLink(address: parsed.address, branch: branch, path: path, token: entry["token"].flatMap { $0.isEmpty ? nil : $0 })
                    var folder = LinkedRepos.folder(root: root).appendingPathComponent(link.slug)
                    if !path.isEmpty { folder.appendPathComponent(path) }
                    let host = parsed.address.host + "/" + parsed.address.name
                    let place = host + (branch.isEmpty ? "" : ", branch \(branch)") + (path.isEmpty ? "" : ", \(path)")
                    sources.append(NotesSource(name: unique(entry["name"] ?? parsed.address.repo), folder: folder.standardizedFileURL,
                                               repo: link, place: place, index: index))
                } catch {
                    problems.append("brain.json: the source \"\(repo)\" can't be used. \(error)")
                }
            } else if let page = entry["page"], !page.isEmpty {
                guard let address = PageCopies.address(page) else {
                    problems.append("brain.json: the source \"\(page)\" is not the address of a page.")
                    continue
                }
                sources.append(NotesSource(name: unique(entry["name"] ?? PageCopies.name(for: address)), folder: PageCopies.folder(for: address, root: root).standardizedFileURL,
                                           page: address, place: PageCopies.short(address), index: index))
            } else {
                problems.append("brain.json: source \(index + 1) names neither a \"folder\", a \"repo\" nor a \"page\".")
            }
        }
        return (sources, problems)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// What Stand's sources hold right now. A source is a folder, and the folder is the
/// boundary: the brain may read and search what is in it, with its own tools, and nothing
/// outside it without a question. (The user's design, 2026-11-13: "it gives boundary,
/// this is the folder you can use, and then the llm can just run grep".)
///
/// The documents in those folders are the notes. They are read here as well, because
/// notes small enough are handed to the model whole, which makes an answer take one
/// request. Everything else in a folder (code, configuration, data) is only counted here,
/// so that the brain can be told where it is.
public struct Notes: Sendable {
    public struct File: Sendable {
        /// The source's name, then the file's path inside it: "handbook/pricing/plans.md".
        public let path: String
        public let text: String
    }

    public struct Count: Sendable {
        public let name: String
        /// Documents, and how much text they hold.
        public let files: Int
        public let characters: Int
        /// Everything else in the folder that the brain can search.
        public let others: Int
    }

    /// The documents.
    public let files: [File]
    /// One per source, in the settings' order, with nothing in it counted as zero.
    public let counts: [Count]
    /// What was not read, and why, in a sentence each.
    public let leftOut: [String]
    /// Where everything but the notes is, for a brain that has to go and look: a line for
    /// each folder, the fullest first. Empty when the sources hold only notes.
    public let map: String
    /// Changes whenever a document is added, removed or edited.
    let signature: Int

    /// What counts as a note: a document someone wrote to be read.
    static let kinds: Set<String> = ["md", "markdown", "mdx", "txt", "rst", "adoc", "org"]
    /// What counts as code, for the copy Stand keeps of a GitHub repository and for saying
    /// what the brain is reading. On this Mac a folder is used as it is, whatever is in it.
    static let codeKinds: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "hh", "cs", "fs", "vb",
        "java", "kt", "kts", "scala", "groovy", "gradle", "clj", "cljs",
        "go", "rs", "zig", "py", "pyi", "rb", "erb", "php", "pl", "pm", "lua", "r", "jl", "dart", "ex", "exs", "erl", "hs", "ml",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "astro", "html", "htm", "css", "scss", "sass", "less",
        "sql", "graphql", "gql", "proto", "thrift", "avsc",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "json", "jsonc", "yaml", "yml", "toml", "xml", "plist", "ini", "cfg", "conf", "properties",
        "tf", "hcl", "cmake", "mk", "bzl", "bazel", "nix",
    ]
    /// Code that goes by its name and has no ending.
    static let codeNames: Set<String> = ["makefile", "dockerfile", "gemfile", "rakefile", "procfile", "podfile", "cartfile", "brewfile",
                                         "justfile", "jenkinsfile", "vagrantfile", "containerfile"]
    /// Folders of things a project downloads or generates. Notes are not looked for in
    /// them, and they are not counted.
    static let foldersLeftOut: Set<String> = ["node_modules", "bower_components", "pods", "carthage", "deriveddata", "__pycache__",
                                              "site-packages", "venv", "vendor"]
    /// Hidden folders are passed over, except the ones that say how a project is tested and shipped.
    static let hiddenFoldersKept: Set<String> = [".github", ".circleci", ".gitlab", ".buildkite"]
    /// A bigger file than this is not a note.
    static let largestFile = 1_000_000
    static let mostFiles = 2_000
    /// Counting stops here. The brain can still search the rest.
    static let mostCounted = 100_000

    /// True when there is nothing to look anything up in: no notes, and nothing else in any folder.
    public var isEmpty: Bool { files.isEmpty && !hasOtherFiles }
    public var hasDocuments: Bool { !files.isEmpty }
    public var hasOtherFiles: Bool { counts.contains { $0.others > 0 } }
    /// How much text the notes hold. Nothing else is counted: nothing else is ever sent whole.
    public var totalCharacters: Int { counts.reduce(0) { $0 + $1.characters } }
    /// Up to `limit` characters (`docsStuffLimitChars` in brain.json), every note is handed
    /// to the model at once, which takes one request. Above it, the model reads files through tools.
    public func fits(within limit: Int) -> Bool { totalCharacters <= limit }

    /// "14 files from 2 places", or "14 notes and 212 other files from 2 places", for the log and the panel.
    public var summary: String {
        let places = counts.filter { $0.files + $0.others > 0 }.count
        guard !isEmpty else { return "no notes" }
        let from = "from \(places) \(places == 1 ? "place" : "places")"
        let documents = counts.reduce(0) { $0 + $1.files }, others = counts.reduce(0) { $0 + $1.others }
        guard others > 0 else { return "\(documents) \(documents == 1 ? "file" : "files") \(from)" }
        let rest = "\(others)\(others >= Notes.mostCounted ? " or more" : "") other \(others == 1 ? "file" : "files")"
        return documents == 0 ? "\(rest) \(from)" : "\(documents) \(documents == 1 ? "note" : "notes") and \(rest) \(from)"
    }

    /// Every note, one after another, for notes small enough to send whole.
    var inlined: String {
        files.map { "# \($0.path)\n\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n---\n\n")
    }

    // The three tools a model gets over the Messages API when the notes are too big to send whole.

    func list() -> String {
        files.map { "\($0.path) (\($0.text.count) characters)" }.joined(separator: "\n")
    }

    func read(_ path: String) -> String? {
        files.first { $0.path == path }.map { String($0.text.prefix(60_000)) }
    }

    func search(_ query: String) -> String {
        let needle = query.lowercased()
        var hits = [String]()
        for file in files {
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.lowercased().contains(needle) {
                hits.append("\(file.path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(300))")
                if hits.count == 40 { return hits.joined(separator: "\n") + "\n(more matches were left out)" }
            }
        }
        return hits.isEmpty ? "No line contains \"\(query)\"." : hits.joined(separator: "\n")
    }
}

/// A small part of what a .gitignore means: enough to leave out what a project builds,
/// downloads or keeps to itself. A line that brings a file back (`!…`) is followed when
/// the folders are walked: the last rule that fits a file decides, as in git. The rules
/// handed to the brain's own search (`globs`) cannot say "except", so there a file that
/// was brought back stays left out.
struct Ignore {
    private struct Rule {
        /// The folder the .gitignore is in, as a path inside the source ending in a slash, or empty.
        let under: String
        let pattern: String
        /// With a slash in it, a pattern is a path from the .gitignore's own folder; without, a name at any depth.
        let isPath: Bool
        let foldersOnly: Bool
        /// `**` lets a star run across folders.
        let acrossFolders: Bool
        /// A line that began with `!`: what fits it is kept after all.
        let bringsBack: Bool
    }

    private var rules = [Rule]()

    mutating func read(_ file: URL, under: String) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            var pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            let bringsBack = pattern.hasPrefix("!")
            if bringsBack { pattern.removeFirst() }
            var foldersOnly = false
            if pattern.hasSuffix("/**") { pattern.removeLast(3); foldersOnly = true }
            if pattern.hasSuffix("/") { pattern.removeLast(); foldersOnly = true }
            while pattern.hasPrefix("**/") { pattern.removeFirst(3) }
            var isPath = pattern.contains("/")
            if pattern.hasPrefix("/") { pattern.removeFirst(); isPath = true }
            guard !pattern.isEmpty else { continue }
            rules.append(Rule(under: under, pattern: pattern, isPath: isPath, foldersOnly: foldersOnly,
                              acrossFolders: pattern.contains("**"), bringsBack: bringsBack))
        }
    }

    /// The rules that leave things out, as patterns for a tool that takes them one by one:
    /// each as a path below the folder the .gitignore is in, once for the thing itself and
    /// once for everything in it.
    var globs: [String] {
        rules.filter { !$0.bringsBack }.flatMap { rule -> [String] in
            let path = rule.under + (rule.isPath ? "" : "**/") + rule.pattern
            return rule.foldersOnly ? [path + "/**"] : [path, path + "/**"]
        }
    }

    /// Whether the rules leave this out. Later rules win over earlier ones, and a folder's
    /// own .gitignore, read after the ones above it, over those.
    func matches(_ relative: String, isFolder: Bool) -> Bool {
        guard !rules.isEmpty else { return false }
        let name = (relative as NSString).lastPathComponent
        var leftOut = false
        for rule in rules where relative.hasPrefix(rule.under) && (isFolder || !rule.foldersOnly) {
            let fits = rule.isPath
                ? fnmatch(rule.pattern, String(relative.dropFirst(rule.under.count)), rule.acrossFolders ? 0 : FNM_PATHNAME) == 0
                : fnmatch(rule.pattern, name, 0) == 0
            if fits { leftOut = !rule.bringsBack }
        }
        return leftOut
    }
}

/// Reads the sources, and reads them again when a file has changed. The brain asks for
/// the current notes before every answer, so a note saved, or a repository updated,
/// during a meeting is used a question or two later.
public final class NotesLibrary: @unchecked Sendable {
    public let sources: [NotesSource]
    /// Sources named in brain.json that could not be used.
    public let problems: [String]
    private let lock = NSLock()
    private var cached: Notes?
    private var walkedAt = Date.distantPast
    private var walking = false
    /// A folder of code can take seconds to walk, and the brain asks before every answer.
    /// So what was found last time is given at once, and when that is older than this the
    /// folders are walked again behind it, for the answer after.
    static let walkEvery: TimeInterval = 5

    public init(root: URL, settings: BrainSettings) {
        (sources, problems) = NotesSource.all(root: root, settings: settings)
    }

    public init(sources: [NotesSource]) {
        self.sources = sources
        problems = []
    }

    public func current() -> Notes {
        lock.lock()
        if let cached {
            if Date().timeIntervalSince(walkedAt) > Self.walkEvery, !walking {
                walking = true
                DispatchQueue.global(qos: .utility).async { [weak self] in _ = self?.walk() }
            }
            lock.unlock()
            return cached
        }
        lock.unlock()
        return walk()
    }

    /// An empty folder for the brain's program to start in, so that nothing is in reach of
    /// its file tools but the folders it is given by name. One per run of Stand.
    public static func standingPlace() throws -> URL {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("stand-brain-\(getpid())")
        if !manager.fileExists(atPath: folder.path) {
            // What an earlier run left behind is of no more use, under this name or the old one.
            for name in (try? manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path)) ?? [] {
                for prefix in ["stand-brain-", "stand-notes-"] where name.hasPrefix(prefix) {
                    guard let pid = Int32(name.dropFirst(prefix.count)), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
                    try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent(name))
                }
            }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func walk() -> Notes {
        lock.lock()
        let before = cached
        lock.unlock()
        var found = [(path: String, url: URL, source: Int)]()
        var leftOut = [String]()
        var hasher = Hasher()
        var others = [Int: Int]()
        var folders = [String: (count: Int, kinds: [String: Int])]()
        var counted = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        walking: for (number, source) in sources.enumerated() {
            let base = source.folder.path.hasSuffix("/") ? source.folder.path : source.folder.path + "/"
            guard let walker = FileManager.default.enumerator(at: source.folder, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsPackageDescendants]) else { continue }
            var ignore = Ignore()
            ignore.read(source.folder.appendingPathComponent(".gitignore"), under: "")
            var inSource = [(path: String, url: URL, source: Int)]()
            for case let url as URL in walker {
                let name = url.lastPathComponent
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base), let values = try? url.resourceValues(forKeys: keys) else { continue }
                let relative = String(path.dropFirst(base.count))
                if values.isDirectory == true {
                    let hidden = name.hasPrefix(".") && !Notes.hiddenFoldersKept.contains(name)
                    if hidden || Notes.foldersLeftOut.contains(name.lowercased()) || ignore.matches(relative, isFolder: true) {
                        walker.skipDescendants()
                    } else {
                        ignore.read(url.appendingPathComponent(".gitignore"), under: relative + "/")
                    }
                    continue
                }
                guard values.isRegularFile == true, !name.hasPrefix("."), !ignore.matches(relative, isFolder: false) else { continue }
                let ending = url.pathExtension.lowercased()
                guard Notes.kinds.contains(ending) else {
                    // Not a note: counted, and placed on the map of where things are.
                    guard counted < Notes.mostCounted else { continue }
                    counted += 1
                    others[number, default: 0] += 1
                    let parts = relative.split(separator: "/")
                    let folder = ([Substring(source.name)] + parts.dropLast().prefix(3)).joined(separator: "/")
                    var entry = folders[folder] ?? (0, [:])
                    entry.count += 1
                    entry.kinds[ending.isEmpty ? name : ending, default: 0] += 1
                    folders[folder] = entry
                    continue
                }
                if source.isBuiltIn, relative.lowercased() == "readme.md" { continue }
                let size = values.fileSize ?? 0
                if size > Notes.largestFile {
                    leftOut.append("\(source.name)/\(relative) is over \(Notes.largestFile / 1_000_000) MB, too big to be a note.")
                    continue
                }
                if found.count + inSource.count >= Notes.mostFiles {
                    leftOut.append("There are more than \(Notes.mostFiles) notes; the rest of \(source.name) and anything after it is not read as notes.")
                    found += inSource.sorted { $0.path < $1.path }
                    break walking
                }
                inSource.append(("\(source.name)/\(relative)", url, number))
                hasher.combine(path)
                hasher.combine(size)
                hasher.combine(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            }
            found += inSource.sorted { $0.path < $1.path }
        }

        // The map: a line for each folder, the fullest first.
        let sorted = folders.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        var lines = sorted.prefix(40).map { folder, entry -> String in
            let kinds = entry.kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key).joined(separator: ", ")
            return "- \(folder): \(entry.count) \(entry.count == 1 ? "file" : "files") (\(kinds))"
        }
        if sorted.count > 40 { lines.append("- and \(sorted.count - 40) more folders with fewer files") }
        // The map is not part of what makes the notes "changed": a file of code added or
        // taken away must not start the brain's program again in the middle of a meeting.
        let map = lines.joined(separator: "\n")

        let signature = hasher.finalize()
        if let before, before.signature == signature { return keep(before) }

        var files = [Notes.File]()
        var perSource = [Int: (files: Int, characters: Int)]()
        for entry in found {
            guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
                leftOut.append("\(entry.path) is not text that can be read (it is not UTF-8).")
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            files.append(Notes.File(path: entry.path, text: text))
            let so = perSource[entry.source] ?? (0, 0)
            perSource[entry.source] = (so.files + 1, so.characters + text.count)
        }
        let counts = sources.enumerated().map { number, source in
            Notes.Count(name: source.name, files: perSource[number]?.files ?? 0, characters: perSource[number]?.characters ?? 0,
                        others: others[number] ?? 0)
        }
        return keep(Notes(files: files, counts: counts, leftOut: leftOut, map: map, signature: signature))
    }

    private func keep(_ notes: Notes) -> Notes {
        lock.lock()
        cached = notes
        walkedAt = Date()
        walking = false
        lock.unlock()
        return notes
    }
}

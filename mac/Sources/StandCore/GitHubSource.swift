import Darwin
import Foundation

// Notes from a GitHub repository. The method is Noteling's (its LinkedTools): no git, only
// GitHub's REST API. One cheap request asks for the newest commit of a branch; when that
// has changed, the commit is downloaded as an archive and unpacked into `linked/` in the
// project, replacing the copy from before in one step. Only notes are unpacked.

/// A repository on GitHub, from whatever was pasted for it: the page's address (with or
/// without `.git`, or deeper, like the `/tree/main/docs` a browser shows), an SSH address
/// (`git@host:owner/repo.git`), or just `owner/repo` for github.com.
public struct RepoAddress: Equatable, Sendable {
    public let host: String // lowercased, without the port
    public var port: Int?
    public let owner: String
    public let repo: String

    public static let example = "https://github.com/your-team/handbook"

    public var name: String { "\(owner)/\(repo)" }
    private var authority: String { port.map { "\(host):\($0)" } ?? host }
    public var webURL: String { "https://\(authority)/\(owner)/\(repo)" }
    /// GitHub's REST API for the host: api.github.com for github.com, `api.<host>` for
    /// GitHub Enterprise Cloud with data residency, `<host>/api/v3` for GitHub Enterprise Server.
    var apiBase: String {
        if host == "github.com" { return "https://api.github.com" }
        if host.hasSuffix(".ghe.com") { return "https://api.\(host)" }
        return "https://\(authority)/api/v3"
    }

    /// The repository, and the branch and folder when the address names them
    /// (`…/tree/<branch>/<folder>`; a branch with a slash in its name has to be set by hand).
    public static func parse(_ text: String) throws -> (address: RepoAddress, branch: String?, path: String?) {
        let notAnAddress = StandError("That isn't a repository address. Paste the address of the repository's page, like \(example).")
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { throw notAnAddress }
        if !s.contains("://"), let colon = s.firstIndex(of: ":") {
            // `[user@]host:owner/repo.git`, unless the colon starts a port (`host:8443/owner/repo`).
            let before = s[..<colon], after = s[s.index(after: colon)...]
            let port = after.prefix { $0 != "/" }
            if before.contains("@") || port.isEmpty || !port.allSatisfy(\.isNumber) {
                s = "ssh://" + (before.split(separator: "@").last.map(String.init) ?? "") + "/" + after
            }
        }
        if !s.contains("://") {
            // `owner/repo` alone means github.com.
            let pieces = s.split(separator: "/")
            s = pieces.count == 2 && !pieces[0].contains(".") ? "https://github.com/" + s : "https://" + s
        }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              ["https", "http", "ssh", "git", "git+ssh"].contains(scheme),
              var host = c.host?.lowercased(), !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw notAnAddress }
        // A host has a dot in it. Without one this is something else, such as the path of a folder that is not there.
        guard host.contains(".") else { throw notAnAddress }
        var parts = c.path.split(separator: "/").map(String.init)
        if host == "www.github.com" { host = "github.com" }
        if host == "api.github.com" || (host.hasPrefix("api.") && host.hasSuffix(".ghe.com")) {
            host = host == "api.github.com" ? "github.com" : String(host.dropFirst(4))
            if parts.first == "repos" { parts.removeFirst() }
        } else if parts.starts(with: ["api", "v3", "repos"]) {
            parts.removeFirst(3)
        }
        guard parts.count >= 2 else {
            throw StandError("That address names no repository. It needs the owner and the repository's name, like \(example).")
        }
        let owner = parts[0]
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isName(owner), isName(repo) else { throw notAnAddress }
        var branch: String?, path: String?
        if parts.count >= 4, ["tree", "blob"].contains(parts[2]) {
            branch = parts[3]
            if parts.count > 4 { path = parts[4...].joined(separator: "/") }
        }
        // An SSH port is not the web's; a web address keeps its own.
        return (RepoAddress(host: host, port: scheme == "https" ? c.port : nil, owner: owner, repo: repo), branch, path)
    }

    private static func isName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

/// A GitHub repository as a source of notes: which branch, which folder inside it, and how to sign in.
public struct RepoLink: Sendable {
    public var address: RepoAddress
    /// Empty means the repository's default branch.
    public var branch: String
    /// A folder inside the repository, or empty for all of it.
    public var path: String
    /// "$NAME" for a secret in .env, "gh" for the GitHub CLI's own login, nil for a public repository.
    public var token: String?

    /// The name of its copy's folder under linked/.
    public var slug: String {
        var parts = [String]()
        if address.host != "github.com" { parts.append(address.host) }
        parts += [address.owner, address.repo]
        let slug = parts.joined(separator: "-") + (branch.isEmpty ? "" : "@" + branch)
        return String(slug.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) ? $0 : "-" })
    }
}

/// GitHub would not show a repository to a request that carried no token. It may be private.
struct MightNeedToken: Error, CustomStringConvertible {
    let description: String
}

/// One repository through GitHub's REST API: the newest commit of a branch, and an archive
/// of one commit. The token goes to the API, and on a redirect only to the repository's
/// host and its subdomains (GitHub's download host is one).
struct GitHubRepo {
    let address: RepoAddress
    var token: String?
    var session: URLSession = LinkedRepos.session

    private var authorization: String? {
        let t = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : "Bearer \(t)"
    }

    /// The commit at the tip of `branch` (the default branch when it is empty), or nil when
    /// it is still the one `etag` was given for. That answer does not count against GitHub's
    /// hourly limit, so checking every ten minutes costs nothing while nothing changes.
    func headCommit(branch: String, etag: String?) async throws -> (sha: String, etag: String?)? {
        let ref = branch.isEmpty ? "HEAD" : (branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)
        let (data, response) = try await load("commits/\(ref)", accept: "application/vnd.github.sha", etag: etag) { request, guarding in
            try await session.data(for: request, delegate: guarding)
        }
        if response.statusCode == 304 { return nil }
        try verify(response, body: data, branch: branch)
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else {
            throw StandError("\(address.host) didn't answer the way GitHub does. Check that the address is the repository's page; a sign-in page on your network can cause this too.")
        }
        return (sha, response.value(forHTTPHeaderField: "ETag"))
    }

    /// The archive of commit `sha`, saved at `file`.
    func downloadArchive(sha: String, to file: URL) async throws {
        let (temporary, response) = try await load("tarball/\(sha)", accept: "application/vnd.github+json", etag: nil) { request, guarding in
            try await session.download(for: request, delegate: guarding)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let head: Data = {
            guard let handle = try? FileHandle(forReadingFrom: temporary) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        }()
        try verify(response, body: head, branch: nil)
        guard head.starts(with: [0x1f, 0x8b]) else { // gzip
            throw StandError("The download from \(response.url?.host ?? address.host) wasn't an archive of the repository.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
        guard size <= LinkedRepos.largestArchive else {
            throw StandError("\(address.name) is \(size / 1_000_000) MB to download, more than the \(LinkedRepos.largestArchive / 1_000_000) MB Stand keeps a copy of. Link a repository of documents, or use a folder on this Mac.")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func load<T>(_ path: String, accept: String, etag: String?,
                         _ send: (URLRequest, URLSessionTaskDelegate) async throws -> (T, URLResponse)) async throws -> (T, HTTPURLResponse) {
        guard let url = URL(string: "\(address.apiBase)/repos/\(address.owner)/\(address.repo)/\(path)") else {
            throw StandError("That isn't a repository address. Paste the address of the repository's page, like \(RepoAddress.example).")
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Stand", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (value, response) = try await send(request, RedirectGuard(host: address.host, authorization: authorization))
            guard let http = response as? HTTPURLResponse else {
                throw StandError("\(address.host) didn't answer the way GitHub does. Check that the address is the repository's page.")
            }
            return (value, http)
        } catch let error as URLError {
            let host = error.failingURL?.host ?? url.host ?? address.host
            throw StandError("Couldn't reach \(host): \(Self.reason(error))")
        }
    }

    /// Why a connection failed, in a few plain words.
    static func reason(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "this Mac isn't online."
        case .cannotFindHost, .dnsLookupFailed: return "its name couldn't be looked up."
        case .cannotConnectToHost: return "it didn't accept the connection."
        case .timedOut: return "it didn't answer in time."
        case .networkConnectionLost: return "the connection dropped."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "this Mac doesn't trust its certificate."
        default:
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasSuffix(".") ? text : text + "."
        }
    }

    /// Anything but success becomes a sentence: what happened, where, and what to do.
    private func verify(_ response: HTTPURLResponse, body: Data, branch: String?) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let host = address.host
        let said = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String
        let message = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = message.isEmpty || message.count > 120 || message.contains(where: \.isNewline) ? "" : " (“\(message)”)"
        let addToken = "If it is private, sign in with the GitHub CLI on this Mac (`gh auth login`) and Stand will use that, or give the source a \"token\" in brain.json: \"$NAME\" for a secret in .env."
        switch status {
        case 401 where authorization == nil:
            throw MightNeedToken(description: "\(host) needs a token to read \(address.name). \(addToken)")
        case 401:
            throw StandError("\(host) refused the token for \(address.name). It may have expired or been mistyped.")
        case 403, 429:
            if status == 429 || response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || message.lowercased().contains("rate limit") {
                throw StandError("\(host) turned Stand away for asking too often\(quoted). It will try again later."
                    + (authorization == nil ? " A source with a token is allowed far more requests." : ""))
            }
            if authorization == nil { throw MightNeedToken(description: "\(host) didn't allow reading \(address.name)\(quoted). \(addToken)") }
            throw StandError("\(host) didn't allow reading \(address.name)\(quoted). Check that the token can read this repository.")
        case 409:
            throw StandError("\(address.name) on \(host) is empty: nothing has been pushed to it yet.")
        case 422 where branch != nil:
            throw StandError("\(address.name) on \(host) has no \(branch ?? "") branch\(quoted).")
        case 404:
            let what = (branch ?? "").isEmpty ? address.name : "\(address.name) with a \(branch ?? "") branch"
            if authorization == nil { throw MightNeedToken(description: "\(host) couldn't find \(what). Check the address. \(addToken)") }
            throw StandError("\(host) couldn't find \(what), or the login used can't see it. Check the address.")
        default:
            throw StandError("\(host) answered with an error (HTTP \(status)).")
        }
    }
}

/// Keeps the token on a redirect within the repository's host and its subdomains, and takes it off anywhere else.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let host: String
    let authorization: String?

    init(host: String, authorization: String?) {
        self.host = host
        self.authorization = authorization
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        let target = request.url?.host?.lowercased() ?? ""
        let trusted = request.url?.scheme?.lowercased() == "https" && (target == host || target.hasSuffix("." + host))
        next.setValue(trusted ? authorization : nil, forHTTPHeaderField: "Authorization")
        return next
    }
}

/// The copies of linked repositories in the project's `linked/` folder, and keeping them current.
public enum LinkedRepos {
    /// How one repository's copy stands after a check.
    public struct Status: Sendable {
        public let name: String
        public let place: String
        /// The commit the copy is of, or nil when there is no copy yet.
        public var sha: String?
        public var updatedAt: Date?
        public var checkedAt: Date?
        /// Why the last check failed. The copy from before, if any, is still in use.
        public var error: String?
        /// True when this check brought a new copy.
        public var changed = false

        /// One line for the panel and the log.
        public func line(now: Date = Date()) -> String {
            if let error {
                guard sha != nil, let updatedAt else { return "\(name): \(error)" }
                return "\(name): couldn't update. \(error) Using the copy from \(LinkedRepos.ago(updatedAt, now: now))."
            }
            guard let sha else { return "\(name): not downloaded yet" }
            return "\(name): \(place) at \(sha.prefix(7)), updated \(LinkedRepos.ago(updatedAt ?? now, now: now))"
        }
    }

    /// What `linked/<slug>.json` holds: which copy is installed and how the last check went.
    struct Record: Codable {
        var url = ""
        var branch = ""
        var sha: String?
        var etag: String?
        /// "gh" once the GitHub CLI's login turned out to be needed, so later checks start with it.
        var auth: String?
        var updatedAt: Date?
        var checkedAt: Date?
        var error: String?
        /// What the copy was unpacked with: nil for the first copies, which held documents
        /// only, `Record.notesAndCode` since code is kept too. An older copy is fetched again.
        var holds: Int?
        static let notesAndCode = 2
    }

    public static let checkInterval: TimeInterval = 600
    static let largestArchive = 100_000_000

    /// No cache, so a check sees a change pushed a minute ago.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    public static func folder(root: URL) -> URL { root.appendingPathComponent("linked") }

    /// Checks every linked repository among `sources` and brings in a new copy where the
    /// branch has moved. Never throws: a repository that can't be checked keeps the copy
    /// it has, and its status says why.
    public static func refresh(root: URL, sources: [NotesSource]) async -> [Status] {
        clearLeftovers(root: root)
        return await withTaskGroup(of: (Int, Status).self) { group in
            for (index, source) in sources.enumerated() where source.repo != nil {
                group.addTask { (index, await gate.run(source.repo!.slug) { await refreshOne(source, root: root) }) }
            }
            var found = [(Int, Status)]()
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Removes what an update that was cut short left behind, once it is an hour old.
    private static func clearLeftovers(root: URL) {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: folder(root: root), includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for url in entries where url.lastPathComponent.hasPrefix(".incoming-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(modified) > 3600 { try? manager.removeItem(at: url) }
        }
    }

    /// The same, but gives up waiting after `seconds` and returns nil. The check itself
    /// carries on, and the notes are read again once it has brought anything new.
    public static func refresh(root: URL, sources: [NotesSource], waitingAtMost seconds: Double) async -> [Status]? {
        guard sources.contains(where: { $0.repo != nil }) else { return [] }
        let work = Task { await refresh(root: root, sources: sources) }
        return await withCheckedContinuation { (done: CheckedContinuation<[Status]?, Never>) in
            let once = Once()
            Task { let value = await work.value; if once.claim() { done.resume(returning: value) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { done.resume(returning: nil) }
            }
        }
    }

    /// How each linked repository's copy stands, from the records on disk. No network.
    public static func statuses(root: URL, sources: [NotesSource]) -> [Status] {
        sources.compactMap { source in
            guard let link = source.repo else { return nil }
            return status(source, record: record(root: root, slug: link.slug), root: root)
        }
    }

    // MARK: One repository

    private static let gate = Gate()

    /// One check at a time per repository, however many callers ask.
    private actor Gate {
        private var running = [String: Task<Status, Never>]()

        func run(_ key: String, _ work: @escaping @Sendable () async -> Status) async -> Status {
            if let task = running[key] { return await task.value }
            let task = Task { await work() }
            running[key] = task
            let value = await task.value
            running[key] = nil
            return value
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func recordFile(root: URL, slug: String) -> URL {
        folder(root: root).appendingPathComponent("\(slug).json")
    }

    private static func record(root: URL, slug: String) -> Record? {
        guard let data = try? Data(contentsOf: recordFile(root: root, slug: slug)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    private static func save(_ record: Record, root: URL, slug: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: folder(root: root), withIntermediateDirectories: true)
        try? data.write(to: recordFile(root: root, slug: slug), options: .atomic)
    }

    private static func status(_ source: NotesSource, record: Record?, root: URL, changed: Bool = false) -> Status {
        let copy = source.repo.map { folder(root: root).appendingPathComponent($0.slug) }
        let installed = copy.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return Status(name: source.name, place: source.place, sha: installed ? record?.sha : nil, updatedAt: record?.updatedAt,
                      checkedAt: record?.checkedAt, error: record?.error, changed: changed)
    }

    private static func refreshOne(_ source: NotesSource, root: URL) async -> Status {
        guard let link = source.repo else { return Status(name: source.name, place: source.place) }
        let copy = folder(root: root).appendingPathComponent(link.slug)
        var next = record(root: root, slug: link.slug) ?? Record()
        let installed = FileManager.default.fileExists(atPath: copy.path) && next.sha != nil
            && next.url == link.address.webURL && next.branch == link.branch && next.holds == Record.notesAndCode
        next.checkedAt = Date()

        /// One check with one way of signing in. Returns true when it brought a new copy.
        func check(token: String?) async throws -> Bool {
            let client = GitHubRepo(address: link.address, token: token)
            guard let head = try await client.headCommit(branch: link.branch, etag: installed ? next.etag : nil) else { return false }
            if installed, next.sha == head.sha {
                next.etag = head.etag
                return false
            }
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("stand-linked-\(UUID().uuidString).tar.gz")
            defer { try? FileManager.default.removeItem(at: archive) }
            try await client.downloadArchive(sha: head.sha, to: archive)
            try await install(archive: archive, as: copy)
            let now = Date()
            next = Record(url: link.address.webURL, branch: link.branch, sha: head.sha, etag: head.etag, auth: next.auth, updatedAt: now, checkedAt: now,
                          holds: Record.notesAndCode)
            return true
        }

        do {
            var changed: Bool
            let named = link.token ?? (next.auth == "gh" ? "gh" : nil)
            do {
                changed = try await check(token: try await resolve(token: named, host: link.address.host, root: root))
            } catch let refusal as MightNeedToken {
                // Nobody is asked whether the repository is private. If GitHub will not show
                // it without a token, the login the GitHub CLI already has on this Mac is tried.
                guard let login = try? await resolve(token: "gh", host: link.address.host, root: root) else { throw refusal }
                do {
                    changed = try await check(token: login)
                    next.auth = "gh"
                } catch is MightNeedToken {
                    throw refusal
                } catch {
                    throw StandError("\(error) (This was with the GitHub CLI's login; without any login, GitHub did not show the repository at all.)")
                }
            }
            next.error = nil
            save(next, root: root, slug: link.slug)
            return status(source, record: next, root: root, changed: changed)
        } catch {
            next.error = "\(error)"
            save(next, root: root, slug: link.slug)
            return status(source, record: next, root: root)
        }
    }

    /// The token a source asks for: a secret named in .env, the GitHub CLI's login, or none.
    private static func resolve(token: String?, host: String, root: URL) async throws -> String? {
        guard let token, !token.isEmpty else { return nil }
        if token == "gh" {
            let manager = FileManager.default
            let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
                + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            guard let gh = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
                throw StandError("The source asks for the GitHub CLI's login, but `gh` was not found on this Mac.")
            }
            let ran = try await Subprocess.run(gh, ["auth", "token", "--hostname", host], timeout: 10)
            let value = String(decoding: ran.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard ran.status == 0, !value.isEmpty else {
                throw StandError("The GitHub CLI has no login for \(host). Run `gh auth login`, or give the source a token of its own.")
            }
            return value
        }
        if token.hasPrefix("$") {
            let name = String(token.dropFirst())
            guard let value = Project.setting(name, root: root) else {
                throw StandError("The source needs a secret that is not set: \(name). Add it to .env.")
            }
            return value
        }
        throw StandError("brain.json: a source's \"token\" is either \"$NAME\", for a secret in .env, or \"gh\". Never write the token itself there.")
    }

    /// Unpacks the notes in a GitHub archive next to the installed copy, and swaps them in
    /// with a single rename. A failure before that leaves the installed copy as it was.
    private static func install(archive: URL, as copy: URL) async throws {
        let manager = FileManager.default
        let incoming = copy.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: incoming) }
        let fresh = incoming.appendingPathComponent("copy")
        try manager.createDirectory(at: fresh, withIntermediateDirectories: true)

        // Only the notes and the code are unpacked. tar stops with an error on a pattern that
        // matches nothing, so the patterns are made from the endings the archive actually has.
        let listed = try await Subprocess.run("/usr/bin/tar", ["-tzf", archive.path], timeout: 120)
        guard listed.status == 0 else { throw StandError("The download couldn't be read as an archive. Nothing was changed.") }
        var endings = Set<String>()
        var names = Set<String>()
        for line in String(decoding: listed.output, as: UTF8.self).split(whereSeparator: \.isNewline) where !line.hasSuffix("/") {
            let file = String(line) as NSString
            let ending = file.pathExtension
            if Notes.kinds.contains(ending.lowercased()) || Notes.codeKinds.contains(ending.lowercased()) {
                endings.insert(ending)
            } else if Notes.codeNames.contains(file.lastPathComponent.lowercased()) {
                names.insert(file.lastPathComponent)
            }
        }
        if !endings.isEmpty || !names.isEmpty {
            // GitHub's archives hold one folder at the top; --strip-components drops it. bsdtar refuses
            // entries with `..` in their path, or that would write through a link.
            let includes = endings.sorted().flatMap { ["--include", "*.\($0)"] } + names.sorted().flatMap { ["--include", "*/\($0)"] }
            let tar = try await Subprocess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", fresh.path, "--strip-components", "1"] + includes, timeout: 180)
            guard tar.status == 0 else {
                let why = String(decoding: tar.errors, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? "tar stopped"
                throw StandError("The download couldn't be unpacked (\(why)). Nothing was changed.")
            }
        }
        dropLinks(in: fresh)
        do { try swap(fresh, into: copy) } catch {
            throw StandError("The new copy couldn't be put in place (\(error.localizedDescription)). The copy from before is still in use.")
        }
    }

    /// Takes every link out of a new copy, so that no file in it stands for one elsewhere on this Mac.
    private static func dropLinks(in folder: URL) {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        var links = [URL]()
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            links.append(url)
        }
        for url in links { try? manager.removeItem(at: url) }
    }

    /// Puts `new` at `target` in one step. The old copy is swapped to `new`'s place, to be deleted with it.
    private static func swap(_ new: URL, into target: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: target.path) else { try manager.moveItem(at: new, to: target); return }
        if renamex_np(new.path, target.path, UInt32(RENAME_SWAP)) == 0 { return }
        // A volume that can't swap: the old copy goes aside, the new one in, and the old one back if that fails.
        let aside = new.deletingLastPathComponent().appendingPathComponent("previous")
        try manager.moveItem(at: target, to: aside)
        do { try manager.moveItem(at: new, to: target) } catch {
            try? manager.moveItem(at: aside, to: target)
            throw error
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400:
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }
}

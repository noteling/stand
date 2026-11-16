import Foundation

/// What Stand shows while it gives a talk: pages, one at a time, for the audience to see.
///
/// The screen is not a performer of its own. It shows the page that belongs to the place
/// in the talk the stage manager keeps (`StandSession`), and it is moved only between
/// sections, in the silence that is already there: first the page, then a look at what
/// came up, and only then is Stand told to speak about it. That order is the whole of the
/// coordination. A hand, an eye and a voice that each kept their own time would drift
/// apart by seconds: the voice model runs well ahead of its own sound, and its account of
/// where it is can be two seconds off.
///
/// A screen moves and looks in one step, and what it answers is what it saw, not what it
/// was asked for. When a page does not come up, Stand is told so in words, and says so.
public protocol Screen: AnyObject, Sendable {
    /// Shows a page and looks at what came up. It never throws, and it answers within a
    /// few seconds whatever happens: what went wrong is in the answer.
    func show(_ page: TalkPlan.Page) async -> ScreenLook

    /// A section is about to be given under the page that is showing. Finds where on the
    /// page each of its points is written about, so that the page can be brought down to
    /// each as it comes up (`bring`). Answers with how many of the points have a place of
    /// their own: 0 when the whole part fits on the screen, when nothing on the page
    /// matches, or when this screen does not scroll.
    func follow(_ points: [String]) async -> Int

    /// Brings the place of one of those points into view, if it is not in view already: its
    /// own place, or that of the last point before it that has one. Nil when nothing had
    /// to move. This is the one move made while Stand is speaking:
    /// it follows the sound of the talk, a second or two either way, which is close enough
    /// for a page to keep up with a voice and not close enough to point at anything.
    func bring(point: Int) async -> ScreenLook?

    /// Moves the page a screenful down or up, because someone asked.
    func scroll(_ direction: ScreenScroll) async -> ScreenLook
}

public enum ScreenScroll: String, Sendable {
    /// Most of a screenful down, or up.
    case down, up
    /// Back to where the section's part of the page begins.
    case top

    /// The way someone asked for, from the word Stand passed on.
    public init(asked: String) {
        let asked = asked.lowercased()
        if asked.contains("top") || asked.contains("start") || asked.contains("begin") { self = .top }
        else if asked.contains("up") || asked.contains("back") { self = .up }
        else { self = .down }
    }

    /// In a sentence: "has moved down", "is back at the top of this part".
    public var done: String {
        switch self {
        case .down: return "has moved down"
        case .up: return "has moved up"
        case .top: return "is back at the top of this part"
        }
    }
}

extension Screen {
    public func follow(_ points: [String]) async -> Int { 0 }
    public func bring(point: Int) async -> ScreenLook? { nil }
    public func scroll(_ direction: ScreenScroll) async -> ScreenLook {
        ScreenLook(shown: false, showing: "", problem: "This screen cannot be scrolled.", how: "nothing", seconds: 0)
    }
}

/// What was on the screen after it was asked to show a page.
public struct ScreenLook: Sendable {
    /// The page asked for is what the audience now sees.
    public let shown: Bool
    /// What is on the screen now, in the page's own words: its heading, or its title.
    /// Empty when that could not be made out.
    public let showing: String
    /// Why the page is not showing, in a sentence, when it is not.
    public let problem: String?
    /// How the look was taken: "the page itself", or "a picture of it".
    public let how: String
    /// How long moving and looking took.
    public let seconds: Double
    /// A picture of the screen as it was, as a PNG file's bytes, when one was taken.
    public let picture: Data?

    public init(shown: Bool, showing: String, problem: String? = nil, how: String, seconds: Double, picture: Data? = nil) {
        self.shown = shown
        self.showing = showing
        self.problem = problem
        self.how = how
        self.seconds = seconds
        self.picture = picture
    }

    /// The same look, said to have failed for a reason of the caller's.
    public func failed(_ problem: String) -> ScreenLook {
        ScreenLook(shown: false, showing: showing, problem: problem, how: how, seconds: seconds, picture: picture)
    }
}

extension TalkPlan {
    /// The page a section of a talk is given with. The plan names it on a line of its own
    /// under the section's heading:
    ///
    ///     Show: handbook/architecture.md # How a question is answered
    ///     Show: https://wiki.example.com/pages/1234 # Storage
    ///
    /// Before the `#` is the place: a document in one of the folders Stand was given, by
    /// the folder's name and the path inside it, or an address. After it is the heading to
    /// bring to the top; without one, the page is shown from its start.
    public struct Page: Hashable, Sendable {
        public let place: String
        public let heading: String?

        public init(place: String, heading: String? = nil) {
            self.place = place
            self.heading = heading
        }

        /// The page a line of a plan names, or nil when it is not a "Show:" line.
        public init?(line: String) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("show:") else { return nil }
            let rest = line.dropFirst("show:".count).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            // An address may carry a "#" of its own, with no space before it: that one is the page's, not the plan's.
            if let mark = rest.range(of: " #") ?? (rest.contains("://") ? nil : rest.range(of: "#")) {
                place = rest[..<mark.lowerBound].trimmingCharacters(in: .whitespaces)
                let heading = rest[mark.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
                self.heading = heading.isEmpty ? nil : heading
            } else {
                place = rest
                heading = nil
            }
            guard !place.isEmpty else { return nil }
        }

        /// The page in a few words, for a message or a log: "How a question is answered" in handbook/architecture.md.
        public var words: String { heading.map { "\"\($0)\" in \(place)" } ?? place }
    }

    /// A plan without its "Show:" lines, for a talk given with no screen: Stand should not
    /// read of pages nobody will see.
    public static func withoutPages(_ plan: String) -> String {
        plan.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { Page(line: String($0)) == nil }
            .joined(separator: "\n")
    }
}

/// Where the pages a talk names are.
public enum Pages {
    /// The pages a plan names that cannot be shown, each in a sentence: a document that is
    /// not in the folders Stand was given, or a heading its document does not have. This is
    /// for the moment a talk has been prepared, so that its human hears of a page that will
    /// not come up before the meeting and not in it. An address is not fetched for this:
    /// its headings are checked only when the page is one of the sources, against its copy.
    public static func missing(in plan: String, sources: [NotesSource]) -> [String] {
        var problems = [String]()
        for section in TalkPlan.sections(in: plan) {
            guard let page = section.show else { continue }
            do {
                let place = try locate(page.place, sources: sources)
                guard let heading = page.heading else { continue }
                let text: String
                switch place {
                case .document(let url, _): text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                case .address(let address):
                    // A page that was read from the browser is kept as a copy, and its headings can be checked there.
                    guard let copy = PageCopies.text(of: address, sources: sources) else { continue }
                    text = copy
                }
                if !has(heading, in: text) { problems.append("Section \(section.number): \(page.place) has no heading called \"\(heading)\".") }
            } catch {
                problems.append("Section \(section.number): \(error)")
            }
        }
        return problems
    }

    /// Whether a document has a heading by this name, read as the screen reads it: whatever
    /// the capitals and the marks, the whole heading or the start of it or a part of it.
    static func has(_ heading: String, in markdown: String) -> Bool {
        func plain(_ text: String) -> String {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let wanted = plain(heading)
        guard !wanted.isEmpty else { return true }
        var inCode = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard !inCode, (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { continue }
            // A link in a heading is read by its words, as the page shows it, not by its address.
            let shown = line.dropFirst(hashes).replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
            if plain(shown).contains(wanted) { return true }
        }
        return false
    }

    public enum Place: Sendable {
        /// A document on this Mac, inside one of the folders Stand was given. `name` is how the talk names it.
        case document(URL, name: String)
        /// A page that is fetched: a wiki, a site, an app that serves pages.
        case address(URL)
    }

    /// Finds the page a talk names. A document has to be one of the notes in the folders
    /// Stand was given: the folder is the boundary for what it shows, as it is for what its
    /// brain reads, and a screen that other people are looking at is the last place for
    /// anything else.
    public static func locate(_ place: String, sources: [NotesSource]) throws -> Place {
        let place = place.trimmingCharacters(in: .whitespaces)
        if place.lowercased().hasPrefix("http://") || place.lowercased().hasPrefix("https://") {
            guard let url = URL(string: place), url.host != nil else { throw StandError("\"\(place)\" is not an address a page can be fetched from.") }
            return .address(url)
        }
        guard !place.contains("://") else { throw StandError("Stand shows pages from http and https addresses, and \"\(place)\" is neither.") }
        func inside(_ source: NotesSource, _ path: String) -> URL? {
            let base = source.folder.standardizedFileURL.path
            let url = source.folder.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
            return url
        }
        let parts = place.split(separator: "/", maxSplits: 1).map(String.init)
        var found = [(URL, String)]()
        // By the folder's name first, as the brain names every document: "handbook/pricing/plans.md".
        if parts.count == 2, let source = sources.first(where: { $0.name.lowercased() == parts[0].lowercased() }), let url = inside(source, parts[1]) {
            found = [(url, place)]
        } else {
            // Or by the path alone, when only one folder has such a document.
            found = sources.compactMap { source in inside(source, place).map { ($0, "\(source.name)/\(place)") } }
        }
        guard let (url, name) = found.first else {
            throw StandError("There is no document called \(place) in the folders Stand was given.")
        }
        guard found.count == 1 else { throw StandError("More than one of the folders Stand was given has a document called \(place). Put the folder's name in front of it.") }
        guard !url.lastPathComponent.hasPrefix("."), Notes.kinds.contains(url.pathExtension.lowercased()) else {
            throw StandError("\(place) is not a document Stand shows: it shows the notes in its folders (Markdown and text), and addresses.")
        }
        // A note that is the copy of a page from the browser is never what the audience is
        // shown: the page itself is, at its address, whichever of the two the plan named.
        let path = url.standardizedFileURL.path
        if let page = sources.first(where: { $0.page != nil && path.hasPrefix($0.folder.standardizedFileURL.path + "/") })?.page { return .address(page) }
        return .document(url, name: name)
    }
}

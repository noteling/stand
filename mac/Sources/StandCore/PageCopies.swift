import Foundation

/// Pages read from a person's browser, kept as notes.
///
/// A folder and a GitHub repository are things Stand's brain can read by itself. A page
/// that lives behind a sign-in is not: only the person's own browser has it. So such a
/// page is a source of its own kind. Its human names it by its address, the app reads it
/// through their browser as they see it there, and what it says is kept here as a note,
/// under linked/ like a repository's copy and replaced whole each time it is read again.
///
/// The copy is for the brain: to prepare a talk from, and to look things up in during the
/// meeting. It is never what the audience is shown. A talk shows the page itself, by its
/// address (`Pages.locate` sees to that even when a plan names the copy).
public enum PageCopies {
    /// What a page said when it was read.
    public struct Copy: Sendable {
        public let address: URL
        public let title: String
        /// The page's own words: its headings, paragraphs, lists and tables, as Markdown.
        public let text: String

        public init(address: URL, title: String, text: String) {
            self.address = address
            self.title = title
            self.text = text
        }
    }

    /// What is kept of a page: what its copy is called, and when it was read.
    public struct Kept: Sendable {
        public let title: String
        public let readAt: Date
        public let file: URL
    }

    public static func folder(root: URL) -> URL { LinkedRepos.folder(root: root).appendingPathComponent("pages", isDirectory: true) }

    /// Where the copy of one page is kept: a folder of its own, since a source is a folder.
    public static func folder(for address: URL, root: URL) -> URL {
        folder(root: root).appendingPathComponent(slug(address), isDirectory: true)
    }

    /// What a pasted address becomes in brain.json's "sources".
    public static func source(from text: String) throws -> [String: String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = self.address(text) else {
            throw StandError("\"\(text)\" is not the address of a page. Paste it as the browser shows it, beginning with http:// or https://.")
        }
        return ["page": address.absoluteString]
    }

    /// A page's address, when the text is one.
    public static func address(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let address = URL(string: text), let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = address.host, !host.isEmpty else { return nil }
        return address
    }

    /// What the brain and the panel call the page: the last part of its address that says something.
    public static func name(for address: URL) -> String {
        let last = address.pathComponents.last { $0 != "/" }.map { ($0 as NSString).deletingPathExtension } ?? ""
        let asked = URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.compactMap { item in item.value.map { "\(item.name)-\($0)" } }.first ?? ""
        let wanted = !last.isEmpty && last.lowercased() != "index" ? last : !asked.isEmpty ? asked : address.host ?? "page"
        let plain = String(tidy(wanted.removingPercentEncoding ?? wanted).prefix(40))
        return plain.isEmpty ? "page" : plain
    }

    /// The address as a person would say it, for the panel: without "https://", and not too long.
    public static func short(_ address: URL) -> String {
        var text = address.absoluteString
        for start in ["https://", "http://"] where text.hasPrefix(start) { text = String(text.dropFirst(start.count)) }
        return text.count > 64 ? text.prefix(61) + "…" : text
    }

    /// Keeps a copy, in place of the one that was there.
    @discardableResult
    public static func save(_ copy: Copy, through browser: String, root: URL) throws -> URL {
        let folder = self.folder(for: copy.address, root: root)
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        stamp.locale = Locale(identifier: "en_GB")
        let title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = """
        Address: \(copy.address.absoluteString)
        Title: \(title.replacingOccurrences(of: "\n", with: " "))
        Read: \(stamp.string(from: Date())), through \(browser)

        This is a copy of a page as Stand's human sees it in their browser, kept so that Stand can speak about it. In a talk, the page itself is what is shown, by the address above.

        \(copy.text.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        let named = String(tidy(title).prefix(60))
        let file = folder.appendingPathComponent((named.isEmpty ? "page" : named) + ".md")
        try note.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The copy that is kept of a page, if it has been read.
    public static func kept(_ address: URL, root: URL) -> Kept? {
        kept(in: folder(for: address, root: root))
    }

    static func kept(in folder: URL) -> Kept? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              let file = files.first(where: { $0.pathExtension == "md" }),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let title = text.split(separator: "\n").first { $0.hasPrefix("Title: ") }.map { String($0.dropFirst("Title: ".count)) } ?? ""
        let readAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        return Kept(title: title, readAt: readAt, file: file)
    }

    /// What the kept copy of a page says, when one of the sources is that page: to check a
    /// heading against, without fetching anything.
    static func text(of address: URL, sources: [NotesSource]) -> String? {
        guard let source = sources.first(where: { $0.page.map { same($0, address) } ?? false }), let kept = kept(in: source.folder) else { return nil }
        return try? String(contentsOf: kept.file, encoding: .utf8)
    }

    /// The same page, whatever follows a "#" in either address.
    static func same(_ one: URL, _ other: URL) -> Bool {
        func bare(_ address: URL) -> String {
            var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            if parts?.path.isEmpty ?? false { parts?.path = "/" }
            return (parts?.string ?? address.absoluteString).lowercased()
        }
        return bare(one) == bare(other)
    }

    /// A name for the folder a page's copy is kept in: readable, and its own. Two addresses
    /// that read alike once the marks are out of them still get two folders.
    static func slug(_ address: URL) -> String {
        var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        parts?.scheme = nil
        let whole = parts?.string ?? address.absoluteString
        // The same every time: Swift's own hashing changes from one run to the next.
        var hash: UInt32 = 2_166_136_261
        for byte in whole.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let readable = String(tidy(whole).prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (readable.isEmpty ? "page" : readable) + "-" + String(format: "%08x", hash)
    }

    /// Letters and digits, with one "-" for whatever stood between them.
    private static func tidy(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isLetter || character.isNumber { out.append(character) } else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

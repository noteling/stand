import Foundation

/// A document's Markdown as a page to show: large type, one column, each heading something
/// that can be brought to the top. Only what documents commonly use: headings, paragraphs,
/// lists, tables, code, quotes, links and pictures.
enum MarkdownPage {
    static func html(_ markdown: String, title: String, folder: URL?) -> String {
        var out = [String]()
        var paragraph = [String]()
        var list: String? // "ul" or "ol" while a list is open
        var table = [[String]]()
        var code: [String]?
        var quote = [String]()

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + inline(paragraph.joined(separator: " "), folder: folder) + "</p>")
            paragraph = []
        }
        func flushList() {
            guard let open = list else { return }
            out.append("</\(open)>")
            list = nil
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            out.append("<blockquote>" + inline(quote.joined(separator: " "), folder: folder) + "</blockquote>")
            quote = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            var rows = table
            table = []
            var markup = "<table>"
            // A row of dashes under the first row makes that row the heading.
            if rows.count >= 2, rows[1].allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) {
                markup += "<thead><tr>" + rows[0].map { "<th>" + inline($0, folder: folder) + "</th>" }.joined() + "</tr></thead>"
                rows.removeFirst(2)
            }
            markup += "<tbody>" + rows.map { "<tr>" + $0.map { "<td>" + inline($0, folder: folder) + "</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
            out.append(markup)
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
            flushTable()
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = code {
                if line.hasPrefix("```") {
                    out.append("<pre><code>" + escape(open.joined(separator: "\n")) + "</code></pre>")
                    code = nil
                } else {
                    code = open + [raw]
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                code = []
                continue
            }
            if line.isEmpty {
                flushAll()
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                flushAll()
                let text = line.dropFirst(hashes).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                out.append("<h\(hashes)>" + inline(text, folder: folder) + "</h\(hashes)>")
                continue
            }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), Set(line).count == 1 {
                flushAll()
                out.append("<hr>")
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                flushList()
                flushQuote()
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                table.append(cells)
                continue
            }
            flushTable()
            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let numbered = line.prefix { $0.isNumber }
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            let isNumbered = !numbered.isEmpty && (line.dropFirst(numbered.count).hasPrefix(". ") || line.dropFirst(numbered.count).hasPrefix(") "))
            if isBullet || isNumbered {
                flushParagraph()
                let kind = isBullet ? "ul" : "ol"
                if list != kind {
                    flushList()
                    out.append("<\(kind)>")
                    list = kind
                }
                let text = isBullet ? String(line.dropFirst(2)) : String(line.dropFirst(numbered.count + 2))
                out.append("<li style=\"margin-left:\(Double(indent / 2) * 1.2)em\">" + inline(text, folder: folder) + "</li>")
                continue
            }
            // More of the list item above, or of the paragraph.
            if list != nil, indent >= 2, !out.isEmpty, out[out.count - 1].hasSuffix("</li>") {
                out[out.count - 1] = String(out[out.count - 1].dropLast(5)) + " " + inline(line, folder: folder) + "</li>"
                continue
            }
            flushList()
            paragraph.append(line)
        }
        if let open = code { out.append("<pre><code>" + escape(open.joined(separator: "\n")) + "</code></pre>") }
        flushAll()

        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light; }
        body { font: 21px/1.55 -apple-system, "Helvetica Neue", sans-serif; color: #1c1c1e; background: #fdfdfc; max-width: 1040px; margin: 0 auto; padding: 26px 56px 85vh; }
        h1, h2, h3, h4 { line-height: 1.2; margin: 1.5em 0 0.5em; scroll-margin-top: 16px; }
        h1 { font-size: 2.1em; } h2 { font-size: 1.6em; border-top: 1px solid #ddd; padding-top: 0.7em; } h3 { font-size: 1.25em; }
        code { font: 0.86em ui-monospace, Menlo, monospace; background: #f0f0ee; padding: 0.1em 0.3em; border-radius: 4px; }
        pre { background: #f0f0ee; padding: 14px 18px; border-radius: 8px; overflow-x: auto; } pre code { background: none; padding: 0; }
        table { border-collapse: collapse; margin: 1em 0; font-size: 0.9em; } th, td { border: 1px solid #d5d5d2; padding: 7px 12px; text-align: left; vertical-align: top; }
        th { background: #f0f0ee; } blockquote { margin: 1em 0; padding: 0.2em 1em; border-left: 4px solid #c9c9c6; color: #444; }
        img { max-width: 100%; } a { color: #1a5fb4; } li { margin: 0.25em 0; } hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        </style></head><body>
        \(out.joined(separator: "\n"))
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The marks inside a line: code, pictures, links, bold and italic.
    private static func inline(_ text: String, folder: URL?) -> String {
        // Code first, so that nothing inside it is taken for a mark.
        var pieces = [String]()
        for (index, part) in text.components(separatedBy: "`").enumerated() {
            if index % 2 == 1 {
                pieces.append("<code>" + escape(part) + "</code>")
                continue
            }
            var html = escape(part)
            html = replace(html, #"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#) { groups in picture(alt: groups[1], path: groups[2], folder: folder) }
            html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
            html = replace(html, #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
            html = replace(html, #"__([^_]+)__"#) { "<strong>\($0[1])</strong>" }
            html = replace(html, #"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
            html = replace(html, #"(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#) { "<em>\($0[1])</em>" }
            pieces.append(html)
        }
        return pieces.joined()
    }

    /// A picture the document points to, put into the page itself, when it is a picture
    /// file beside the document. Anything else is named and not shown.
    private static func picture(alt: String, path: String, folder: URL?) -> String {
        let kinds = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp"]
        if let folder, !path.contains("://"), let kind = kinds[(path as NSString).pathExtension.lowercased()] {
            let url = folder.appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
            if let data = try? Data(contentsOf: url), data.count < 3_000_000 {
                return "<img alt=\"\(alt)\" src=\"data:\(kind);base64,\(data.base64EncodedString())\">"
            }
        }
        return "<em>(picture: \(alt.isEmpty ? path : alt))</em>"
    }

    private static func replace(_ text: String, _ pattern: String, with make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let whole = text as NSString
        var result = ""
        var at = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            result += whole.substring(with: NSRange(location: at, length: match.range.location - at))
            result += make((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : whole.substring(with: match.range(at: $0)) })
            at = match.range.location + match.range.length
        }
        return result + whole.substring(from: at)
    }
}

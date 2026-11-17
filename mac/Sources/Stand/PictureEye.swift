import AppKit
import Vision

/// The eye that works on any screen: read the words in a picture of it, on this Mac, with
/// no model. About four tenths of a second for a window.
enum PictureEye {
    struct Line {
        let text: String
        /// Where the line is, from 0 at the top of the picture to 1 at the bottom.
        let fromTop: Double
    }

    static func read(_ png: Data) async -> [Line]? {
        await Task.detached {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            return (request.results ?? []).compactMap { seen -> Line? in
                guard let text = seen.topCandidates(1).first?.string else { return nil }
                return Line(text: text, fromTop: 1 - Double(seen.boundingBox.maxY))
            }.sorted { $0.fromTop < $1.fromTop }
        }.value
    }

    /// The line that says what was looked for: most of its longer words, whatever the capitals and the marks.
    static func find(_ wanted: String, in lines: [Line]) -> String? {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        }
        let looked = words(wanted)
        guard !looked.isEmpty else { return lines.first?.text }
        func says(_ candidate: String) -> Bool {
            let seen = Set(words(candidate))
            return Double(looked.filter(seen.contains).count) >= Double(looked.count) * 0.75
        }
        if let line = lines.first(where: { says($0.text) }) { return line.text.trimmingCharacters(in: .whitespaces) }
        // A long heading may wrap: two lines next to each other count as one.
        for (index, line) in lines.enumerated().dropLast() where says(line.text + " " + lines[index + 1].text) {
            return (line.text + " " + lines[index + 1].text).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

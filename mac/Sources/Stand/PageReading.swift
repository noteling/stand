import AppKit
import StandCore

/// Reads the pages among Stand's sources and keeps a copy of each (`PageCopies`).
///
/// A page is read where its human reads it: in their own browser, signed in as they are.
/// That opens a window there, so it is done when they ask and at no other time: when a
/// page is added, and when they press Check now. A run can be told to read in Stand's own
/// window instead (STAND_SCREEN=window), which gets only what anyone can see.
enum PageReading {
    /// Reads each page among `sources`, one after another in one window, and closes what
    /// it opened. Answers with what could not be read, by address, each in a sentence.
    @MainActor
    static func read(_ sources: [NotesSource], root: URL, onPage: ((URL) -> Void)? = nil) async -> [URL: String] {
        let pages = sources.compactMap(\.page)
        guard !pages.isEmpty else { return [:] }
        let screen = PageScreen(root: root, visible: false, in: PageScreen.Where.told ?? .browser)
        defer { screen.close() }
        var problems = [URL: String]()
        for address in pages {
            onPage?(address)
            switch await screen.read(address) {
            case .success(let copy):
                do { try PageCopies.save(copy, through: screen.program, root: root) } catch { problems[address] = "The page was read and could not be kept: \(error.localizedDescription)" }
            case .failure(let why):
                problems[address] = "\(why)"
            }
        }
        return problems
    }
}

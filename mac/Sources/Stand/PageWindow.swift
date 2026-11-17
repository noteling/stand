import AppKit
import StandCore

/// Stand's screen: one page at a time, for the person beside Stand to share in the call. A
/// page is a document from one of the folders Stand was given, drawn from its Markdown, or
/// an address, loaded as a browser loads it. It is put up either in a window of Stand's own
/// or in a window Stand opens in the person's own browser (`PageSurface`).
///
/// It is the simplest hand there is, and the simplest eye. Showing a page is loading it
/// and bringing a heading to the top; looking is asking the page what is at the top, or
/// taking a picture of the window and reading the words in it, which is how any other
/// screen would have to be looked at. Either way the answer is what is there, not what
/// was asked for: a page that did not load, or a heading the document does not have, comes
/// back as a failure with what the audience sees in its place.
final class PageScreen: Screen, @unchecked Sendable {
    /// How the screen is looked at after a page has been put up.
    enum Eye: String {
        /// Ask the page itself what is at the top of it. Exact, and only possible for a page that lets itself be asked.
        case page
        /// Take a picture of the window and read the words in it. What any screen allows.
        case picture
    }

    /// Where the pages are put up.
    enum Where: String {
        /// A window of Stand's own, which draws the page itself. Nothing has to be allowed for it.
        case window
        /// A window Stand opens in the person's own browser, where they are signed in to what they are signed in to.
        case browser

        /// What a run was told in its environment, if it was told: STAND_SCREEN=chrome, or =window.
        static var told: Where? {
            switch ProcessInfo.processInfo.environment["STAND_SCREEN"]?.lowercased() {
            case "chrome", "browser": return .browser
            case "window", "own": return .window
            default: return nil
            }
        }
    }

    private let sources: [NotesSource]
    private let eye: Eye
    private let window: PageWindow
    let place: Where

    @MainActor init(root: URL, visible: Bool, eye: Eye = .page, in place: Where = .window) {
        sources = NotesSource.all(root: root, settings: BrainSettings.load(root: root)).sources
        self.eye = eye
        self.place = place
        let surface: PageSurface = place == .browser ? BrowserSurface() : WebViewSurface(visible: visible)
        window = PageWindow(on: surface)
    }

    /// What its human shares in the call, in a few words: "the window “Stand: the screen”".
    @MainActor var toShare: String { window.surface.name }
    /// The program the pages are in, by its name: "Google Chrome", or "Stand's own window".
    @MainActor var program: String { window.surface.program }

    func show(_ page: TalkPlan.Page) async -> ScreenLook {
        let started = Date()
        do {
            let place = try Pages.locate(page.place, sources: sources)
            return await window.show(page, at: place, eye: eye)
        } catch {
            // Nothing was moved: say what is still there.
            let showing = await window.atTheTop()
            return ScreenLook(shown: false, showing: showing, problem: "\(error)", how: "the page itself", seconds: Date().timeIntervalSince(started),
                              picture: await window.picture())
        }
    }

    func follow(_ points: [String]) async -> Int { await window.follow(points) }
    /// The first words at the place found for each point, for looking at how well points and page were matched.
    func places() async -> [Int: String] { await window.places }
    func bring(point: Int) async -> ScreenLook? { await window.bring(point: point, eye: eye) }
    func scroll(_ direction: ScreenScroll) async -> ScreenLook { await window.scroll(direction) }

    /// Reads a page for a note (`PageCopies`): puts it up from its start, waits for its
    /// words, and gives them back, or says why there is nothing to give, in a sentence.
    func read(_ address: URL) async -> Result<PageCopies.Copy, StandError> {
        let look = await window.show(TalkPlan.Page(place: address.absoluteString), at: .address(address), eye: .page)
        guard look.shown else { return .failure(StandError(look.problem ?? "The page did not come up.")) }
        guard let read = await window.read(), read.text.count >= 40 else {
            return .failure(StandError("The page came up with no words on it that Stand could read."))
        }
        // Sent on to another site: most often a sign-in page standing where the page should be.
        if let landed = URL(string: read.address)?.host?.lowercased(), let wanted = address.host?.lowercased(), landed != wanted {
            return .failure(StandError("The browser was sent on to \(landed) and did not get the page. It may want signing in to first: open the page there yourself, and then check again."))
        }
        return .success(PageCopies.Copy(address: address, title: read.title, text: read.text))
    }

    @MainActor func close() { window.close() }
    @MainActor func bringToFront() { window.bringToFront() }

    /// Closes the screen from wherever a run happens to be ending, and does not come back
    /// until it is closed: a task left to do it would be cut off by the end of the run.
    nonisolated func closeAndWait() {
        if Thread.isMainThread { MainActor.assumeIsolated { close() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { close() } } }
    }
}

/// A screen that fails on purpose, for rehearsing what Stand says when a page does not
/// come up: the pages asked for in the given turns (the first is 1) are not shown.
final class FaultyScreen: Screen, @unchecked Sendable {
    private let real: Screen
    private let failing: Set<Int>
    private let lock = NSLock()
    private var asked = 0
    private var lastShowing = ""

    init(_ real: Screen, failing: Set<Int>) {
        self.real = real
        self.failing = failing
    }

    func show(_ page: TalkPlan.Page) async -> ScreenLook {
        let (turn, showing) = lock.withLock { () -> (Int, String) in
            asked += 1
            return (asked, lastShowing)
        }
        if failing.contains(turn) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return ScreenLook(shown: false, showing: showing, problem: "The page did not load.", how: "a failure made up for this rehearsal", seconds: 0.6)
        }
        let look = await real.show(page)
        lock.withLock { lastShowing = look.showing }
        return look
    }

    func follow(_ points: [String]) async -> Int { await real.follow(points) }
    func bring(point: Int) async -> ScreenLook? { await real.bring(point: point) }
    func scroll(_ direction: ScreenScroll) async -> ScreenLook { await real.scroll(direction) }
}

/// What a page is put up on: a window of Stand's own (`WebViewSurface`), or a tab of the
/// person's own browser (`BrowserSurface`). A surface gets a page loaded and runs a script
/// in it, and that is all it does. Finding a heading, bringing it to the top, following a
/// section down the page and looking at what is there are the same on any surface, and are
/// `PageWindow`'s.
@MainActor
protocol PageSurface: AnyObject {
    /// What its human shares in the call, in a few words, for the panel.
    var name: String { get }
    /// The program the page is in, by its name.
    var program: String { get }
    /// Whether a picture of what is showing can be taken here.
    var takesPictures: Bool { get }
    /// Whether a page moved gently here is seen to move: false for a window that is kept off the display.
    var animates: Bool { get }
    /// Puts a document in front of the audience, drawn as a page. `key` says which document
    /// and when it was last changed: when that is what is showing already, nothing is
    /// loaded, and `html` is not asked for. `html` answers nil when the document cannot be read.
    func load(document name: String, key: String, html: () -> String?) async -> PageLoad
    /// Puts the page at an address in front of the audience.
    func load(address: URL) async -> PageLoad
    /// The next load is a fresh one, whatever is thought to be showing.
    func forget()
    /// Runs a script in the page and gives back the text it answers with, or nil when it answers with none.
    func run(_ script: String) async -> String?
    /// Why the page cannot be asked anything, in a sentence, when it cannot: then it can be neither moved nor looked at.
    func blind() async -> String?
    /// A picture of what is showing, as a PNG file's bytes.
    func picture() async -> Data?
    func close()
    func bringToFront()
}

/// What came of asking a surface for a page.
enum PageLoad {
    /// It was showing already.
    case held
    /// It was loaded now.
    case loaded
    /// It is not showing, and why, in a sentence.
    case failed(String)
}

/// The hand and the eye for one page at a time, on whatever it is put up on.
///
/// The scripts here are written for pages Stand did not draw as much as for those it did.
/// On such a page the thing that scrolls is often a panel inside the window and not the
/// window, a bar often stays stuck over the top of what shows, and a menu at the side has
/// headings of its own. `tools` is what every script is given to cope with that; on a page
/// Stand drew, each of those comes out as nothing, and the page moves as it always did.
@MainActor
final class PageWindow {
    let surface: PageSurface
    /// The points of the section being given that have a place of their own on the page, with
    /// the first words there. The place itself is marked on the page (data-stand-stop), and
    /// found again each time it is needed: a window that is resized, or zoomed, moves everything.
    private var stops = [Int: String]()
    private var marks = [Int: Int]() // a point whose place is the block already marked for an earlier point: which one
    var places: [Int: String] { stops }

    init(on surface: PageSurface) {
        self.surface = surface
    }

    func close() { surface.close() }
    func bringToFront() { surface.bringToFront() }
    func picture() async -> Data? { await surface.picture() }

    /// Where a heading was found, once it had been brought to the top.
    private struct Found {
        let text: String
        /// How far down what shows of the page it is, and how tall that is.
        let top: Double
        let view: Double
        let isHeading: Bool
        /// It is where it can be seen: within what shows, with nothing lying over it.
        let seen: Bool
        /// The page is as far down as it goes, so the heading can come no nearer the top.
        let atEnd: Bool
        /// The page had to be moved to get it there.
        let moved: Bool
    }

    /// Puts the page up and looks at it.
    func show(_ page: TalkPlan.Page, at place: Pages.Place, eye: PageScreen.Eye, again: Bool = false) async -> ScreenLook {
        let started = Date()
        func look(_ shown: Bool, _ showing: String, _ problem: String? = nil, how: String = "the page itself", picture: Data? = nil) -> ScreenLook {
            ScreenLook(shown: shown, showing: showing, problem: problem, how: how, seconds: Date().timeIntervalSince(started), picture: picture)
        }

        stops = [:] // the places of the last section's points mean nothing on the page that comes now
        marks = [:]

        // The hand, first part: the right page in the window.
        let load: PageLoad
        switch place {
        case .document(let url, let name):
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            load = await surface.load(document: name, key: "\(url.path) \(changed?.timeIntervalSince1970 ?? 0)") {
                (try? String(contentsOf: url, encoding: .utf8)).map {
                    MarkdownPage.html($0, title: url.deletingPathExtension().lastPathComponent, folder: url.deletingLastPathComponent())
                }
            }
        case .address(let url):
            load = await surface.load(address: url)
        }
        let justLoaded: Bool // the page in the window was loaded during this very call
        switch load {
        case .failed(let why): return look(false, await atTheTop(), why, picture: await surface.picture())
        case .loaded: justLoaded = true
        case .held: justLoaded = false
        }
        // A page that cannot be asked anything can be neither moved nor looked at. Say that,
        // and not that it has no such heading.
        if let why = await surface.blind() { return look(false, "", why, how: "nothing") }

        // The hand, second part: the heading to the top. A page that builds itself after
        // loading may not have the heading yet, so it is looked for a few times.
        var found: Found?
        var wanted = page.heading
        if wanted == nil, case .address(let url) = place { wanted = url.fragment }
        for attempt in 0..<12 {
            if let answer = await scroll(to: wanted, patient: attempt < 11) {
                found = answer
                break
            }
            if case .document = place { break } // a document drawn here has all of itself at once
            if attempt < 11 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        try? await Task.sleep(nanoseconds: 120_000_000) // let it draw before it is looked at
        // A page from an address goes on changing after it has been moved. It may still be
        // putting things in above the heading, and a bar across its top may only come out,
        // or grow, once the page has moved under it: the heading is then behind the bar. So
        // the heading is put in its place again, until doing so moves nothing.
        if found != nil, case .address = place {
            for pass in 0..<3 {
                guard let again = await scroll(to: wanted) else { break }
                found = again
                if !again.moved { break }
                if pass < 2 { try? await Task.sleep(nanoseconds: 120_000_000) }
            }
        }
        let snapshot = await surface.picture()

        guard let found else {
            // The window was thought to hold this page already, and what is in it is something
            // else: someone followed a link, or the page rebuilt itself. Load it afresh, once.
            if !justLoaded, !again {
                surface.forget()
                return await show(page, at: place, eye: eye, again: true)
            }
            let showing = await atTheTop()
            return look(false, showing, "The page has no heading called \"\(wanted ?? "")\".", picture: snapshot)
        }

        // The eye. A surface that takes no pictures is looked at by asking the page.
        switch surface.takesPictures ? eye : .page {
        case .page:
            // Asked for a page from its start: it is at its start, whatever is at the top of it.
            if wanted == nil { return look(true, found.text, picture: snapshot) }
            // Near the top, or as near as a page that ends there lets it come.
            guard found.top > -8, found.top < found.view * 0.6 || (found.atEnd && found.top < found.view - 24) else {
                return look(false, await atTheTop(), "The heading \"\(found.text)\" could not be brought to the top of the page.", picture: snapshot)
            }
            guard found.seen else {
                return look(false, await atTheTop(), "The heading \"\(found.text)\" is on the page, but something else on the page is lying over it.", picture: snapshot)
            }
            return look(true, found.text, picture: snapshot)
        case .picture:
            guard let snapshot, let lines = await PictureEye.read(snapshot) else {
                return look(false, "", "No picture of the screen could be taken.", how: "a picture of it", picture: snapshot)
            }
            // Read from the top: the heading has to be among the first things in the picture.
            let upper = lines.filter { $0.fromTop < 0.6 }
            if let line = PictureEye.find(found.text, in: upper) {
                return look(true, line, how: "a picture of it", picture: snapshot)
            }
            // Asked for a page from its start, and the page has no heading to look for: all
            // that can be said is that it loaded, and what the picture has at the top.
            if wanted == nil, !found.isHeading {
                return look(true, upper.first?.text ?? found.text, how: "a picture of it", picture: snapshot)
            }
            return look(false, upper.first?.text ?? "", "A picture of the screen does not show \"\(found.text)\" near the top.", how: "a picture of it", picture: snapshot)
        }
    }

    /// Finds where each point of the section is written about, in the part of the page under
    /// the heading the section starts at. A point's place is the block (a paragraph, a list
    /// item, a row of a table) that shares most of its longer words, never above the place
    /// of the point before it. The first point has no place of its own: it is made under the
    /// heading. When the whole part fits on the screen there is nothing to follow, and the
    /// answer is 0.
    func follow(_ points: [String]) async -> Int {
        stops = [:]
        marks = [:]
        guard let list = try? JSONSerialization.data(withJSONObject: points), let json = String(data: list, encoding: .utf8) else { return 0 }
        let script = """
        ((points) => {
          // The words that say what a sentence is about: four letters or more, without their
          // endings, and without the words every sentence has.
          const common = new Set('about above after again against also among another because been before being below between both cannot come could does doing down during each either else even ever every first from further have having here into itself just know less like made make many might more most much must never next none nothing once only onto other others ours over rather same should since some such take than that their theirs them then there these they this those through thus time times under until upon very want well were what when where whether which while will with within without would your yours please hello thank thanks going give given gives'.split(' '));
          const stem = t => new Set(((t || '').toLowerCase().match(/\\p{L}{4,}/gu) || []).filter(w => !common.has(w)).map(w => {
            if (w.length > 6 && w.endsWith('ing')) w = w.slice(0, -3); else if (w.length > 5 && w.endsWith('ed')) w = w.slice(0, -2);
            else if (w.length > 4 && w.endsWith('s')) w = w.slice(0, -1);
            return w.slice(0, 6);
          }));
          const head = document.querySelector('[data-stand-section]');
          const region = S.region();
          let hs = S.headingsIn(region);
          if (head && !hs.includes(head)) hs = S.headingsIn(document);
          const end = head ? hs.slice(hs.indexOf(head) + 1).find(h => S.level(h) <= S.level(head)) || null : null;
          const follows = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
          const sc = head ? S.scroller(head) : S.main();
          // The page's own words: not a menu's, and not what is in some other part that scrolls by itself.
          const root = region !== document && (!head || region.contains(head)) ? region : document;
          const blocks = [...root.querySelectorAll('p,li,tr,pre,blockquote,h2,h3,h4,h5,h6,dd,dt')].filter(b =>
            (!head || follows(head, b)) && (!end || follows(b, end)) && S.shows(b) && (S.isPage(sc) || sc.contains(b))
            && b.innerText.trim().length > 0 && !b.querySelector('p,li,tr,pre,blockquote'));
          if (!blocks.length) return '[]';
          const start = head ? S.pos(head, sc) : 0;
          const bottom = Math.max(...blocks.map(b => S.bottom(b, sc) + S.at(sc)));
          const room = S.view(sc) - (head ? S.cover(head, sc) : 0);
          if (bottom - start <= room * 0.92) return '[]';
          const words = blocks.map(b => stem(b.innerText));
          document.querySelectorAll('[data-stand-stop]').forEach(e => e.removeAttribute('data-stand-stop'));
          // A word that is in every block says little about which block is meant: each word
          // counts for more the fewer blocks have it.
          const inBlocks = new Map();
          words.forEach(set => set.forEach(w => inBlocks.set(w, (inBlocks.get(w) || 0) + 1)));
          const weight = w => Math.log((blocks.length + 1) / ((inBlocks.get(w) || 0) + 0.5));
          const out = [];
          let from = 0;
          points.forEach((point, i) => {
            // The first point is made under the heading the page was just brought to: that is
            // its place. (An opening that says who is speaking once shared its words with a row
            // of a table far down the page, and the page left its title a second into the talk.)
            if (i === 0) return;
            const wanted = [...stem(point)];
            if (wanted.length < 3) return;
            const all = wanted.reduce((sum, w) => sum + weight(w), 0);
            let best = -1, bestScore = 0;
            for (let j = from; j < blocks.length; j++) {
              const shared = wanted.filter(w => words[j].has(w));
              const score = shared.reduce((sum, w) => sum + weight(w), 0) / all;
              if (shared.length >= 3 && score > bestScore + 0.001) { best = j; bestScore = score; }
            }
            // A third of what the point is about, in at least three of its words, or it has no place of its own.
            if (best < 0 || bestScore < 0.33) return;
            from = best;
            // One block can be the place of several points: it keeps the first, and the others are in view when it is.
            if (!blocks[best].hasAttribute('data-stand-stop')) blocks[best].setAttribute('data-stand-stop', String(i));
            out.push({point: i, at: blocks[best].getAttribute('data-stand-stop'), text: blocks[best].innerText.trim().replace(/\\s+/g, ' ').slice(0, 90)});
          });
          return JSON.stringify(out);
        })(\(json))
        """
        guard let answer = await run(script), let data = answer.data(using: .utf8),
              let found = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        for stop in found {
            guard let point = stop["point"] as? Int, let text = stop["text"] as? String else { continue }
            stops[point] = text
            if let at = stop["at"] as? String, let first = Int(at), first != point { marks[point] = first }
        }
        return stops.count
    }

    /// Brings the place of a point into view, gently, when it is not in view already. Nil
    /// when nothing had to move, or when neither this point nor any before it has a place.
    func bring(point: Int, eye: PageScreen.Eye) async -> ScreenLook? {
        // A point with no place of its own is made where the last point before it that has
        // one is written about. (When the talk goes on after someone had the page, that is
        // where the page has to come back to.)
        guard point >= 1, let point = stride(from: point, through: 1, by: -1).first(where: { stops[$0] != nil }), let text = stops[point] else { return nil }
        let started = Date()
        // Where the block is now and where it should be: a little down from the top of what
        // shows, clear of anything that sticks there. Worked out afresh each time it is
        // needed: the window may have been resized since the place was found.
        let aim = """
        (() => {
          const b = document.querySelector('[data-stand-stop="\(marks[point] ?? point)"]');
          if (!b) return null;
          const sc = S.scroller(b), view = S.view(sc), cover = S.cover(b, sc);
          return {sc, view, cover, at: S.top(b, sc), to: Math.min(S.most(sc), Math.max(0, S.pos(b, sc) - Math.max(view * 0.22, cover + 24)))};
        })()
        """
        let moving = await run("""
        ((aim) => {
          if (!aim) return 'gone';
          if (aim.at > Math.max(aim.view * 0.08, aim.cover + 8) && aim.at < aim.view * 0.6) return 'in view';
          S.to(aim.sc, aim.to, true);
          return 'moving';
        })(\(aim))
        """)
        guard moving == "moving" else { return nil } // in view already, or the page is no longer the one the place was found on
        try? await Task.sleep(nanoseconds: 650_000_000) // a gentle scroll takes about half a second
        // Gently when it can, at once when it has not got there: a window that is not on the
        // display is sometimes not given the time to animate.
        await settle(aim)
        var at = -1.0, view = 0.0
        if let answer = await run("((aim) => aim ? JSON.stringify({at: aim.at, view: aim.view}) : '')(\(aim))"), let data = answer.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            at = (json["at"] as? NSNumber)?.doubleValue ?? -1
            view = (json["view"] as? NSNumber)?.doubleValue ?? 0
        }
        let snapshot = await surface.picture()
        let seconds = Date().timeIntervalSince(started)
        guard at > -8, at < view * 0.75 else {
            return ScreenLook(shown: false, showing: await atTheTop(), problem: "The page could not be moved down to \"\(text)\".", how: "the page itself", seconds: seconds, picture: snapshot)
        }
        if eye == .picture, let snapshot, let lines = await PictureEye.read(snapshot) {
            guard let line = PictureEye.find(text, in: lines) else {
                return ScreenLook(shown: false, showing: lines.first?.text ?? "", problem: "A picture of the screen does not show \"\(text)\".", how: "a picture of it", seconds: Date().timeIntervalSince(started), picture: snapshot)
            }
            return ScreenLook(shown: true, showing: line, how: "a picture of it", seconds: Date().timeIntervalSince(started), picture: snapshot)
        }
        return ScreenLook(shown: true, showing: text, how: "the page itself", seconds: seconds, picture: snapshot)
    }

    /// Moves the page most of a screenful down or up, because someone asked, and says what
    /// is at the top now. A page that is already at its end, or its start, does not move.
    func scroll(_ direction: ScreenScroll) async -> ScreenLook {
        let started = Date()
        if direction == .top {
            // Back to the heading the section starts at, or to the start of a page that has none marked.
            let aim = """
            (() => {
              const head = document.querySelector('[data-stand-section]');
              const sc = head ? S.scroller(head) : S.main();
              return {sc, to: head ? Math.min(S.most(sc), Math.max(0, S.pos(head, sc) - S.cover(head, sc) - 16)) : 0};
            })()
            """
            let answer = await run("""
            ((aim) => {
              if (Math.abs(S.at(aim.sc) - aim.to) < 4) return 'start';
              S.to(aim.sc, aim.to, true);
              return 'moving';
            })(\(aim))
            """)
            if answer != "moving" {
                return ScreenLook(shown: false, showing: await atTheTop(), problem: "The page is already at the top of this part.", how: "the page itself",
                                  seconds: Date().timeIntervalSince(started), picture: await surface.picture())
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            await settle(aim)
            return ScreenLook(shown: true, showing: await atTheTop(), how: "the page itself", seconds: Date().timeIntervalSince(started), picture: await surface.picture())
        }
        let down = direction == .down
        let answer = await run("""
        ((down) => {
          const sc = S.main(), view = S.view(sc);
          // The last thing with words in it: below that there is only empty space.
          const blocks = [...(S.isPage(sc) ? document : sc).querySelectorAll('p,li,tr,pre,blockquote,h1,h2,h3,h4,h5,h6,td,div')].filter(b => S.shows(b) && b.innerText && b.innerText.trim().length > 0);
          const bottom = blocks.length ? Math.max(...blocks.map(b => S.bottom(b, sc) + S.at(sc))) : S.most(sc) + view;
          const before = S.at(sc);
          if (down && (bottom - before <= view * 0.95 || before >= S.most(sc) - 2)) return 'end';
          if (!down && before <= 2) return 'start';
          const to = Math.min(S.most(sc), Math.max(0, before + (down ? 1 : -1) * view * 0.7));
          S.to(sc, to, true);
          return 'moving ' + to;
        })(\(down))
        """)
        if answer == "end" || answer == "start" {
            return ScreenLook(shown: false, showing: await atTheTop(), problem: "The page is already at its \(answer ?? "end").", how: "the page itself",
                              seconds: Date().timeIntervalSince(started), picture: await surface.picture())
        }
        try? await Task.sleep(nanoseconds: 650_000_000)
        let moved = answer?.hasPrefix("moving") ?? false
        if moved, let to = answer.flatMap({ Double($0.dropFirst("moving ".count)) }) { await settle("({sc: S.main(), to: \(to)})") }
        return ScreenLook(shown: moved, showing: await atTheTop(), problem: moved ? nil : "The page did not move.", how: "the page itself",
                          seconds: Date().timeIntervalSince(started), picture: await surface.picture())
    }

    /// Makes sure a gentle scroll has arrived where it was sent: if the page is not there,
    /// it is put there at once. `aim` is a script that gives what scrolls and how far down it should be.
    private func settle(_ aim: String) async {
        _ = await run("""
        ((aim) => {
          if (!aim || typeof aim.to !== 'number' || isNaN(aim.to)) return 'unknown';
          if (Math.abs(S.at(aim.sc) - aim.to) <= 8) return 'there';
          S.to(aim.sc, aim.to, false);
          return 'put there';
        })(\(aim))
        """)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// What is at the top of the page now, in its own words: the first heading in view, or its title.
    func atTheTop() async -> String {
        let script = """
        (() => {
          const hs = S.headings();
          const sc = S.main(), view = S.view(sc);
          const cover = hs.length ? S.cover(hs[0], sc) : 0;
          const inView = hs.filter(h => S.bottom(h, sc) > cover && S.top(h, sc) < view * 0.6);
          const above = hs.filter(h => S.top(h, sc) <= cover).pop();
          const h = inView[0] || above || hs[0];
          return (h ? h.innerText : document.title || '').trim().slice(0, 120);
        })()
        """
        return await run(script) ?? ""
    }

    /// What the page that is showing says, in its own words, for a note: the headings,
    /// paragraphs, lists and tables of the page proper as Markdown, with the page's title
    /// and the address the browser ended up at. A page goes on filling in after it has come
    /// up, so it is read until two readings a moment apart are as long as each other.
    func read() async -> (title: String, address: String, text: String)? {
        let script = """
        (() => {
          const proper = S.region();
          const root = proper === document ? document.body : proper;
          const clean = t => (t || '').replace(/\\s+/g, ' ').trim();
          // Not the page's words: what a site puts around them, and what is only there to be pressed or typed into.
          const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'NAV', 'ASIDE', 'FOOTER', 'BUTTON', 'FORM', 'SVG', 'IFRAME', 'SELECT', 'TEXTAREA', 'INPUT']);
          const blocks = 'p,li,tr,pre,blockquote,h1,h2,h3,h4,h5,h6,[role="heading"],dt,dd,ul,ol,table,div,section,article,figure,details';
          const out = [];
          const walk = el => {
            for (const c of el.children) {
              const tag = c.tagName.toUpperCase();
              if (skip.has(tag) || !S.shows(c)) continue;
              if (S.isHeading(c)) { const t = clean(c.innerText); if (t) out.push('', '#'.repeat(Math.min(6, S.level(c))) + ' ' + t, ''); continue; }
              if (tag === 'PRE') { out.push('```', c.innerText.replace(/\\n+$/, ''), '```', ''); continue; }
              if (tag === 'TR') { const cells = [...c.children].map(x => clean(x.innerText)); if (cells.some(x => x)) out.push('| ' + cells.join(' | ') + ' |'); continue; }
              if (tag === 'LI') {
                // Its own words first, then any list inside it.
                const own = clean([...c.childNodes].filter(n => !(n.nodeType === 1 && /^(UL|OL)$/i.test(n.tagName))).map(n => n.nodeType === 3 ? n.textContent : n.nodeType === 1 ? n.innerText : '').join(' '));
                if (own) out.push('- ' + own);
                for (const inner of c.children) if (/^(UL|OL)$/i.test(inner.tagName)) walk(inner);
                continue;
              }
              if (tag === 'P' || tag === 'BLOCKQUOTE' || tag === 'DT' || tag === 'DD' || tag === 'FIGCAPTION') { const t = clean(c.innerText); if (t) out.push(t, ''); continue; }
              if (c.querySelector(blocks)) { walk(c); if (tag === 'TABLE' || tag === 'UL' || tag === 'OL') out.push(''); continue; }
              const t = clean(c.innerText);
              if (t) out.push(t, '');
            }
          };
          walk(root);
          const text = out.join('\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
          return JSON.stringify({title: clean(document.title), href: location.href, text: text.slice(0, 200000), more: text.length > 200000});
        })()
        """
        var last: (title: String, address: String, text: String)?
        for _ in 0..<6 {
            if let answer = await run(script), let data = answer.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var text = json["text"] as? String {
                if json["more"] as? Bool == true { text += "\n\n(The page goes on: only its first part was read.)" }
                let now = (json["title"] as? String ?? "", json["href"] as? String ?? "", text)
                if let before = last, before.text.count == now.2.count { return now }
                last = now
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return last
    }

    /// Runs a script in the page, with the tools every script here uses, and gives back the
    /// text it answers with, or nil when it answers with none. The script is one expression.
    private func run(_ script: String) async -> String? {
        await surface.run("(() => {\nconst GENTLY = \(surface.animates);\n\(Self.tools)\nreturn \(script.trimmingCharacters(in: .whitespacesAndNewlines));\n})()")
    }

    /// What every script here is given to work with, as `S`.
    private static let tools = """
    const S = (() => {
      const page = document.scrollingElement || document.documentElement;
      const isPage = sc => !sc || sc === page || sc === document.body || sc === document.documentElement;
      // There to be seen: not left out of the page, not a pixel put there for a screen reader, not made invisible.
      const shows = el => {
        if (!el) return false;
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        // Something with no box of its own (display: contents) shows when what is in it does. MDN's whole page is in one.
        if (style.display === 'contents') return [...el.children].some(shows);
        const r = el.getBoundingClientRect();
        return r.width > 2 && r.height > 2;
      };
      // The thing that scrolls around an element: the nearest one around it that really does, or the page itself.
      const scroller = el => {
        for (let p = el && el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
          const how = getComputedStyle(p).overflowY;
          if ((how === 'auto' || how === 'scroll' || how === 'overlay') && p.scrollHeight > p.clientHeight + 4) return p;
        }
        return page;
      };
      // Where what shows of it starts on the screen, how tall that is, how far down it is now, and how far down it goes.
      const viewTop = sc => isPage(sc) ? 0 : sc.getBoundingClientRect().top + sc.clientTop;
      const view = sc => isPage(sc) ? innerHeight : sc.clientHeight;
      const at = sc => isPage(sc) ? window.scrollY : sc.scrollTop;
      const most = sc => Math.max(0, (isPage(sc) ? page.scrollHeight : sc.scrollHeight) - view(sc));
      // An element's top and bottom, from the top of what shows; and its top from the start of all that scrolls.
      const top = (el, sc) => el.getBoundingClientRect().top - viewTop(sc);
      const bottom = (el, sc) => el.getBoundingClientRect().bottom - viewTop(sc);
      const pos = (el, sc) => top(el, sc) + at(sc);
      // Gently only where that can be seen. A window that is not on the display is not given
      // the time to animate: a gentle move there stalls, and comes back to life under whatever
      // move is made next, so the page ends up where the earlier one was sending it.
      const to = (sc, y, gently) => {
        const what = isPage(sc) ? window : sc;
        y = Math.max(0, y);
        try { what.scrollTo({top: y, behavior: gently && GENTLY ? 'smooth' : 'instant'}); } catch (e) { what.scrollTo(0, y); }
      };
      const marks = 'h1,h2,h3,h4,h5,h6,[role="heading"]';
      const isHeading = el => !!el && el.matches(marks);
      const level = h => /^H[1-6]$/.test(h.tagName) ? +h.tagName[1] : (+h.getAttribute('aria-level') || 2);
      // A heading with no words to it (a picture, a button) is nothing the talk can name.
      const headingsIn = root => [...root.querySelectorAll(marks)].filter(h => shows(h) && h.innerText.trim().length > 0);
      // Where the page's own words are, when the page says so: a heading in a menu or a side bar is not the page's.
      const regions = 'main, [role="main"], article, #main-content, #content';
      let proper = null;
      const region = () => {
        if (proper) return proper;
        // Found once, and marked: weighing the words of a long page takes a moment.
        const marked = document.querySelector('[data-stand-proper]');
        if (marked && shows(marked) && marked.querySelector(marks)) return proper = marked;
        const all = [...document.querySelectorAll(regions)].filter(r => shows(r) && r.querySelector(marks));
        let best = all[0] || document;
        // A part inside it that holds most of the words to be read there is the page proper; what is around that is the site's own furniture.
        for (const r of all) if (best !== document && r !== best && best.contains(r) && r.innerText.length >= best.innerText.length * 0.5) best = r;
        if (marked) marked.removeAttribute('data-stand-proper');
        if (best !== document) best.setAttribute('data-stand-proper', '1');
        return proper = best;
      };
      const headings = () => headingsIn(region());
      // The thing that scrolls for the part of the page the talk is at.
      const main = () => {
        const head = document.querySelector('[data-stand-section]') || headings()[0];
        return head ? scroller(head) : page;
      };
      // Whether something stays where it is while the page moves under it: a bar that sticks, or something laid over the part that scrolls from outside it.
      const stays = (hit, sc) => {
        if (!isPage(sc) && !sc.contains(hit)) return true;
        for (let p = hit; p && p !== sc && p !== document.documentElement; p = p.parentElement) {
          const how = getComputedStyle(p).position;
          if (how === 'fixed' || how === 'sticky') return true;
        }
        return false;
      };
      const column = el => { const r = el.getBoundingClientRect(); return Math.min(innerWidth - 2, Math.max(2, r.left + Math.min(r.width / 2, 200))); };
      // How much of the top of what shows is taken by such a thing, in the column an element is in. A heading brought to the very top would be under it.
      const cover = (el, sc) => {
        const x = column(el), from = Math.max(0, viewTop(sc));
        let covered = 0;
        for (let y = 3; y < Math.min(260, view(sc) * 0.4); y += 5) {
          const hit = document.elementFromPoint(x, from + y);
          if (hit && !el.contains(hit) && !hit.contains(el) && stays(hit, sc)) covered = y + 5;
          else if (y > covered + 30) break;
        }
        return covered;
      };
      // Whether an element can be seen where it is: within what shows, with nothing lying over it.
      const seen = (el, sc) => {
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        const y = r.top + Math.min(r.height / 2, 12);
        if (y < 0 || y > innerHeight) return false;
        const hit = document.elementFromPoint(column(el), y);
        return !!hit && (el.contains(hit) || (hit.contains(el) && (isPage(sc) || sc.contains(hit))));
      };
      return {page, isPage, shows, scroller, view, at, most, top, bottom, pos, to, marks, regions, isHeading, level, headingsIn, region, headings, main, cover, seen};
    })();
    """

    /// Brings a heading to the top and says what it found there, or nil when the page has no such heading.
    /// Without a heading, the page is shown from its start.
    /// A page that fetches its words after it has loaded has, for a moment, a place for them
    /// with nothing in it. Such a page is not there yet; when `patient` is false, what
    /// there is is taken as it is.
    private func scroll(to heading: String?, patient: Bool = false) async -> Found? {
        let script = """
        ((wanted, patient) => {
          const norm = s => (s || '').toLowerCase().replace(/[^\\p{L}\\p{N}]+/gu, ' ').trim();
          // The heading the section starts at is marked, so that the part of the page under it can be found again.
          document.querySelectorAll('[data-stand-section]').forEach(e => e.removeAttribute('data-stand-section'));
          const say = (el, sc, text, heading, was) => JSON.stringify({text: text.slice(0, 120), top: el ? S.top(el, sc) : 0, heading: heading, view: S.view(sc),
            seen: el ? S.seen(el, sc) : true, end: S.at(sc) >= S.most(sc) - 2, moved: Math.abs(S.at(sc) - was) > 1});
          // A page that fetches its words has, for a moment, a place for them with nothing in
          // it. Nothing is taken from such a page yet: asked for from its start it came up as
          // the menu's first heading, and asked for a heading it came up as the one of that
          // name in the menu, while the page proper still said it was loading.
          if (patient && [...document.querySelectorAll(S.regions)].some(r => S.shows(r) && !r.querySelector(S.marks) && r.innerText.trim().length < 200)) return '';
          if (wanted === null) {
            const first = S.headings()[0] || null;
            const sc = first ? S.scroller(first) : S.page, was = S.at(sc);
            S.to(sc, 0, false);
            if (!S.isPage(sc)) S.to(S.page, 0, false);
            if (first) first.setAttribute('data-stand-section', '1');
            const text = first ? first.innerText.trim() : (document.title || '').trim();
            if (!text && !document.body.innerText.trim()) return '';
            return say(first, sc, text, !!first, was);
          }
          const w = norm(wanted);
          const pick = hs => hs.find(h => norm(h.innerText) === w) || hs.find(h => norm(h.innerText).startsWith(w)) || hs.find(h => norm(h.innerText).includes(w));
          // Among the page's own headings first, then among the others, but never one that
          // belongs to what a site puts around its pages: a menu's heading is not a place in the page.
          const around = 'nav, aside, header, footer, [role="navigation"], [role="banner"], [role="complementary"], [role="contentinfo"], [role="menu"], [role="dialog"]';
          const el = pick(S.headings()) || pick(S.headingsIn(document).filter(h => !h.closest(around)))
            || document.getElementById(wanted) || document.querySelector('[name="' + CSS.escape(wanted) + '"]');
          if (!el) return '';
          if (S.isHeading(el)) el.setAttribute('data-stand-section', '1');
          const sc = S.scroller(el), was = S.at(sc);
          try { el.scrollIntoView({block: 'start', behavior: 'instant'}); } catch (e) { el.scrollIntoView(true); }
          // To the top of what shows, clear of anything that sticks there. Twice: such a bar can change as the page moves.
          for (let pass = 0; pass < 2; pass++) S.to(sc, S.pos(el, sc) - S.cover(el, sc) - 16, false);
          return say(el, sc, (el.innerText || wanted).trim(), true, was);
        })(\(heading.map { Self.quoted($0) } ?? "null"), \(patient))
        """
        guard let answer = await run(script), let data = answer.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else { return nil }
        return Found(text: text, top: (json["top"] as? NSNumber)?.doubleValue ?? 0, view: (json["view"] as? NSNumber)?.doubleValue ?? 800,
                     isHeading: json["heading"] as? Bool ?? true, seen: json["seen"] as? Bool ?? true, atEnd: json["end"] as? Bool ?? false,
                     moved: json["moved"] as? Bool ?? false)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

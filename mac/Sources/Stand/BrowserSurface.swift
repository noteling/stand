import AppKit
import CoreServices
import StandCore

/// The few Apple Events Stand sends a browser, each built by hand. No AppleScript is
/// compiled: an event built this way can be sent from any thread, with a time limit of its
/// own, and to one process among several of the same browser.
///
/// These are the events of Chrome's scripting dictionary, which the browsers built on
/// Chrome share: its windows, their tabs, a tab's address, and a script run in a tab.
struct BrowserEvents: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let code: Int
        let message: String
        var description: String { message }
    }

    /// Whether macOS lets this program send the browser events at all.
    enum Leave: Sendable { case given, refused, notAsked, notRunning }

    let bundleID: String
    /// One process of the browser, when a run is told which: a second copy started for a test.
    let pid: pid_t?

    static func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    /// Where events go. By its name the browser is one program; when several copies of it are
    /// running, an event sent by name reaches whichever macOS picks, so the one that has been
    /// running longest is addressed by its process: that is the one its human uses.
    private var address: NSAppleEventDescriptor {
        if let pid { return NSAppleEventDescriptor(processIdentifier: pid) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1, let first = running.min(by: { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }) {
            return NSAppleEventDescriptor(processIdentifier: first.processIdentifier)
        }
        return NSAppleEventDescriptor(bundleIdentifier: bundleID)
    }

    /// Asks macOS whether events to the browser are allowed. With `ask`, a person who has
    /// not been asked yet is asked now, and this does not return until they have answered.
    func leave(ask: Bool) -> Leave {
        let address = self.address
        let any = Self.code("****")
        switch AEDeterminePermissionToAutomateTarget(address.aeDesc, any, any, ask) {
        case 0: return .given
        case -1743: return .refused // errAEEventNotPermitted
        case -1744: return .notAsked // errAEEventWouldRequireUserConsent
        default: return .notRunning // procNotFound, or a browser on its way out
        }
    }

    // MARK: What is said to it

    /// Opens a window and answers with its id and the id of the tab in it.
    func newWindow() throws -> (window: String, tab: String) {
        let made = try send("corecrel", ["kocl": NSAppleEventDescriptor(typeCode: Self.code("cwin"))], within: 6)
        // The answer names the window. If it does not, the window just made is the one in front.
        let window = made.flatMap { $0.descriptorType == Self.code("obj ") ? $0 : nil } ?? Self.specifier("cwin", "indx", NSAppleEventDescriptor(int32: 1))
        guard let id = try get("ID  ", of: window)?.stringValue, !id.isEmpty else { throw Failure(code: 0, message: "it opened a window and would not say which") }
        return (id, try activeTab(window: id))
    }

    func address(tab: String, window: String) throws -> String {
        try get("URL ", of: Self.tab(tab, in: window))?.stringValue ?? ""
    }

    func go(_ address: String, tab: String, window: String) throws {
        try set("URL ", of: Self.tab(tab, in: window), to: NSAppleEventDescriptor(string: address))
    }

    func isLoading(tab: String, window: String) throws -> Bool {
        try get("ldng", of: Self.tab(tab, in: window))?.booleanValue ?? false
    }

    /// Runs a script in the tab and gives back the text it answers with.
    func run(_ script: String, tab: String, window: String) throws -> String? {
        try send("CrSuExJa", direct: Self.tab(tab, in: window), ["JvSc": NSAppleEventDescriptor(string: script)], within: 4)?.stringValue
    }

    func activeTab(window: String) throws -> String {
        let active = Self.property("acTa", of: Self.window(window))
        guard let id = try get("ID  ", of: active)?.stringValue, !id.isEmpty else { throw Failure(code: 0, message: "its window has no tab") }
        return id
    }

    /// The ids of a window's tabs, in the order they stand in.
    func tabs(window: String) throws -> [String] {
        var all = Self.code("all ")
        guard let every = NSAppleEventDescriptor(descriptorType: Self.code("abso"), bytes: &all, length: 4),
              let list = try get("ID  ", of: Self.specifier("CrTb", "indx", every, in: Self.window(window))), list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
    }

    /// Makes the tab that stands at this place in its window (the first is 1) the one that shows.
    func setActiveTab(_ index: Int, window: String) throws {
        try set("acTI", of: Self.window(window), to: NSAppleEventDescriptor(int32: Int32(index)))
    }

    func isMinimized(window: String) throws -> Bool {
        try get("pmnd", of: Self.window(window))?.booleanValue ?? false
    }

    func setMinimized(_ minimized: Bool, window: String) throws {
        try set("pmnd", of: Self.window(window), to: NSAppleEventDescriptor(boolean: minimized))
    }

    /// In front of the browser's other windows.
    func raise(window: String) throws {
        try set("pidx", of: Self.window(window), to: NSAppleEventDescriptor(int32: 1))
    }

    func close(tab: String, window: String) throws {
        try send("coreclos", direct: Self.tab(tab, in: window))
    }

    /// What stands between Stand and showing pages in the browser, in a line, for the
    /// doctor. Nobody is asked anything: where macOS has not asked yet, that is the answer.
    static func standing() -> String {
        let bundleID = ProcessInfo.processInfo.environment["STAND_BROWSER"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.google.Chrome"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "Google Chrome is not on this Mac" }
        let name = app.deletingPathExtension().lastPathComponent
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "of a version it does not give"
        let events = BrowserEvents(bundleID: bundleID, pid: nil)
        switch events.leave(ask: false) {
        case .notRunning: return "\(name) \(version), not running now, so what macOS allows cannot be told"
        case .notAsked: return "\(name) \(version); macOS has not asked yet whether Stand may control it (it asks the first time a page goes up there)"
        case .refused: return "\(name) \(version); macOS does NOT let Stand control it (System Settings > Privacy & Security > Automation)"
        case .given:
            // Whether the browser lets a script into its pages is only found by trying: one that does nothing, in the tab in front.
            let front = property("acTa", of: specifier("cwin", "indx", NSAppleEventDescriptor(int32: 1)))
            do {
                _ = try events.send("CrSuExJa", direct: front, ["JvSc": NSAppleEventDescriptor(string: "'seen'")], within: 3)
                return "\(name) \(version); macOS lets Stand control it, and it lets Stand look at its pages and move them"
            } catch let failure as Failure where failure.code == 12 || failure.message.contains("JavaScript") {
                return "\(name) \(version); macOS lets Stand control it, but it does NOT let Stand look at its pages or move them (in its menu bar: View > Developer > Allow JavaScript from Apple Events)"
            } catch {
                return "\(name) \(version); macOS lets Stand control it; whether it lets Stand look at its pages could not be told (\(error))"
            }
        }
    }

    // MARK: How it is said

    private func get(_ property: String, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        try send("coregetd", direct: Self.property(property, of: object))
    }

    private func set(_ property: String, of object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        try send("coresetd", direct: Self.property(property, of: object), ["data": value])
    }

    /// Sends one event, named by the eight letters of its class and its id, and gives back
    /// what the browser answered. An answer that says something went wrong is thrown.
    @discardableResult
    private func send(_ event: String, direct: NSAppleEventDescriptor? = nil, _ parameters: [String: NSAppleEventDescriptor] = [:], within seconds: TimeInterval = 3) throws -> NSAppleEventDescriptor? {
        let descriptor = NSAppleEventDescriptor(eventClass: Self.code(String(event.prefix(4))), eventID: Self.code(String(event.suffix(4))), targetDescriptor: address,
                                                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { descriptor.setParam(direct, forKeyword: Self.code("----")) }
        for (keyword, value) in parameters { descriptor.setParam(value, forKeyword: Self.code(keyword)) }
        let reply: NSAppleEventDescriptor
        do {
            reply = try descriptor.sendEvent(options: [.waitForReply], timeout: seconds)
        } catch {
            let code = (error as NSError).code
            throw Failure(code: code, message: Self.words(code) ?? error.localizedDescription)
        }
        if let number = reply.paramDescriptor(forKeyword: Self.code("errn"))?.int32Value, number != 0 {
            throw Failure(code: Int(number), message: reply.paramDescriptor(forKeyword: Self.code("errs"))?.stringValue ?? Self.words(Int(number)) ?? "it answered with error \(number)")
        }
        return reply.paramDescriptor(forKeyword: Self.code("----"))
    }

    private static func words(_ code: Int) -> String? {
        switch code {
        case -1712: return "it did not answer in time"
        case -1743: return "macOS does not let Stand control it"
        case -600, -609: return "it is not running"
        case -1728, -1719: return "what was asked for is not there any more"
        default: return nil
        }
    }

    /// Something in the browser, named the way AppleScript names it: a window by its id, a
    /// tab by its id in its window, a property of either. An object specifier is a record
    /// of four things, read as one.
    private static func specifier(_ wanted: String, _ form: String, _ data: NSAppleEventDescriptor, in container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(wanted)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(data, forKeyword: code("seld"))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    private static func property(_ name: String, of object: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier("prop", "prop", NSAppleEventDescriptor(typeCode: code(name)), in: object)
    }

    private static func window(_ id: String) -> NSAppleEventDescriptor {
        specifier("cwin", "ID  ", NSAppleEventDescriptor(string: id))
    }

    private static func tab(_ id: String, in window: String) -> NSAppleEventDescriptor {
        specifier("CrTb", "ID  ", NSAppleEventDescriptor(string: id), in: self.window(window))
    }
}

/// A tab of the person's own browser to put a page up in: Chrome, in a window Stand opens
/// there. The page is the real one, with whatever that person is signed in to, in the
/// window people expect to see shared in a call.
///
/// Two things have to be allowed for it, each once, and neither is Stand's to give:
/// macOS asks whether Stand may control the browser, and the browser lets no program run a
/// script in its pages until "Allow JavaScript from Apple Events" is chosen in its own
/// menu. Until both are, a page asked for comes back as not shown, with which of the two
/// is in the way.
///
/// The browser is someone else's program and other hands are on it: its human can follow a
/// link, change tabs, or close the window. So nothing is remembered that can be asked: each
/// time a page is wanted the browser is asked what the tab holds now.
@MainActor
final class BrowserSurface: PageSurface {
    let takesPictures = false
    let animates = true
    var name: String { "the \(browser) window that Stand opened" }
    var program: String { browser }

    private let events: BrowserEvents
    /// The browser's name, as its human knows it: "Google Chrome".
    private let browser: String
    /// Events are sent from here, never from the main thread: each waits for its answer.
    private let queue = DispatchQueue(label: "stand.browser")
    private var windowID: String?
    private var tabID: String?
    /// Where the browser ended up for an address it was sent to, when that was somewhere else: both without what follows a "#".
    private var landed = [String: String]()
    /// The documents drawn into files for the browser to load, and which state of each.
    private var written = [String: String]()
    private var afresh = false
    private var asking = false
    private var whyBlind: String?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let bundleID = environment["STAND_BROWSER"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.google.Chrome"
        events = BrowserEvents(bundleID: bundleID, pid: environment["STAND_BROWSER_PID"].flatMap { pid_t($0) })
        browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? "the browser"
    }

    /// Where a document is drawn for the browser to load: a file, since a browser draws no Markdown.
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stand-pages", isDirectory: true)

    func load(document name: String, key: String, html: () -> String?) async -> PageLoad {
        if let why = await ready() { return .failed(why) }
        let inside = name.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        let file = Self.folder.appendingPathComponent(inside).deletingPathExtension().appendingPathExtension("html")
        var changed = false
        if written[file.path] != key || !FileManager.default.fileExists(atPath: file.path) {
            guard let page = html() else { return .failed("The document could not be read.") }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try page.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return .failed("The document could not be made into a page for \(browser).")
            }
            written[file.path] = key
            changed = true
        }
        let wanted = Self.bare(file.absoluteString)
        if !afresh, !changed, await holds(wanted) { return .held }
        return await go(to: file.absoluteString, wanted: wanted, within: 4, what: "The document")
    }

    func load(address url: URL) async -> PageLoad {
        if let why = await ready() { return .failed(why) }
        let wanted = Self.bare(url.absoluteString)
        if !afresh, await holds(wanted) { return .held }
        return await go(to: url.absoluteString, wanted: wanted, within: 6, what: "The page")
    }

    func forget() { afresh = true }

    func run(_ script: String) async -> String? {
        guard let window = windowID, let tab = tabID else { return nil }
        do {
            let answer = try await work { try $0.run(script, tab: tab, window: window) }
            whyBlind = nil
            return answer
        } catch {
            whyBlind = why(error)
            return nil
        }
    }

    func blind() async -> String? {
        if await run("'seen'") == "seen" { return nil }
        return whyBlind ?? "\(browser) ran nothing in the page."
    }

    func picture() async -> Data? { nil }

    /// The tab Stand opened is closed. A window with nothing else in it goes with it; one its human has put other tabs in stays.
    func close() {
        guard let window = windowID, let tab = tabID else { return }
        windowID = nil
        tabID = nil
        let events = self.events
        // Waited for: a run that ends right after this must not leave its window behind in someone's browser.
        queue.sync { try? events.close(tab: tab, window: window) }
    }

    func bringToFront() {
        let app = events.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: events.bundleID).min(by: { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) })
        app?.activate(options: [])
        guard let window = windowID else { return }
        let events = self.events
        queue.async { try? events.raise(window: window) }
    }

    // MARK: The browser, its window and its tab

    /// Sees to it that the browser is running and may be spoken to, and that the window
    /// Stand opened in it is there, with its tab showing. Nil when it is, or what is in the way.
    private func ready() async -> String? {
        if events.pid == nil, NSWorkspace.shared.urlForApplication(withBundleIdentifier: events.bundleID) == nil { return "\(browser) is not on this Mac." }
        var leave = await asked()
        if leave == .notRunning {
            guard events.pid == nil, await launch() else { return "\(browser) is not running, and could not be started." }
            leave = await asked()
        }
        if leave == .notAsked {
            // macOS asks its human, once. The question is put from a thread of its own: it does not come back until it is answered.
            if !asking {
                asking = true
                let events = self.events
                Thread.detachNewThread { _ = events.leave(ask: true) }
            }
            for _ in 0..<20 where leave == .notAsked {
                try? await Task.sleep(nanoseconds: 250_000_000)
                leave = await asked()
            }
        }
        switch leave {
        case .given: break
        case .notAsked: return "macOS is asking whether Stand may control \(browser). Once that is answered, the next page will come up."
        case .refused: return "macOS does not let Stand control \(browser). That is set in System Settings, under Privacy & Security, Automation."
        case .notRunning: return "\(browser) is not running."
        }

        if let window = windowID, let tab = tabID, (try? await work({ try $0.address(tab: tab, window: window) })) != nil {
            // Its human may have put the window away or another tab in front: what the audience is to see is this one.
            if let showing = try? await work({ try $0.activeTab(window: window) }), showing != tab,
               let place = (try? await work({ try $0.tabs(window: window) }))?.firstIndex(of: tab) {
                _ = try? await work { try $0.setActiveTab(place + 1, window: window) }
            }
            if (try? await work({ try $0.isMinimized(window: window) })) == true { _ = try? await work { try $0.setMinimized(false, window: window) } }
            return nil
        }
        // No window yet, or the one there was has been closed.
        windowID = nil
        tabID = nil
        landed = [:]
        var problem = ""
        for attempt in 0..<8 {
            do {
                let made = try await work { try $0.newWindow() }
                windowID = made.window
                tabID = made.tab
                return nil
            } catch {
                problem = "\(error)"
                // A browser that has only just started does not take events for a moment.
                if attempt < 7 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
        return "\(browser) would not open a window for Stand: \(problem)."
    }

    private func asked() async -> BrowserEvents.Leave {
        (try? await work { $0.leave(ask: false) }) ?? .notRunning
    }

    private func launch() async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: events.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<40 {
            if await asked() != .notRunning { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Whether the tab holds this address now, by what the browser itself says.
    private func holds(_ wanted: String) async -> Bool {
        guard let window = windowID, let tab = tabID, let now = try? await work({ try $0.address(tab: tab, window: window) }) else { return false }
        let bare = Self.bare(now)
        return bare == wanted || bare == landed[wanted]
    }

    /// Sends the tab to an address and waits for the browser to have it.
    private func go(to address: String, wanted: String, within seconds: Double, what: String) async -> PageLoad {
        guard let window = windowID, let tab = tabID else { return .failed("\(browser) has no window of Stand's.") }
        afresh = false
        do {
            try await work { try $0.go(address, tab: tab, window: window) }
        } catch {
            return .failed("\(browser) did not take the address: \(error).")
        }
        // The browser says when it has the page. A page that goes on building itself after
        // that is waited for where its heading is looked for.
        let began = Date()
        var wasLoading = false
        while true {
            try? await Task.sleep(nanoseconds: 60_000_000)
            let waited = Date().timeIntervalSince(began)
            guard let loading = try? await work({ try $0.isLoading(tab: tab, window: window) }) else {
                return .failed("\(browser) stopped answering while the page was loading.")
            }
            if loading { wasLoading = true } else if wasLoading || waited > 0.35 { break }
            if waited > seconds { return .failed("\(what) did not load within \(seconds == 4 ? "four" : "six") seconds.") }
        }
        // Where it ended up, and whether that is a page at all.
        let asked = await run("JSON.stringify({href: location.href, status: (performance.getEntriesByType('navigation')[0] || {}).responseStatus || 0})")
        if let asked, let data = asked.data(using: .utf8), let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let href = said["href"] as? String ?? ""
            let status = (said["status"] as? NSNumber)?.intValue ?? 0
            if href.hasPrefix("chrome-error:") { return .failed("\(what) did not load.") }
            if status >= 400 { return .failed("The address answered \(status).") }
            if !href.isEmpty { landed[wanted] = Self.bare(href) }
        } else if let now = try? await work({ try $0.address(tab: tab, window: window) }) {
            landed[wanted] = Self.bare(now)
        }
        return .loaded
    }

    /// An address without what follows its "#", and with the "/" a browser puts after a bare host.
    private static func bare(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return String(address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        parts.fragment = nil
        if parts.path.isEmpty, parts.host != nil { parts.path = "/" }
        return parts.string ?? address
    }

    /// Why a script did not run, in a sentence for the person beside Stand.
    private func why(_ error: Error) -> String {
        let failure = error as? BrowserEvents.Failure
        // The browser's own setting, off until its human turns it on.
        if failure?.code == 12 || (failure?.message.contains("JavaScript") ?? false) {
            return "\(browser) is not letting Stand look at its pages or move them. In \(browser)'s menu bar choose View, then Developer, then Allow JavaScript from Apple Events."
        }
        return "\(browser) ran nothing in the page: \(error)."
    }

    private func work<T: Sendable>(_ body: @escaping @Sendable (BrowserEvents) throws -> T) async throws -> T {
        let events = self.events
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(events) }) }
        }
    }
}

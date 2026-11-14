import AppKit
import Carbon.HIToolbox
import StandCore
import SwiftUI

/// The app: one small panel that stays above the call, and two global hotkeys.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = SessionController()
    private var panel: NSPanel?
    private var hushKey: HotKey?
    private var noteKey: HotKey?
    private var topLeft = NSPoint.zero
    private var appBeforeNote: NSRunningApplication? // which app had the keyboard before the note hotkey
    private var hideItem: NSMenuItem?

    /// The panel holds the brief and the notes passed to Stand, which are private. Unless
    /// this is turned off in the menu, it is left out of anything that captures the screen,
    /// a call's screen sharing included.
    private var hiddenFromSharing: Bool {
        get { UserDefaults.standard.object(forKey: "hideFromScreenSharing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hideFromScreenSharing") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = menu()

        // A non-activating panel: its buttons and its text fields work without taking the
        // call's app out of the front.
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Stand"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = hiddenFromSharing ? .none : .readOnly
        // The panel is as tall as what it shows, which changes between before and during a meeting.
        let hosting = NSHostingController(rootView: PanelView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            topLeft = NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24)
            panel.setFrameTopLeftPoint(topLeft)
        }
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel

        // ⌃⌥S anywhere: Stand stops talking at once.
        hushKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.controller.hush()
        }
        // ⌃⌥N anywhere: the keyboard goes to the note field, to pass Stand a note. Return
        // passes it, Escape gives up, and either way the keyboard goes back where it was.
        noteKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.takeKeyboardForNote()
        }
        controller.onNoteDone = { [weak self] in self?.giveKeyboardBack() }
    }

    private func takeKeyboardForNote() {
        guard controller.phase == .running, let panel else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { appBeforeNote = front }
        panel.makeKeyAndOrderFront(nil)
        controller.focusNote()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
            // The system did not give the keyboard to a window of an app in the background.
            // Come to the front for it; the call's app gets the keyboard back afterwards.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            self.controller.focusNote()
        }
    }

    private func giveKeyboardBack() {
        guard let panel else { return }
        if NSApp.isActive, let app = appBeforeNote {
            app.activate()
        } else if panel.isKeyWindow {
            // Taking the panel off screen for an instant hands the keyboard back to the app in front.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        appBeforeNote = nil
    }

    // The panel grows downwards: its top left corner stays where the person put it.
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    func windowDidResize(_ notification: Notification) {
        panel?.setFrameTopLeftPoint(topLeft)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Give a running session the moment it needs to save its recording.
        guard controller.phase == .running else { return .terminateNow }
        controller.stop()
        Task { @MainActor in
            while controller.phase != .idle { try? await Task.sleep(nanoseconds: 100_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Drives the real window the way a person would, with nobody at the keyboard, and
    /// returns what went wrong. `Stand --probe panel` runs it. No session is started: the
    /// window is put in its during-a-meeting state by hand.
    func selfTest() async -> [String] {
        var failures = [String]()
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func key(_ characters: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel?.windowNumber ?? 0, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(event)
                }
            }
        }
        await pause(0.6)
        guard let panel else { return ["there is no window"] }
        // On a test folder only (STAND_HOME), never the person's own: the key field's way to .env.
        if controller.needsKey, ProcessInfo.processInfo.environment["STAND_HOME"] != nil, let root = try? Project.root() {
            controller.saveKey("  self-test-key  ")
            let kept = Project.setting("GEMINI_API_KEY", root: root)
            let mode = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".env").path)[.posixPermissions] as? Int) ?? 0
            print("the key field: kept \(kept == "self-test-key" ? "the key" : "something else"), readable only by this person: \(mode == 0o600 ? "yes" : "no")")
            if kept != "self-test-key" || controller.needsKey || mode != 0o600 { failures.append("the key pasted into the panel was not kept as it should be") }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".env"))
        }

        await pause(0.4)
        if !panel.isVisible { failures.append("the window is not on screen") }
        let corner = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let idleHeight = panel.frame.height
        print(String(format: "before a meeting: %.0f x %.0f points, hidden from screen sharing: %@", panel.frame.width, idleHeight, panel.sharingType == .none ? "yes" : "no"))

        controller.showingSources = true
        await pause(0.4)
        print(String(format: "with the notes list open: %.0f points tall", panel.frame.height))
        if panel.frame.height <= idleHeight { failures.append("the window did not grow when the notes list opened") }
        if abs(panel.frame.maxY - corner.y) > 1 || abs(panel.frame.minX - corner.x) > 1 { failures.append("the window's top left corner moved when it grew") }
        controller.showingSources = false

        controller.phase = .running
        await pause(0.4)
        print(String(format: "during a meeting: %.0f points tall", panel.frame.height))
        if abs(panel.frame.maxY - corner.y) > 1 { failures.append("the window's top left corner moved between before and during a meeting") }

        // What ⌃⌥N does.
        panel.makeKeyAndOrderFront(nil)
        controller.focusNote()
        await pause(0.5)
        // macOS gives the keyboard to a window of a background app only on a real key press
        // or click, and this test makes neither. So whether ⌃⌥N takes the keyboard is for a
        // person to check; what is checked here is that typing, once it arrives, is taken.
        print("the window has the keyboard: \(panel.isKeyWindow ? "yes" : "no (expected here: nobody pressed a key)")")
        if !(panel.firstResponder is NSTextView) { failures.append("the note field did not take the keyboard (the keyboard is in \(type(of: panel.firstResponder as Any)))") }
        for character in "wrap up" { key(String(character), code: 0) }
        await pause(0.3)
        print("typed into the note field: \"\(controller.note)\"")
        if controller.note != "wrap up" { failures.append("typing did not reach the note field") }
        key("\r", code: 36)
        await pause(0.3)
        if !controller.note.isEmpty { failures.append("Return did not pass the note") }

        controller.phase = .idle
        await pause(0.4)
        if abs(panel.frame.height - idleHeight) > 1 { failures.append("the window did not return to its size from before the meeting") }
        return failures
    }

    /// One file with what this Mac gives Stand and the last session's record, shown in the Finder to be sent.
    @objc private func makeProblemReport() {
        controller.makeProblemReport()
    }

    @objc private func toggleHiddenFromSharing() {
        hiddenFromSharing.toggle()
        panel?.sharingType = hiddenFromSharing ? .none : .readOnly
        hideItem?.state = hiddenFromSharing ? .on : .off
    }

    private func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let hide = NSMenuItem(title: "Hide Stand's Window from Screen Sharing", action: #selector(toggleHiddenFromSharing), keyEquivalent: "")
        hide.target = self
        hide.state = hiddenFromSharing ? .on : .off
        hideItem = hide
        appMenu.addItem(hide)
        let report = NSMenuItem(title: "Make a Problem Report", action: #selector(makeProblemReport), keyEquivalent: "")
        report.target = self
        appMenu.addItem(report)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Stand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        // Cut, copy and paste in the brief and the note field work through the Edit menu's key equivalents.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        return main
    }
}

/// A global hotkey through Carbon, which needs no Accessibility permission. Same approach
/// as Noteling's HotKey.
final class HotKey {
    private static var registry = [UInt32: HotKey]()
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let callback: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        id = UInt32(HotKey.registry.count + 1)
        HotKey.registry[id] = self
        HotKey.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4E44), id: id) // 'STND'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKey.registry[hotKeyID.id]?.callback() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

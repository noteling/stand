import AppKit
import SwiftUI

/// Draws the panel to PNG files in a few made-up states, with no session and nothing on
/// screen, so the layout and wording can be looked at without launching the app:
///
///   Stand --render-panel /tmp/panels
enum RenderPanel {
    @MainActor
    static func run(folder: String) throws {
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let idle = SessionController(live: false)
        idle.brief = ""
        idle.notesLine = "No notes. Stand can still look things up on the web"
        let firstRun = SessionController(live: false)
        firstRun.needsKey = true
        firstRun.notesLine = "No notes. Stand can still look things up on the web"
        firstRun.brainNotice = "Claude Code is not on this Mac, so Stand will not look anything up. Install it and sign in (claude.ai/code), then start again."
        let discussion = SessionController(live: false)
        discussion.talk = ""
        discussion.brief = "Weekly planning call for the Juniper pilot. Daniel runs it, Samantha has the venue. The next session must not be before 19 November: the room is booked only from then."
        discussion.notesLine = "Notes: 3 files from 1 place"
        let discussionBare = SessionController(live: false)
        discussionBare.talk = ""
        discussionBare.brief = ""
        discussionBare.notesLine = "Notes: 3 files from 1 place"
        let listening = SessionController(live: false)
        listening.talk = ""
        listening.phase = .running
        listening.elapsed = 412
        listening.roomText = "The twelfth is fine with me. Shall we settle on that?"
        listening.standText = "The next session cannot be earlier than the 19th of November, as the room is only booked from then."
        listening.cue = "Tuesday had 14 people, not 20."
        listening.sheet = "The meeting so far: weekly planning call for the Juniper pilot. Lunch for twenty was proposed. Facts to have ready: the Tuesday pilot had 14 attendees; Morgan will pay for catering up to 400 dollars."
        let questioned = SessionController(live: false)
        questioned.talk = ""
        questioned.phase = .running
        questioned.elapsed = 733
        questioned.roomText = "Stand, can Morgan do the Thursday instead of the Wednesday?"
        questioned.standText = "I'd have to check that with Morgan. I'll come back to you."
        questioned.questions = [.init(id: "q", text: "Can you do the Thursday instead of the Wednesday for the follow-up workshop?")]
        let briefed = SessionController(live: false)
        briefed.brief = "Priya (CFO) and Sam (IT) from Northwind. They are deciding whether to try Stand in their weekly review. Nothing is priced yet: say I will send a proposal by Friday."
        briefed.notesLine = "Notes: 14 files from 3 places"
        briefed.showingSources = true
        briefed.sources = [
            .init(id: "a", name: "context", place: "context", detail: "2 files", problem: nil, index: nil),
            .init(id: "b", name: "pilot-notes", place: "~/Documents/pilot-notes", detail: "5 files", problem: nil, index: 0),
            .init(id: "c", name: "handbook", place: "github.com/northwind/handbook, docs", detail: "7 files, at 1a2b3c4, checked 2 min ago", problem: nil, index: 1),
            .init(id: "d", name: "playbook", place: "github.com/northwind/playbook", detail: "nothing to read here",
                  problem: "github.com couldn't find northwind/playbook. Check the address. If it is private, sign in with the GitHub CLI on this Mac (gh auth login) and Stand will use that.", index: 2),
        ]
        let preparing = SessionController(live: false)
        preparing.brief = "Introduce the Ledger service to the support team. Ten minutes. They are not engineers. Aarav leads the team."
        preparing.notesLine = "Notes: 31 notes and 412 other files from 2 places"
        preparing.preparing = "reading the code"
        preparing.voice = "Zubenelgenubi"
        let prepared = SessionController(live: false)
        prepared.brief = preparing.brief
        prepared.notesLine = preparing.notesLine
        prepared.preparedLine = "Its brain wrote “Introducing the Ledger service”: 9 sections, in 4 min. Read it before the meeting."
        prepared.voice = "Zubenelgenubi" // the longest name on the list, with a long description beside it
        prepared.hearing = "Zubenelgenubi"
        let speaking = SessionController(live: false)
        speaking.phase = .running
        speaking.standSpeaking = true
        speaking.elapsed = 83
        speaking.standText = "It joins the call already knowing the background, just like a prepared colleague would, and it speaks up out loud."
        speaking.roomText = "Sorry, quick question. What do you mean when you say it has a goal?"
        speaking.note = "wrap up in two minutes"
        speaking.passed = ["Priya just joined. Say hello to her."]
        let asking = SessionController(live: false)
        asking.phase = .running
        asking.lookingUp = true
        asking.brainBusy = "using order_status from orders"
        asking.elapsed = 204
        asking.standText = "That's taking a moment. I'll come back to it."
        asking.roomText = "Do you know where order 4417 has got to?"
        asking.ask = .init(id: "x", what: "use order_status from orders (order_id: 4417)", until: Date().addingTimeInterval(17))
        let waiting = SessionController(live: false)
        waiting.phase = .running
        waiting.floorOpen = true
        waiting.elapsed = 131
        waiting.standText = "I'm ready for your questions now."
        let withPages = SessionController(live: false)
        withPages.talkShowsPages = true
        withPages.brief = "Walk the new engineers through the Ledger service. Six minutes. Show the documents as you go."
        withPages.notesLine = "Notes: 31 notes and 412 other files from 2 places"
        let inChrome = SessionController(live: false)
        inChrome.talkShowsPages = true
        inChrome.pagesInChrome = true
        inChrome.brief = withPages.brief
        inChrome.notesLine = withPages.notesLine
        let notes = SessionController(live: false)
        notes.brief = withPages.brief
        notes.notesLine = "Notes: 33 notes and 412 other files from 4 places"
        notes.showingSources = true
        notes.sources = [
            .init(id: "a", name: "context", place: "context", detail: "2 files", problem: nil, index: nil),
            .init(id: "b", name: "ledger", place: "~/projects/ledger", detail: "29 notes, 412 other files to search", problem: nil, index: 0),
            .init(id: "c", name: "How-refunds-work", place: "wiki.example.com/display/LEDGER/How+refunds+work", detail: "“How refunds work - Ledger - Wiki”, read 4 min ago", problem: nil, index: 1),
            .init(id: "d", name: "Runbook", place: "wiki.example.com/display/LEDGER/Runbook", detail: "not read yet", problem: "The browser was sent on to login.example.com and did not get the page. It may want signing in to first: open the page there yourself, and then check again.", index: 2),
        ]
        let pagesMissing = SessionController(live: false)
        pagesMissing.talkShowsPages = true
        pagesMissing.talkPagesMissing = ["Section 3: ledger/docs/architecture.md has no heading called \"How a refund is recorded\".", "Section 5: There is no document called ledger/docs/runbook.md in the folders Stand was given."]
        pagesMissing.brief = withPages.brief
        pagesMissing.notesLine = withPages.notesLine
        let showing = SessionController(live: false)
        showing.phase = .running
        showing.standSpeaking = true
        showing.elapsed = 147
        showing.standText = "Each payment is written to the ledger twice, once for each side, and the two entries are checked against each other every night."
        showing.screenSays = "On the screen for section 4: \"How a payment is recorded\" in ledger/docs/architecture.md, 0.2 s, seen by the page itself"
        showing.watchSays = "The talk is waiting: someone asked Stand to hold on. It goes on when they say so."
        let ended = SessionController(live: false)
        ended.lastRun = out
        ended.lastRunSummary = "Last run: 2:44, about $0.05"
        ended.message = "The session ended: the voice model ended the session: the connection closed"
        ended.notesLine = "Notes: 2 files from 1 place"
        ended.spendLine = "41 sessions so far, about $1.87 by their own estimates"

        // Each state is laid out in a real window that is never shown, and that window's
        // view is drawn to a picture, so the pictures have the real pickers and text fields.
        _ = NSApplication.shared
        for (name, controller) in [("idle", idle), ("first-run", firstRun), ("briefed", briefed), ("preparing", preparing), ("prepared", prepared), ("discussion", discussion), ("discussion-no-brief", discussionBare),
                                   ("discussion-listening", listening), ("stand-asks-you", questioned), ("speaking", speaking), ("asking", asking), ("waiting", waiting), ("ended", ended),
                                   ("talk-with-pages", withPages), ("talk-with-pages-in-chrome", inChrome), ("notes-with-pages", notes), ("talk-with-pages-missing", pagesMissing), ("pages-showing", showing)] {
            let view = NSHostingView(rootView: PanelView(controller: controller).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // One turn of the run loop: SwiftUI finishes its first layout on it.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "Stand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render the \(name) panel."])
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "Stand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render the \(name) panel."])
            }
            try png.write(to: out.appendingPathComponent("\(name).png"))
            print("wrote \(out.appendingPathComponent("\(name).png").path)")
        }
    }
}

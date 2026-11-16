import Foundation

/// The brain keeping watch over a talk.
///
/// The voice model hears the room and answers it by itself, and understands every word.
/// The stage manager keeps the place in the talk and the screen, and understands none.
/// So when someone in the audience steers the talk in words ("thanks, you can continue",
/// "hold on a minute", "skip to the part about search"), the voice acts on it and the
/// stage manager never hears. The first time a person tried a talk with pages, on
/// 2026-11-15, they asked for the page before, said "you can continue", and Stand gave a
/// whole section under the page they had asked for.
///
/// The watch is the part that both understands words and sees everything at once. It is a
/// brain of its own, asked every few seconds and each time someone in the audience has
/// spoken. It is shown the place in the talk, what is on the screen and why, what has
/// been said, and what Stand is about to say (the voice model makes its words seconds
/// ahead of its sound). It answers with one line, which is nearly always NOTHING. It
/// never speaks to the meeting and never writes Stand's words.
///
/// The rules for it are in prompts/brain-watch.md. This is the form of what it is shown
/// and of what it may answer, shared by the session and by `Stand --probe watch`.
public enum WatchCommand: Equatable, CustomStringConvertible {
    /// The screen should show this section's page: Stand is giving that section.
    case show(String)
    /// The talk has moved to this section, because someone asked for it.
    case place(String)
    /// Someone asked Stand to stop for a while: hand it nothing until told to go on.
    case wait
    /// Someone said to go on, and Stand is waiting to be handed the next part.
    case go

    public var description: String {
        switch self {
        case .show(let section): return "SHOW \(section)"
        case .place(let section): return "PLACE \(section)"
        case .wait: return "WAIT"
        case .go: return "GO"
        }
    }
}

/// Where a talk stands at one moment, as the watch is shown it.
public struct WatchState {
    public struct Line {
        public var t: Double
        public var stand: Bool
        public var text: String
        public init(t: Double, stand: Bool, text: String) {
            self.t = t
            self.stand = stand
            self.text = text
        }
    }

    /// Why the screen shows what it shows.
    public enum Why { case talk, asked, scrolled }

    public struct OnScreen {
        /// The section whose page it is, by number and title.
        public var section: String
        public var title: String
        /// What is at the top of it, as the last look found it.
        public var showing: String
        public var why: Why
        /// How long it has been there.
        public var seconds: Double
        /// False when the last page asked for did not come up.
        public var came: Bool
        public init(section: String, title: String, showing: String, why: Why, seconds: Double, came: Bool) {
            self.section = section
            self.title = title
            self.showing = showing
            self.why = why
            self.seconds = seconds
            self.came = came
        }
    }

    /// Seconds since the session began.
    public var clock = 0.0
    /// The section the stage manager last handed to Stand, by number and title. Nil before the talk.
    public var section: String?
    public var sectionTitle = ""
    public var handedAt = 0.0
    /// Stand was stopped while giving it.
    public var stoppedInIt = false
    public var pointsHeard = 0, points = 0
    /// Nil when the talk has no screen.
    public var screen: OnScreen?
    /// The last minute, oldest first: Stand's words as the audience heard them, and the room's as the transcript has them.
    public var said = [Line]()
    /// What Stand has made and the audience has not yet heard.
    public var coming = ""
    public var standSpeaking = false, roomSpeaking = false
    public var quietFor = 0.0
    /// How long the talk has been waiting at the watch's own word. Nil when it is not.
    public var heldFor: Double?
    public var lookingUp = false
    public init() {}
}

public enum Watch {
    /// The message that shows the watch where things stand. `afterSomeoneSpoke`: it is
    /// asked because someone in the audience has just said something, not because a few
    /// seconds have passed.
    public static func request(root: URL, state: WatchState, afterSomeoneSpoke: Bool) throws -> String {
        try Project.read("prompts/brain-watch-request.txt", root: root)
            .replacingOccurrences(of: "{why}", with: afterSomeoneSpoke ? "Someone in the meeting has just spoken." : "A few seconds have passed.")
            .replacingOccurrences(of: "{clock}", with: clock(state.clock))
            .replacingOccurrences(of: "{place}", with: place(state))
            .replacingOccurrences(of: "{screen}", with: screen(state))
            .replacingOccurrences(of: "{said}", with: said(state))
            .replacingOccurrences(of: "{coming}", with: coming(state))
            .replacingOccurrences(of: "{now}", with: now(state))
    }

    /// What a reply asks for: nothing (an empty list), or one or two commands. Nil when
    /// the reply is not in the form at all.
    public static func commands(reply: String) -> [WatchCommand]? {
        var commands = [WatchCommand]()
        var understood = false
        for line in reply.split(whereSeparator: \.isNewline) {
            let words = line.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard let first = words.first else { continue }
            // "SHOW 3", "SHOW SECTION 3": the number is the first thing after the word that has a digit in it.
            let number = words.dropFirst().first { $0.contains(where: \.isNumber) }.map { String($0.filter(\.isNumber)) }
            switch first {
            case "NOTHING", "NONE": understood = true
            case "SHOW": if let number { commands.append(.show(number)); understood = true }
            case "PLACE": if let number { commands.append(.place(number)); understood = true }
            case "WAIT": commands.append(.wait); understood = true
            case "GO": commands.append(.go); understood = true
            default: break
            }
        }
        return understood ? commands : nil
    }

    public static func clock(_ t: Double) -> String {
        String(format: "%d:%02d", Int(max(0, t)) / 60, Int(max(0, t)) % 60)
    }

    private static func ago(_ seconds: Double) -> String {
        let n = Int(max(0, min(seconds, 36000)).rounded())
        return n <= 1 ? "a moment ago" : "\(n) seconds ago"
    }

    static func place(_ state: WatchState) -> String {
        guard let section = state.section else { return "the talk has not started." }
        var text = "section \(section), \"\(state.sectionTitle)\", handed to Stand at \(clock(state.handedAt))."
        if state.points > 0 {
            text += state.pointsHeard == 0 ? " None of its \(state.points) points has been heard since."
                : state.pointsHeard >= state.points ? " All \(state.points) of its points have been heard since."
                : " \(state.pointsHeard) of its \(state.points) points \(state.pointsHeard == 1 ? "has" : "have") been heard since."
        }
        if state.stoppedInIt { text += " Stand was stopped while giving it." }
        return text
    }

    static func screen(_ state: WatchState) -> String {
        guard let screen = state.screen else { return "this talk has no screen." }
        guard screen.came else {
            return "the page of section \(screen.section), \"\(screen.title)\", was asked for \(ago(screen.seconds)) and did not come up. Stand has been told."
        }
        var text = "the page of section \(screen.section), \"\(screen.title)\""
        if !screen.showing.isEmpty { text += ", with \"\(screen.showing)\" at the top" }
        text += ". "
        switch screen.why {
        case .talk:
            text += screen.section == state.section ? "It is the page of the section the talk is at."
                : "The stage manager put it up \(ago(screen.seconds)) for the section that comes next."
        case .asked:
            text += "It was put up \(ago(screen.seconds)) because someone in the audience asked to see it. The place in the talk did not move for it"
                + (state.section.map { $0 == screen.section ? "." : ": the talk's own page, for section \($0), is not on the screen." } ?? ".")
        case .scrolled:
            text += "Someone in the audience asked for it to be scrolled, \(ago(screen.seconds)), and it is where they left it, not where the talk is."
        }
        return text
    }

    static func said(_ state: WatchState) -> String {
        guard !state.said.isEmpty else { return "(nothing)" }
        return state.said.map { "[\(clock($0.t))] \($0.stand ? "Stand" : "In the meeting"): \($0.text)" }.joined(separator: "\n")
    }

    static func coming(_ state: WatchState) -> String {
        let text = state.coming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Stand has nothing more ready to say." }
        // The first few hundred characters say what it is doing; a whole section is not needed.
        let shown = text.count > 420 ? String(text.prefix(420)) + " …" : text
        return "Stand is about to say, not yet heard: \"\(shown)\""
    }

    static func now(_ state: WatchState) -> String {
        var text = state.roomSpeaking ? "someone in the meeting is speaking."
            : state.standSpeaking ? "Stand is speaking."
            : state.quietFor >= 2 && state.quietFor < 3600 ? "nobody is speaking, for \(Int(state.quietFor.rounded())) seconds now."
            : "nobody is speaking."
        if state.lookingUp { text += " Stand is waiting for its brain to look something up." }
        if let held = state.heldFor {
            text += " The talk is waiting at your word (WAIT), for \(Int(max(0, min(held, 36000)).rounded())) seconds now: the stage manager hands Stand nothing until you say GO."
        }
        return text
    }
}

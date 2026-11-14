import Foundation

/// One Stand session: it connects the voice model, passes it what Stand hears, keeps the
/// clock, plays stage manager to keep a talk moving, and writes the whole run to disk when
/// it ends. This is the Swift port of poc/src/session.js; DECISIONS.md explains each rule.
///
/// It knows nothing about microphones or speakers. Whoever owns it calls `hear` with
/// audio and plays what `onSpeech` hands back, which is how the scripted audience can
/// rehearse a talk with no audio hardware at all.
public final class StandSession {
    public struct Settings {
        /// The talk Stand gives. Empty when it gives none and takes part in a discussion
        /// instead: it listens, and speaks when there is a reason to (prompts/attendee.md).
        public var talk = "talks/introducing-stand.md"
        public var attending: Bool { talk.isEmpty }
        /// This program, not the voice service, decides when someone has started and
        /// stopped speaking, from how loud the room is (`SpeechMarker`). The service then gets
        /// every utterance from its first sound. Left to mark speech itself, it often lost
        /// the first word of anything said about a second after someone else had finished,
        /// Stand's name among them. On unless turned off: here, or for one run with
        /// STAND_OWN_ACTIVITY=off, which is the way back if a room defeats the detector.
        public var ownActivity: Bool?
        var marksActivity: Bool {
            switch ProcessInfo.processInfo.environment["STAND_OWN_ACTIVITY"] {
            case "on": return true
            case "off": return false
            default: return ownActivity ?? true
            }
        }
        /// With `ownActivity`: this much quiet ends an utterance, and Stand may answer.
        public var ownActivityEndsAfter = 0.7
        /// Stand may put a question to its human when it is asked something only they
        /// can say. The question goes to whoever owns the session (the panel), and the
        /// answer comes back through `answer(question:with:)`. Off for a run with nobody there to answer.
        public var canAskHuman = true
        /// In a discussion a second brain follows the meeting through the transcript and
        /// keeps a sheet in front of Stand, as a prompter does for an actor
        /// (`PrompterSheet`): the thread of the meeting before the last few minutes, which
        /// is all the voice model holds; the facts from the notes that bear on what is
        /// being discussed; what Stand owes; and now and then a point worth making.
        public var hasPrompter = true
        /// In a talk, the stage manager hands Stand one section at a time and keeps the
        /// place. Off (`--whole-talk` on a rehearsal), Stand keeps its own place in the
        /// plan and is only told to carry on, as it was until 2026-11-13.
        public var handsSections = true
        /// The prompter is asked for a new sheet once this many characters have been said
        /// since the last, and not more often than every `prompterEvery` seconds.
        public var prompterAfterCharacters = 160
        public var prompterEvery = 10.0
        /// It is also asked, whatever little has been said, when nobody has spoken for this
        /// long: a question may be hanging that Stand did not catch as its own. Asked at two
        /// and a half seconds, it judged the quiet too short to mean anything, and by the
        /// time it was asked again the meeting had moved on.
        public var prompterAtLull = 3.0
        /// The sheet is passed to Stand when what is on it has changed, not more often than
        /// every `sheetAtMostEvery` seconds, and at least every `sheetEvery`.
        public var sheetAtMostEvery = 20.0
        /// In a talk the prompter is asked again when this much more has been heard: about twenty seconds of speech.
        public var prompterAfterCharactersInTalk = 300
        public var sheetEvery = 60.0
        /// A point the prompter thought worth saying is dropped if no opening has come for it in this long.
        public var cueKeepsFor = 30.0
        /// In a discussion: how long the start of an utterance is kept from the service when
        /// it comes just after the last one was closed, while the model is taking its turn
        /// on that one. See `startHeld`. "Nothing to say" was over within 1.1 seconds of the
        /// close in every run looked at, and when Stand spoke instead its first sound came
        /// within 1.7. 0 tells the service at once.
        public var turnFinishesWithin = 2.0
        /// In a discussion: the pause that ends an utterance when Stand has no part in the
        /// exchange, which is when it has not spoken for `inTheExchangeFor` seconds and is
        /// not waiting on anything. For an evening this was 1.5 seconds, to give Stand
        /// fewer turns, each of which is paid for (`Spend`). It made one utterance out of
        /// several people's sentences, and of such an utterance the model catches less:
        /// asked "Stand, anything else from you?" a second after someone else's sentence,
        /// it answered in 16 runs of 35, and in 14 of 14 with each sentence an utterance of
        /// its own. Shortening the pauses inside the long utterance did not help (5 of 8).
        /// So this is the same as `ownActivityEndsAfter` now, and Stand takes about three
        /// times as many turns in a meeting. 1.5 on a rehearsal's command line is the
        /// comparison.
        public var endsAfterWhenOut = 0.7
        public var inTheExchangeFor = 15.0
        /// In a discussion, a remark from Stand that is over in less than this is not
        /// played. It is a stray word such as "Silent", said where it meant to say nothing.
        public var shortestRemark = 0.9
        /// What Stand's human wrote about this meeting beforehand. Empty for none.
        public var brief = ""
        /// Whose voice Stand speaks with: a name from prompts/voices-gemini.txt. The panel
        /// has the choice; STAND_VOICE sets it for one run from the command line. A name
        /// that is not on the list stops the session before it starts, because the voice
        /// service would not: it speaks with another voice and says nothing.
        public var voice = ProcessInfo.processInfo.environment["STAND_VOICE"] ?? Voices.usual
        /// A note passed while Stand is talking reaches it in the pause at the end of a
        /// sentence, as a person would read one. If no such pause comes within this long,
        /// any short pause will do, and three seconds after that it reaches it regardless.
        public var noteLandsWithin = 6.0
        /// A reply to a private note that is shorter than this is not played. It is the
        /// model saying a word such as "Silent" where it means to say nothing.
        public var shortestReplyToNote = 1.0
        /// Starting a session waits this long, at most, for linked repositories to be
        /// checked. A check that takes longer carries on, and the notes are read again when it lands.
        public var linkedCheckSeconds = 4.0
        /// Pause before "carry on" once the model has reported its turn finished.
        public var carryOnAfterTurn = 0.2
        /// The same, when the model has not reported it.
        public var carryOnAfterSpeech = 1.2
        /// Room silence required after Stand was cut off. Longer than a pause inside a question.
        public var carryOnAfterCut = 3.5
        /// The same, when what stopped Stand was a note from its human and not someone
        /// speaking. It usually goes on by itself within a second.
        public var carryOnAfterNote = 1.2
        /// Room silence required after the room made sound and Stand said nothing more.
        public var carryOnAfterRoom = 3.0
        /// In a talk handed over a section at a time: sent back to a section it was stopped
        /// in, Stand has this long to speak before it is taken to have had nothing left of it.
        public var resumeDrawsNothingAfter = 4.0
        /// In a talk: how much of a sound has to be loud before it stops Stand in the
        /// middle of speaking. Under that, a cough, an "mm-hm" or a short laugh is let pass
        /// and Stand keeps talking, as a person would. 0 stops it for anything, at once, as
        /// it did until 2026-11-13. STAND_CUTS_IN_AFTER sets it for one run.
        public var talkCutsInAfter = ProcessInfo.processInfo.environment["STAND_CUTS_IN_AFTER"].flatMap { Double($0) } ?? 0.6
        /// A reply to "carry on" shorter than this means Stand is waiting on purpose.
        public var shortReply = 4.0
        /// Louder than this (RMS out of 32768) counts as the room making sound. With
        /// `ownActivity` it is also the least a voice has to be to reach the service at
        /// all, so STAND_VOICE_LEVEL can set it for one run, for a room with quiet voices.
        public var roomVoiceLevel = ProcessInfo.processInfo.environment["STAND_VOICE_LEVEL"].flatMap { Double($0) } ?? 500.0
        /// After Stand's first words, ignore the room for this long. An echo canceller
        /// needs about a second of Stand's voice before it stops leaking it.
        public var echoSettle = 0.0
        /// If the brain has not answered by then, Stand is told that it is taking a moment.
        /// It says so and carries on, and the answer reaches it later, as a note does.
        public var lookUpPatience = 5.0
        /// If the brain is by then reading or searching for the answer, it gets this much
        /// longer first. An answer out of code takes four to seven seconds, and "that's
        /// taking a moment" said just as it arrived came out as "That's taking a. Regarding
        /// your question", which is worse than a longer silence after "let me check".
        public var lookUpPatienceAtWork = 3.0
        /// While the brain looks something up, the stage manager holds "carry on" this long.
        public var lookUpHold = 9.0
        /// If the brain has not answered by then, it is told to stop, and Stand says it could not find it.
        public var lookUpLimit = 60.0
        /// How long a question from the brain to Stand's human stays open before the answer is no.
        public var askSeconds = 20.0
        /// For a run with nobody to ask: the brain's questions are answered this way after a second.
        public var answerAsks: Bool?
        /// Starting a session waits this long, at most, for the brain to be ready.
        public var brainStartSeconds = 12.0
        /// How many minutes of the meeting the voice model keeps word for word, at the
        /// least: its own speech and everyone else's. What was said before that is gone
        /// from it, and is the brain's to remember (the prompter's sheet). Every turn of
        /// the model is billed for everything it keeps, at about 1,500 tokens for a minute
        /// of speech, so this is most of what a long meeting costs: about 2 cents a turn
        /// at 3 minutes, 3 at 5, 5.5 at 10. The user's choice, 2026-11-13: start at 3.
        /// STAND_REMEMBER_MINUTES sets it for one run.
        public var rememberMinutes = ProcessInfo.processInfo.environment["STAND_REMEMBER_MINUTES"].flatMap { Double($0) } ?? 3.0
        /// For a test: the limit in tokens, exactly, in place of `rememberMinutes`. When
        /// the session reaches it the oldest is dropped until `contextKeeps` is left. 0
        /// leaves the service's own limit, about 105,000 tokens, which is more than an
        /// hour of talk and costs accordingly. STAND_CONTEXT_TOKENS sets it for one run.
        public var contextLimit = ProcessInfo.processInfo.environment["STAND_CONTEXT_TOKENS"].flatMap { Int($0) }
        /// With `contextLimit`: left at 0, two thirds of the limit.
        public var contextKeeps = 0

        /// What the voice service is told to keep, in tokens, for instructions of this
        /// length: nil when it is left to its own limit. The instructions are never
        /// dropped and count towards the limit, so the room for speech is what is left
        /// over. Worked out from `rememberMinutes`, the room for speech does not shrink
        /// when the instructions grow, as it did while the limit was one fixed number.
        public func memory(instructionsCharacters: Int) -> (limit: Int, keep: Int)? {
            if let limit = contextLimit {
                return limit > 0 ? (limit, contextKeeps > 0 ? contextKeeps : limit * 2 / 3) : nil
            }
            guard rememberMinutes > 0 else { return nil }
            // About four characters to a token, and some 500 tokens for the tools.
            let instructions = instructionsCharacters / 4 + 500
            let speech = Int(rememberMinutes * 1500)
            // The stage manager's messages and the brain's sheets of those minutes are kept with them.
            let keep = instructions + speech + 1000
            // The service drops the oldest only some 30 to 45 seconds after the limit is
            // passed (seen on 2026-11-13: set to 6,500, it let a session reach 8,000 and
            // 8,450 before cutting back to 5,300 and 5,800). So the limit sits just above
            // what is kept, and the model holds these minutes and up to two more.
            return (keep + 500, keep)
        }
        /// Once it is ready, the brain is asked what the notes cover, so that Stand knows
        /// what is worth looking up. Starting waits this long for that, at most, and goes without.
        public var outlineSeconds = 6.0
        /// When an interruption leaves at least this much generated speech unheard, Stand is
        /// told the last words that were heard. 0 turns that off.
        public var tellWhereCutAfter = 1.5
        public init() {}
    }

    public enum Speaker: String { case stand, room }

    public enum Update {
        case state(standSpeaking: Bool, roomSpeaking: Bool, floorOpen: Bool)
        case transcript(Speaker, String)
        case interrupted
        case carryOn
        /// Stand asked its brain a question.
        case lookingUp(String)
        /// The brain's answer, and how many seconds it took.
        case lookedUp(String, seconds: Double)
        /// Its human passed Stand a private note.
        case told(String)
        /// What the brain is doing while it works on an answer: "searching the web for …".
        case brainBusy(String)
        /// The brain wants a yes from Stand's human before it does something. Answer with `answer(ask:allow:)`.
        case asking(id: String, what: String, seconds: Double)
        case asked(id: String, allowed: Bool)
        /// Stand has a question for its human, and has told the meeting it will come back
        /// to it. Answer with `answer(question:with:)`.
        case askingHuman(id: String, question: String)
        /// Its human answered, or said there is no answer (nil).
        case humanAnswered(id: String, answer: String?)
        /// The prompter has put a new sheet in front of Stand, or (with `cue`) has a point
        /// it thinks worth making, which Stand may make or let go.
        case prompted(sheet: String, cue: String?)
        case error(String)
        case closed(reason: String, folder: URL?)
    }

    public struct Event {
        public let t: Double
        public let type: String
        /// For `stand_stop`: when the speech actually ran out. For `floor_open`: when it counts from.
        public var at: Double?
        public var detail: String?
    }

    public struct Line {
        public let who: Speaker
        public let t: Double
        public var updated: Double
        public var text: String
    }

    /// Called on the session's own queue.
    public var onUpdate: ((Update) -> Void)?
    /// Stand's speech to play: mono 16-bit little-endian PCM at 24 kHz.
    public var onSpeech: ((Data) -> Void)?
    /// Drop whatever speech is queued but not yet played.
    public var onFlush: (() -> Void)?

    /// Where the run is saved. Settled when the session opens: two sessions that start in
    /// the same second get different folders.
    public private(set) var folder: URL
    public let model = "gemini-3.8-live"

    private let root: URL
    private let settings: Settings
    private let queue = DispatchQueue(label: "stand.session")
    private var live: GeminiLive?
    private var timer: DispatchSourceTimer?
    private var eventsFile: FileHandle?
    private var beginText = "", carryOnText = "", finishText = "", hushText = ""
    private var cutOffText = "", cutOffUnknownText = ""
    private var noteText = "", noteMidSpeechText = "", noteMidSentenceText = "", noteMidSpeechUnknownText = "", noteWhileListeningText = ""
    private var t0 = Date()

    // Everything below is touched only on `queue`.
    private var events = [Event]()
    private var transcript = [Line]()
    private var roomChunks = [Data]()
    private var roomStart: Double?
    private var standSegments = [(start: Double, pcm: Data)]()
    private var playUntil = 0.0 // session time at which speech already sent runs out
    private var lastRoomVoice = -Double.infinity
    private var lastStandAudio = -Double.infinity
    private var turnCompleteAt: Double?
    private var standSpeaking = false
    private var roomSpeaking = false
    private var beganAt: Double?
    private var nudged = false // one "carry on" per silence
    // The talk is handed to Stand a section at a time, and the place in it is kept here,
    // not by the voice model, which holds only the last few minutes, nor by the brain's
    // sheet, which is always a few seconds behind. Left to keep its own place over ten
    // minutes, Stand gave half a section twice and ran three sections into one at the end.
    private var sections = [TalkPlan.Section]() // empty for a talk that numbers none: that one is kept moving with a plain "carry on"
    private var sectionGiven = -1 // the section Stand was last told to give, as a place in `sections`
    private var sectionGivenAt = 0.0
    private var sectionCutShort = false // Stand was stopped while giving it, and may not have finished it
    private var sectionPieces = [(startsAt: Double, text: String)]() // what Stand has said since that section was handed over, each piece at the moment its sound began
    private var resumeSentAt: Double? // Stand was sent back to a section it had been stopped in, and has not spoken since
    private var nothingLeftOfSection = false // that drew no speech: there was nothing left of the section to say
    private var unheardAtCut = 0.0 // how much speech Stand had ready and unheard when it was last stopped in a section
    private var pointsMatched = 0, pointsGiven = 0 // over the sections it gave unstopped: how many points could be found in its words
    private var beginSectionText = "", sectionText = "", sectionAfterCutText = "", sectionResumeText = "", sectionLastText = "", sectionsDoneText = ""
    private var lastCarryOn: (t: Double, spoken: Double)?
    private var floorOpenAt: Double?
    private var floorCancelled = false // Stand opened the floor, then was cut off before the ending was heard
    private var cutOff = false // Stand's last speech was cut short by someone speaking
    private var hushed = false // the human said stop: drop speech until this turn is over
    private var deafUntil = 0.0
    private var carryOns = 0
    private var interruptions = 0
    private var isClosed = false
    private var isOpen = false
    private var brain: Brain?
    private struct LookUp {
        let asked: Double
        let question: String
        var told = false // Stand has been told the answer is taking a moment, which answered its tool call
        var waitedLonger = false // the brain was at work on it when patience ran out, and was given a little longer
    }
    private var brainActiveAt: Double? // when the brain last reached for something
    private var lookUps = [String: LookUp]() // questions the brain has not answered yet
    private var asks = [String: CheckedContinuation<Bool, Never>]() // the brain's questions to Stand's human
    private var stillLookingText = "", lateAnswerText = "", noteFromHuman = "", noteFromBrain = ""
    private var lookUpAnsweredAt: Double? // an answer went to Stand and it has not started saying it yet
    private var hushedAt: Double?
    private var notesPassed = 0
    /// Who a note for Stand is from: its human, its brain with an answer it had promised,
    /// or the prompter with a point it thinks worth making.
    private enum NoteFrom { case human, brain, prompter }
    private var notesWaiting = [(text: String, since: Double, from: NoteFrom)]() // not yet handed to Stand
    private var noteLandedAt: Double? // a note stopped Stand's speech; the model reports that as an interruption a moment later
    private var stoppedForNote = false // Stand's speech was stopped by a note, and it has not spoken since
    private var carryOnNow = false // skip the wait before the next "carry on"
    private var noteHandedAt: Double? // a note reached a silent Stand, which may be about to speak because of it
    /// What Stand has begun to say after a note reached it, held back until it is clear
    /// that it should be heard. After a note that reached a silent Stand: until it has run
    /// to a second, so that a stray word is not played (`shortestReplyToNote`). After a
    /// note that arrived while someone was speaking: until that person has finished, so
    /// that Stand does not talk over them because of the note.
    private struct Held {
        var since: Double
        var whileListening = false
        /// In a discussion: the first moments of anything Stand says, held until it has
        /// run long enough to be a remark and not a stray word (`shortestRemark`).
        var opening = false
        var audio = [Data]()
        var seconds = 0.0
        var text = ""
    }
    private var held: Held?
    private var saidThisTurn = false // the model has produced sound or words since its last turn ended
    private var marker = SpeechMarker() // with `ownActivity`: decides when someone starts and stops speaking
    private var reported = Spend.Reported() // what the service says it counted, added up
    private var prompter: Brain? // the second brain, which follows the meeting
    private var sheetMessage = "", cueText = "", noteFromPrompter = ""
    private var sheet: PrompterSheet? // as the prompter last wrote it
    private var sheetTold: PrompterSheet? // as Stand was last shown it
    private var sheetToldAt = -Double.infinity
    private var sheetToTell: PrompterSheet? // written, and waiting for a quiet moment
    private var seenLines = 0, seenCharacters = 0 // how much of the transcript the prompter has been given
    private var heardGiven = -Double.infinity // in a talk: how far into Stand's own speech, as heard, the prompter has been given
    private var prompterAskedAt = 0.0
    /// When the service was last told that an utterance had ended, until the model's turn on it is known to be over.
    private var turnOpenSince: Double?
    /// The start of an utterance, with its sound so far, that the service has not been
    /// given yet. Someone began to speak in the moment after the last utterance was
    /// closed, while the model was taking its turn on it. Told at once, the service
    /// cancels that turn and loses the new utterance from its own transcript (26 runs of
    /// 26 of one script), and the model misses what was said about one time in five. The
    /// turn is mostly "nothing to say" and over in about half a second, so the start
    /// waits for it. If Stand begins to speak instead, the service is told at once.
    private var startHeld: Data?
    private var startHeldAt = 0.0
    private var lullAskedAt = -Double.infinity // when the prompter was last asked in a silence
    private var prompterInFlight = false
    private var cuesPassed = [String]() // every point the prompter has given as worth saying
    /// Points the prompter raised when it was told the room had gone quiet: a question
    /// nobody was answering, mostly. Such a point is about the silence, and is void once
    /// someone else speaks. One that outlived it was handed to Stand after the person who
    /// had been asked gave their answer, and Stand answered the question a second time.
    private var quietCues = Set<String>()
    private var humanQuestions = [String: String]() // what Stand has asked its human and not had an answer to
    private var humanAskedText = "", humanAskedSaySoText = "", humanAnswerText = "", humanNoAnswerText = ""
    private var spokeThisTurn = false // the model has produced speech since its last turn ended
    private var piecesThisTurn = 0 // how many fragments of its own words the model has produced since its last turn ended
    private var notesHeldUntil: Double? // a note is waiting for Stand to finish its turn on what the room just said
    private var instructionsCharacters = 0
    private var lastSentToService = 0.0 // with `ownActivity`: when the service last got anything from the microphone
    private var notHeardText = ""
    /// What Stand has said lately, piece by piece as the model's transcript arrived (a
    /// second of speech each, or so), each with the moment its sound starts: a piece
    /// arrives just ahead of its audio. So a piece has been heard in full once the next
    /// one starts. The model generates far ahead of the speakers and counts everything it
    /// sent as said; this is how it can be told where it was actually cut off.
    private var spokenPieces = [(startsAt: Double, text: String)]()

    public init(root: URL, label: String, settings: Settings = Settings()) {
        self.root = root
        self.settings = settings
        marker = SpeechMarker(level: settings.roomVoiceLevel, endsAfter: settings.ownActivityEndsAfter)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        folder = root.appendingPathComponent("runs/\(formatter.string(from: Date()))-gemini-\(label)")
    }

    // MARK: Reading the session from outside

    public var now: Double { Date().timeIntervalSince(t0) }
    public var log: [Event] { queue.sync { events } }
    public var lines: [Line] { queue.sync { transcript } }
    public var isStandSpeaking: Bool { queue.sync { standSpeaking } }
    public var speechRunsOutAt: Double { queue.sync { playUntil } }
    public var began: Double? { queue.sync { beganAt } }
    public var closed: Bool { queue.sync { isClosed } }
    /// True once Stand has said it is waiting for the audience and that moment has been heard.
    public var floorOpen: Bool { queue.sync { floorIsOpen } }
    /// How long Stand has actually been heard speaking so far.
    public var spokenSeconds: Double { queue.sync { spoken() } }
    /// True while Stand has asked its brain something and is still waiting on the spot for the answer.
    public var waitingOnBrain: Bool { queue.sync { lookUps.values.contains { !$0.told } } }
    public private(set) var summary: [String: Any] = [:]
    /// The voice this session speaks with, as the service spells it. Set when it opens.
    public private(set) var voice = Voices.usual
    /// True when this program, and not the voice service, marks who is speaking.
    public var marksActivity: Bool { settings.marksActivity }

    // MARK: Running it

    public func open() async throws {
        // Linked repositories are checked first, so the notes are as they stand on GitHub now.
        // The key first: without it nothing else is worth starting.
        let key = try Project.geminiKey(root: root)
        voice = try Voices.named(settings.voice, root: root).name
        let brainSettings = BrainSettings.load(root: root)
        let library = NotesLibrary(root: root, settings: brainSettings)
        // The brain is a program of its own. If the session does not open after all (no
        // credit, a refused key), it must not be left running.
        var opened = false
        defer {
            if !opened {
                brain?.stop()
                brain = nil
                prompter?.stop()
                prompter = nil
                live?.close()
            }
        }
        let checked = await LinkedRepos.refresh(root: root, sources: library.sources, waitingAtMost: settings.linkedCheckSeconds)
        brain = try BrainFactory.make(root: root)
        brain?.onAsk = { [weak self] ask in await self?.ask(ask) ?? false }
        brain?.onActivity = { [weak self] what in
            self?.queue.async {
                guard let self, self.isOpen, !self.isClosed else { return }
                self.brainActiveAt = self.now
                self.record("brain", detail: what)
                self.onUpdate?(.brainBusy(what))
            }
        }
        // The prompter starts at the same time, as a process of its own. In a discussion it
        // follows the meeting; in a talk it keeps track of where the talk stands and of
        // what has passed with the audience, which Stand itself forgets after a few minutes.
        prompter = settings.hasPrompter ? try? BrainFactory.makePrompter(root: root, talk: settings.attending ? nil : settings.talk) : nil
        let prompterStarting = prompter.map { starting in Task { await starting.start() } }
        // The brain is got ready before the voice is told it has one. If it cannot be, Stand
        // goes without: better "I don't know" than "let me check" and then nothing.
        var brainProblem: String?
        if let starting = brain {
            brainProblem = await Self.within(settings.brainStartSeconds) { await starting.start() }
                ?? "it was not ready after \(Int(settings.brainStartSeconds)) seconds"
            if brainProblem == "" { brainProblem = nil }
            if brainProblem != nil {
                starting.stop()
                brain = nil
            }
        }
        var prompterProblem: String?
        if let prompterStarting {
            prompterProblem = await Self.within(settings.brainStartSeconds) { await prompterStarting.value }
                ?? "it was not ready after \(Int(settings.brainStartSeconds)) seconds"
            if prompterProblem == "" { prompterProblem = nil }
            if prompterProblem != nil {
                prompter?.stop()
                prompter = nil
            }
        }
        // Stand cannot see its notes. A sentence or two from the brain on what they cover
        // tells it what is worth looking up; without that it says "I don't know" to
        // questions it has no reason to think the notes answer.
        var outline: String?
        // Asked only when the brain has the notes in front of it: too many to send whole,
        // it would have to read through them with its tools, which takes far too long here.
        let notes = library.current()
        if let brain, !notes.isEmpty, notes.fits(within: brainSettings.docsStuffLimitChars),
           let ask = try? Project.read("prompts/brain-outline.txt", root: root) {
            let said = await Self.within(settings.outlineSeconds) { try? await brain.answer(ask) }
            if case .some(.some(let text)) = said {
                let text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                // A sentence or two, or nothing: anything longer is not an outline.
                if !text.isEmpty, text.count <= 700, !text.hasPrefix("NONE"), !text.hasPrefix("NOT FOUND") { outline = text }
            } else if said == nil {
                brain.giveUp() // still at it: the meeting's own questions must not wait behind this one
            }
        }
        let instructions = try Project.instructions(root: root, talk: settings.talk, brief: settings.brief, canLookUp: brain != nil,
                                                    notesOutline: outline, canAskHuman: settings.canAskHuman)
        let attending = settings.attending
        beginText = try Project.stageManagerBegin(root: root)
        carryOnText = try Project.stageManagerCarryOn(root: root)
        if !attending, settings.handsSections {
            sections = TalkPlan.sections(in: try Project.read(settings.talk, root: root))
            // One section is no talk to keep a place in.
            if sections.count < 2 { sections = [] }
            beginSectionText = try Project.read("prompts/stage-manager-begin-section.txt", root: root)
            sectionText = try Project.read("prompts/stage-manager-section.txt", root: root)
            sectionAfterCutText = try Project.read("prompts/stage-manager-section-after-cut.txt", root: root)
            sectionResumeText = try Project.read("prompts/stage-manager-section-resume.txt", root: root)
            sectionLastText = try Project.read("prompts/stage-manager-section-last.txt", root: root)
            sectionsDoneText = try Project.read("prompts/stage-manager-sections-done.txt", root: root)
        }
        finishText = try Project.read("prompts/stage-manager-finish.txt", root: root)
        // Cut off in a talk, Stand goes back to the talk. Cut off in a discussion, it gives way.
        cutOffText = try Project.read(attending ? "prompts/attend-cut-off.txt" : "prompts/stage-manager-cut-off.txt", root: root)
        cutOffUnknownText = try Project.read(attending ? "prompts/attend-cut-off-unknown.txt" : "prompts/stage-manager-cut-off-unknown.txt", root: root)
        notHeardText = try Project.read("prompts/attend-not-heard.txt", root: root)
        hushText = try Project.read("prompts/stage-manager-hush.txt", root: root)
        noteText = try Project.read("prompts/stage-manager-note.txt", root: root)
        noteMidSpeechText = try Project.read("prompts/stage-manager-note-mid-speech.txt", root: root)
        noteMidSentenceText = try Project.read("prompts/stage-manager-note-mid-sentence.txt", root: root)
        noteMidSpeechUnknownText = try Project.read("prompts/stage-manager-note-mid-speech-unknown.txt", root: root)
        noteWhileListeningText = try Project.read("prompts/stage-manager-note-while-listening.txt", root: root)
        noteFromHuman = try Project.read("prompts/note-from-human.txt", root: root)
        noteFromBrain = try Project.read("prompts/note-from-brain.txt", root: root)
        stillLookingText = try Project.read("prompts/lookup-still-looking.txt", root: root)
        sheetMessage = try Project.read(attending ? "prompts/attend-sheet.txt" : "prompts/talk-sheet.txt", root: root)
        cueText = try Project.read("prompts/stage-manager-cue.txt", root: root)
        noteFromPrompter = try Project.read("prompts/note-from-prompter.txt", root: root)
        humanAskedText = try Project.read("prompts/human-asked.txt", root: root)
        humanAskedSaySoText = try Project.read("prompts/human-asked-say-so.txt", root: root)
        humanAnswerText = try Project.read("prompts/human-answer.txt", root: root)
        humanNoAnswerText = try Project.read("prompts/human-no-answer.txt", root: root)
        let askHumanTool = settings.canAskHuman ? try Project.read("prompts/tool-ask-my-human.txt", root: root) : nil
        lateAnswerText = try Project.read("prompts/lookup-late-answer.txt", root: root)

        let live = GeminiLive { [weak self] event in
            self?.queue.async { self?.handle(event) }
        }
        self.live = live
        let lookUpTool = try brain.map { _ in try Project.read("prompts/tool-look-it-up.txt", root: root) }
        let quietTool = try Project.read(attending ? "prompts/attend-tool-nothing-to-say.txt" : "prompts/tool-nothing-to-say.txt", root: root)
        instructionsCharacters = instructions.count
        let memory = settings.memory(instructionsCharacters: instructions.count)
        try await live.connect(apiKey: key, instructions: instructions, model: model, voice: voice, lookUp: lookUpTool, quiet: quietTool, askHuman: askHumanTool,
                               floor: !attending, marksActivity: settings.marksActivity, context: memory)

        try queue.sync {
            t0 = Date() // session time counts from the moment the voice model is connected
            // The run folder is created only once connected, so a failed connection leaves nothing behind.
            // Another session may have taken the name in the same second: creating it fails then, and the next name is tried.
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let wanted = folder
            for suffix in ["", "-b", "-c", "-d", "-e", "-f"] {
                let candidate = wanted.deletingLastPathComponent().appendingPathComponent(wanted.lastPathComponent + suffix)
                do {
                    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                    folder = candidate
                    break
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            let eventsURL = folder.appendingPathComponent("events.jsonl")
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            eventsFile = try FileHandle(forWritingTo: eventsURL)
            try instructions.write(to: folder.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
            isOpen = true
            record("opened", detail: "\(model), \(attending ? "a discussion, no talk" : settings.talk), \(settings.brief.isEmpty ? "no brief" : "briefed"), brain: \(brain?.summary ?? "none (no notes to look things up in)")")
            for problem in library.problems { record("notes_problem", detail: problem) }
            record("memory", detail: memory.map { "the voice model keeps \($0.keep) to \($0.limit) tokens: its instructions and "
                + (settings.contextLimit == nil ? String(format: "at least the last %g minutes", settings.rememberMinutes) : "what fits beside them") }
                ?? "the voice model keeps all the service lets it")
            if let outline { record("notes_outline", detail: outline) }
            if let prompterProblem { record("brain_problem", detail: "the prompter: \(prompterProblem)") }
            if let brainProblem {
                record("brain_problem", detail: brainProblem)
                onUpdate?(.error("Stand's brain could not start, so it will not look anything up: \(brainProblem)"))
            }
            if let checked {
                for status in checked { record(status.error == nil ? "linked" : "notes_problem", detail: status.line()) }
            } else {
                record("notes_problem", detail: String(format: "linked repositories were still being checked after %.0f s; the copies on this Mac are in use", settings.linkedCheckSeconds))
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        opened = true
    }

    /// Tells Stand to start the talk. In a discussion there is nothing to tell it: it is
    /// in the room from this moment, listening.
    public func begin() {
        queue.async {
            guard self.isOpen, !self.isClosed, self.beganAt == nil else { return }
            self.beganAt = self.now
            if self.settings.attending {
                self.record("joined")
            } else if let first = self.sections.first {
                self.sectionGiven = 0
                self.sectionGivenAt = self.now
                self.live?.instruct(self.fill(self.beginSectionText, with: first))
                self.record("begin", detail: "section \(first.number) of \(self.sections.count)")
            } else {
                self.live?.instruct(self.beginText)
                self.record("begin")
            }
        }
    }

    /// What Stand hears: mono 16-bit little-endian PCM at 16 kHz, sent without pause.
    public func hear(_ pcm: Data) {
        queue.async {
            guard self.isOpen, !self.isClosed else { return }
            let t = self.now
            if self.roomStart == nil { self.roomStart = t }
            self.roomChunks.append(pcm)
            if t < self.deafUntil {
                if !self.settings.marksActivity { self.live?.sendMicrophone(Data(count: pcm.count)) }
                return
            }
            guard self.settings.marksActivity else {
                // The voice service marks speech for itself and gets everything.
                if PCM.rms(pcm) > self.settings.roomVoiceLevel { self.roomIsLoud(at: t) }
                self.live?.sendMicrophone(pcm)
                return
            }
            // Stand marks speech (`SpeechMarker`): the service is told when an utterance
            // starts and stops, and gets only the utterances, each from a little before
            // its first sound.
            if self.settings.attending {
                let inTheExchange = t - self.lastStandAudio < self.settings.inTheExchangeFor || !self.lookUps.isEmpty || !self.notesWaiting.isEmpty
                self.marker.endsAfter = inTheExchange ? self.settings.ownActivityEndsAfter : self.settings.endsAfterWhenOut
            } else {
                // Giving a talk, Stand is not stopped by a short sound.
                self.marker.cutsInAfter = self.settings.talkCutsInAfter
            }
            let playUntil = self.playUntil, hasSpoken = !self.standSegments.isEmpty
            let events = self.marker.take(pcm, endingAt: t) { moment in hasSpoken && moment < playUntil + 0.2 }
            var batch = Data()
            func send() {
                guard !batch.isEmpty else { return }
                self.live?.sendMicrophone(batch)
                self.lastSentToService = t
                batch = Data()
            }
            for event in events {
                switch event {
                case .loud(let at):
                    self.roomIsLoud(at: at)
                case .started(_, let leadIn):
                    send()
                    if let since = self.turnOpenSince, self.settings.attending, t - since < self.settings.turnFinishesWithin {
                        self.startHeld = leadIn
                        self.startHeldAt = t
                        self.record("start_held", detail: String(format: "%.2f s after the last utterance was closed", t - since))
                    } else {
                        self.live?.activity(started: true)
                        batch.append(leadIn)
                    }
                case .sound(let frame, _):
                    if self.startHeld != nil { self.startHeld?.append(frame) } else { batch.append(frame) }
                case .passedOver(let from, let to, let loud):
                    self.record("passed_over", detail: String(format: "%.1f s of sound while Stand was speaking, %.1f s of it loud", max(0, to - from), loud))
                case .stopped:
                    self.releaseStart(why: "the utterance ended")
                    send()
                    self.live?.activity(started: false)
                    self.turnOpenSince = self.settings.attending ? t : nil
                }
            }
            send()
            if self.startHeld != nil, t - (self.turnOpenSince ?? -.infinity) >= self.settings.turnFinishesWithin {
                self.releaseStart(why: "waited long enough")
            }
            // Nothing is sent while the room is quiet, and after about two minutes of
            // nothing the service takes the session for abandoned and closes it. A
            // moment of silence now and then shows that Stand is still in the room.
            if !self.marker.isOpen, t - self.lastSentToService > 20 {
                self.lastSentToService = t
                self.live?.sendMicrophone(PCM.silence(seconds: 0.1, rate: GeminiLive.microphoneRate))
            }
        }
    }

    /// The room has gone quiet, but its last utterance is still open, waiting out the
    /// pause, and something now needs Stand's attention: a note, or an answer from its
    /// brain. While an utterance is open the service does not let Stand speak, so it is
    /// ended first. Without this a note passed in the second after someone stopped
    /// speaking was taken in with what they said, and Stand said nothing.
    private func endOpenUtterance(at t: Double) {
        guard settings.marksActivity, t - lastRoomVoice > 0.4, marker.stop() else { return }
        releaseStart(why: "the utterance was ended")
        live?.activity(started: false)
        turnOpenSince = settings.attending ? t : nil
    }

    /// Tells the service about an utterance whose start was kept back (`startHeld`), and
    /// gives it the sound so far in one piece.
    private func releaseStart(why: String) {
        guard let sound = startHeld else { return }
        startHeld = nil
        live?.activity(started: true)
        live?.sendMicrophone(sound)
        lastSentToService = now
        record("start_released", detail: String(format: "%@: %.2f s late, with %.2f s of sound", why, now - startHeldAt,
                                                Double(sound.count) / 2 / Double(GeminiLive.microphoneRate)))
    }

    /// The room made a sound over the bar at `t`: a voice, most often.
    private func roomIsLoud(at t: Double) {
        lastRoomVoice = t
        nudged = false
        if !roomSpeaking {
            roomSpeaking = true
            record("room_start")
            sendState()
        }
    }

    /// The human's override: Stand stops talking at once and waits to be spoken to.
    public func hush() {
        queue.async {
            guard self.isOpen, !self.isClosed else { return }
            self.hushed = true
            self.hushedAt = self.now
            self.held = nil
            self.cutSpeech(at: self.now)
            self.onFlush?()
            self.live?.nudge(self.hushText)
            self.record("hush")
        }
    }

    /// A private note from Stand's human, typed during the meeting. Stand acts on it and
    /// never mentions it; the audience hears nothing of the note itself.
    public func tell(_ note: String) {
        // The note is quoted inside the message, so its own double quotes become single ones.
        let note = note.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")
        guard !note.isEmpty else { return }
        queue.async {
            guard self.isOpen, !self.isClosed else { return }
            self.notesPassed += 1
            self.record("told", detail: note)
            self.onUpdate?(.told(note))
            self.notesWaiting.append((note, self.now, .human))
            self.landNotes()
        }
    }

    public func close(reason: String) {
        queue.async { self.finish(reason) }
    }

    /// Closes and returns once the run has been written to disk.
    public func closeAndWait(reason: String) {
        queue.sync { finish(reason) }
    }

    // MARK: The model's side

    private func handle(_ event: LiveEvent) {
        guard !isClosed else { return }
        switch event {
        case .audio(let pcm): standAudio(pcm)
        case .heard(let text): addTranscript(.room, text)
        case .said(let text):
            // The words can arrive before the sound. In a discussion they wait with it.
            holdOpening()
            // Words in reply to a note wait with their sound, until it is known to be speech.
            if held != nil, !text.isEmpty { held?.text += text } else { addTranscript(.stand, text) }
        case .interrupted:
            turnOpenSince = nil
            interrupted()
            saidThisTurn = false
            spokeThisTurn = false
            piecesThisTurn = 0
        case .turnComplete:
            turnOpenSince = nil
            releaseStart(why: "the model's turn was over")
            turnCompleteAt = now
            hushed = false
            saidThisTurn = false
            spokeThisTurn = false
            piecesThisTurn = 0
            if notesHeldUntil != nil { notesHeldUntil = now } // its turn on what the room said is over: the note can go
            // A turn is over in which Stand made no sound: its reply to a note was silence,
            // or the person it was waiting for has finished and it had nothing to add.
            // There is nothing left to hold back. Left in place, the hold took the next
            // thing Stand said, eleven seconds later, for more of the same, swallowed it
            // when someone spoke, and did not tell Stand, which then would not make the
            // point again because it thought it had.
            if let reply = held, !reply.opening, reply.audio.isEmpty, now - reply.since > 0.3,
               !reply.whileListening || now - lastRoomVoice > 0.4 {
                held = nil
            }
            if let reply = held, !reply.whileListening, !reply.audio.isEmpty || reply.opening {
                // The whole of it was under a second. In reply to a note that is a stray
                // word, not speech. In a discussion it can also be a short answer, such as
                // "I don't know", which is played: only a single word, or a sound with no
                // words to it, is taken for a slip.
                let words = reply.text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).count
                if reply.opening, words >= 2 {
                    releaseHeld()
                } else {
                    held = nil
                    if !reply.audio.isEmpty || words > 0 {
                        record("swallowed", detail: String(format: "%.1f s %@: %@", reply.seconds, reply.opening ? "and no more" : "in reply to a note",
                                                           reply.text.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        case .floorOpened:
            // The signal arrives when the words are generated, which can be well before
            // they are heard, so the floor only counts as open once that speech has played.
            guard floorOpenAt == nil else { return }
            // With sections still to give, and nobody having spoken since the last was handed
            // over, the talk is not finished: Stand has run ahead to its close.
            if !sections.isEmpty, sectionGiven + 1 < sections.count, lastRoomVoice < sectionGivenAt {
                record("floor_too_early", detail: "after section \(sections[max(0, sectionGiven)].number) of \(sections.count)")
                return
            }
            floorOpenAt = max(now, playUntil)
            floorCancelled = false
            record("floor_open", at: floorOpenAt)
        case .keptQuiet:
            record("kept_quiet")
            noteHandedAt = nil // it has read the note and has nothing to say: the talk can go on
            // Mid-talk, saying nothing is a stall: tell it to carry on without waiting out the usual pause.
            if stoppedForNote, !floorIsOpen {
                carryOnNow = true
                nudged = false
            }
        case .lookUp(let id, let question):
            lookUp(id: id, question: question)
        case .askHuman(let id, let question):
            // "I'd have to check that with Morgan" must be heard, short as it is.
            if let reply = held, reply.opening { releaseHeld() }
            let question = Self.oneLine(question)
            humanQuestions[id] = question
            record("human_asked", detail: question)
            onUpdate?(.askingHuman(id: id, question: question))
            // It is meant to say first that it will check. When it has asked without a
            // word, the person who asked would hear nothing: it is told to say so now.
            live?.respond(askHuman: id, result: spokeThisTurn ? humanAskedText : humanAskedSaySoText, aloud: !spokeThisTurn)
        case .usage(let promptText, let promptAudio, let responseAudio, let responseText, let thoughts):
            reported.messages += 1
            reported.promptText += promptText
            reported.promptAudio += promptAudio
            reported.responseAudio += responseAudio
            reported.responseText += responseText
            reported.thoughts += thoughts
            record("usage", detail: "given \(promptText) text and \(promptAudio) audio tokens; produced \(responseAudio) audio, \(responseText) text, \(thoughts) of thinking")
        case .reconnected(let why):
            record("reconnected", detail: why)
            turnOpenSince = nil
            releaseStart(why: "the connection was replaced")
            // Whatever the model was in the middle of saying is gone with the old connection.
            saidThisTurn = false
            if held?.opening == true { held = nil }
        case .closed(let reason):
            finish(GeminiLive.explain(reason) ?? "the voice model ended the session: \(reason)")
        }
    }

    /// Stand asked its brain something. The answer goes back to the voice model as the
    /// point to make; Stand says it in its own words.
    private func lookUp(id: String, question: String) {
        // "Let me check that" is short enough to pass for a stray word. It is not one: play it.
        if let reply = held, reply.opening { releaseHeld() }
        record("lookup", detail: question)
        onUpdate?(.lookingUp(question))
        guard let brain else {
            live?.respond(lookUp: id, answer: "NOT FOUND. There is nothing to look this up in.")
            return
        }
        let asked = now
        lookUps[id] = LookUp(asked: asked, question: question)
        // Nobody in a meeting waits long in silence for a fact. After a few seconds Stand
        // says it is taking a moment and carries on; the answer follows when it comes.
        queue.asyncAfter(deadline: .now() + settings.lookUpPatience) { [weak self] in self?.stillLooking(id) }
        queue.asyncAfter(deadline: .now() + settings.lookUpLimit) { [weak self] in
            guard let self, self.lookUps[id] != nil else { return }
            self.brain?.giveUp()
            self.answerLookUp(id, "NOT FOUND. It took too long to find.", asked: asked, note: "gave up waiting")
        }
        // The brain that answers is not the one that follows the meeting, so the thread goes with the question.
        let thread = (sheet?.soFar).flatMap { $0.isEmpty ? nil : "\n\nThe thread of the meeting so far, for when the question is about the meeting itself: \($0)" } ?? ""
        let queue = self.queue
        Task { [weak self] in
            var answer = "NOT FOUND. The lookup did not work. Say you could not check just now."
            var note: String?
            do {
                answer = try await brain.answer(question + thread)
            } catch {
                note = "failed: \(error)" // for the log, not for Stand to read out
            }
            queue.async { [answer, note] in self?.answerLookUp(id, answer, asked: asked, note: note) }
        }
    }

    /// The brain is taking longer than a pause in a conversation. Stand's tool call is
    /// answered with that, so it can say so and move on.
    private func stillLooking(_ id: String) {
        guard !isClosed, let lookUp = lookUps[id], !lookUp.told else { return }
        if !lookUp.waitedLonger, let active = brainActiveAt, active > lookUp.asked {
            lookUps[id]?.waitedLonger = true
            queue.asyncAfter(deadline: .now() + settings.lookUpPatienceAtWork) { [weak self] in self?.stillLooking(id) }
            return
        }
        lookUps[id]?.told = true
        record("lookup_slow", detail: lookUp.question)
        let quietly = hushedAt.map { $0 > lookUp.asked } ?? false
        if !quietly { lookUpAnsweredAt = now }
        endOpenUtterance(at: now)
        live?.respond(lookUp: id, answer: stillLookingText, quietly: quietly)
    }

    private func answerLookUp(_ id: String, _ answer: String, asked: Double, note: String?) {
        guard !isClosed, let lookUp = lookUps.removeValue(forKey: id) else { return } // answered already
        let t = now
        record("lookup_answer", detail: String(format: "%.1f s: %@%@", t - asked, answer, note.map { " (\($0))" } ?? ""))
        onUpdate?(.lookedUp(answer, seconds: t - asked))
        // If its human hushed Stand in the meantime, it learns the answer and keeps quiet.
        let quietly = hushedAt.map { $0 > asked } ?? false
        guard lookUp.told else {
            if !quietly { lookUpAnsweredAt = t }
            endOpenUtterance(at: t)
            live?.respond(lookUp: id, answer: answer, quietly: quietly)
            return
        }
        // Stand has already said it would come back to this. Its tool call is spent, so the
        // answer reaches it the way a note from its human does: at once if it is silent,
        // in its next pause if it is talking, and never across someone who is speaking.
        func plain(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
        }
        let text = lateAnswerText.replacingOccurrences(of: "{question}", with: plain(lookUp.question))
            .replacingOccurrences(of: "{answer}", with: plain(answer))
        if quietly {
            live?.inform(noteFromBrain.replacingOccurrences(of: "{note}", with: text))
        } else {
            notesWaiting.append((text, t, .brain))
            landNotes()
        }
    }

    // MARK: The brain's questions to Stand's human

    /// The brain wants to do something that needs a yes. The question goes to whoever owns
    /// the session (the panel), and stays open for a while. No answer is a no.
    private func ask(_ ask: BrainAsk) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard self.isOpen, !self.isClosed else { done.resume(returning: false); return }
                self.asks[ask.id] = done
                self.record("ask", detail: ask.what)
                self.onUpdate?(.asking(id: ask.id, what: ask.what, seconds: self.settings.askSeconds))
                if let answer = self.settings.answerAsks {
                    self.queue.asyncAfter(deadline: .now() + 1) { self.settle(ask.id, allow: answer, by: "this run's own setting") }
                }
                self.queue.asyncAfter(deadline: .now() + self.settings.askSeconds) {
                    self.settle(ask.id, allow: false, by: "nobody answered in time")
                }
            }
        }
    }

    /// Its human's answer to a question Stand put to them. Nil, or nothing but spaces,
    /// says they have none. It reaches Stand as a note does: at once if it is silent, when
    /// it has finished if it is speaking, and after whoever is speaking if someone is.
    public func answer(question id: String, with text: String?) {
        queue.async {
            guard self.isOpen, !self.isClosed, let question = self.humanQuestions.removeValue(forKey: id) else { return }
            let answer = text.map(Self.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            self.record("human_answer", detail: answer ?? "no answer")
            self.onUpdate?(.humanAnswered(id: id, answer: answer))
            let note = (answer.map { self.humanAnswerText.replacingOccurrences(of: "{answer}", with: $0) } ?? self.humanNoAnswerText)
                .replacingOccurrences(of: "{question}", with: question)
            self.notesWaiting.append((note, self.now, .human))
            self.landNotes()
        }
    }

    /// Text that will sit inside quotation marks in a message to Stand: one line, and no double quotes of its own.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")
    }

    /// Its human's answer to something the brain asked to do.
    public func answer(ask id: String, allow: Bool) {
        queue.async { self.settle(id, allow: allow, by: "its human") }
    }

    private func settle(_ id: String, allow: Bool, by who: String) {
        guard let done = asks.removeValue(forKey: id) else { return }
        record("ask_answer", detail: "\(allow ? "yes" : "no") (\(who))")
        onUpdate?(.asked(id: id, allowed: allow))
        done.resume(returning: allow)
    }

    /// Runs `work`, and gives up waiting for it after `seconds`. The work itself goes on.
    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T?? {
        await withCheckedContinuation { (done: CheckedContinuation<T??, Never>) in
            let lock = NSLock()
            var claimed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if claimed { return false }
                claimed = true
                return true
            }
            Task { let value = await work(); if claim() { done.resume(returning: .some(value)) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if claim() { done.resume(returning: nil) }
            }
        }
    }

    /// In a discussion, the first thing the model produces in a turn opens a hold: nothing
    /// is played, or written down as said, until there is enough of it to be a remark.
    private func holdOpening() {
        guard settings.attending, !saidThisTurn else { return }
        saidThisTurn = true
        // A new remark. If it is cut off, the words quoted back to Stand must be this
        // remark's own: quoted with the end of its last one, it took "what was not heard"
        // for the earlier point and made that one again.
        if now >= playUntil { spokenPieces.removeAll() }
        if held == nil, !hushed { held = Held(since: now, opening: true) }
    }

    private func standAudio(_ pcm: Data) {
        // Stand is answering the last utterance after all. If someone has begun to speak
        // meanwhile and the service has not been told, it is told now.
        if turnOpenSince != nil {
            turnOpenSince = nil
            releaseStart(why: "Stand began to speak")
        }
        guard !hushed else { return }
        spokeThisTurn = true
        holdOpening()
        if let reply = held {
            let t = now
            if reply.opening {
                held?.audio.append(pcm)
                held?.seconds += PCM.seconds(pcm, rate: GeminiLive.speechRate)
                if (held?.seconds ?? 0) >= settings.shortestRemark { releaseHeld() }
                return
            }
            if reply.whileListening {
                // Whoever was speaking when the note arrived has finished: this is Stand's answer.
                if t - lastRoomVoice > 0.4 || t - reply.since > 20 {
                    releaseHeld()
                } else {
                    held?.audio.append(pcm)
                    held?.seconds += PCM.seconds(pcm, rate: GeminiLive.speechRate)
                    return
                }
            } else if lastRoomVoice > reply.since || t - reply.since > 6 {
                // Once someone has spoken, whatever Stand says is an answer to them, however short.
                releaseHeld()
            } else {
                held?.audio.append(pcm)
                held?.seconds += PCM.seconds(pcm, rate: GeminiLive.speechRate)
                if (held?.seconds ?? 0) >= settings.shortestReplyToNote { releaseHeld() }
                return
            }
        }
        play(pcm)
    }

    /// Plays what was held back, now that it has turned out to be speech.
    private func releaseHeld() {
        guard let reply = held else { return }
        held = nil
        if !reply.text.isEmpty { addTranscript(.stand, reply.text) }
        for chunk in reply.audio { play(chunk) }
    }

    private func play(_ pcm: Data) {
        let t = now
        if standSegments.isEmpty, settings.echoSettle > 0 { deafUntil = t + settings.echoSettle }
        // The model sends speech faster than it is spoken, so keep a virtual playhead:
        // each chunk starts when the previous one finishes, or now if Stand was silent.
        let start = max(t, playUntil)
        standSegments.append((start, pcm))
        playUntil = start + PCM.seconds(pcm, rate: GeminiLive.speechRate)
        lastStandAudio = t
        cutOff = false
        stoppedForNote = false
        carryOnNow = false
        nudged = false
        if !standSpeaking {
            standSpeaking = true
            record("stand_start")
            sendState()
        }
        onSpeech?(pcm)
    }

    /// Throws away speech that had been sent but not yet played.
    private func cutSpeech(at t: Double) {
        while let last = standSegments.last {
            if last.start >= t {
                standSegments.removeLast()
                continue
            }
            let keep = Int(((t - last.start) * GeminiLive.speechRate).rounded()) * 2
            if keep < last.pcm.count { standSegments[standSegments.count - 1].pcm = last.pcm.prefix(keep) }
            break
        }
        playUntil = min(playUntil, t)
        // What had not begun to sound was never said, whatever the model thinks.
        sectionPieces.removeAll { $0.startsAt >= t }
    }

    private func interrupted() {
        let t = now
        if let reply = held, reply.opening, playUntil <= t {
            // In a discussion: Stand had only begun, someone else spoke at the same moment,
            // and none of it was played. The model counts it as said, so it is told otherwise.
            // It is told without being asked for a reply, and anything it starts to say
            // before that person has finished is held back.
            held = nil
            let begun = reply.text.trimmingCharacters(in: .whitespaces)
            guard !reply.audio.isEmpty || !begun.isEmpty else { return }
            record("swallowed", detail: String(format: "%.1f s begun as someone else spoke: %@", reply.seconds, begun))
            live?.inform(notHeardText)
            held = Held(since: t, whileListening: true)
            return
        }
        if let reply = held, reply.whileListening {
            // Stand began to speak because of a note while someone was still talking, and
            // the model has now cut that short itself. None of it was played.
            held = Held(since: reply.since, whileListening: true)
            if !reply.audio.isEmpty {
                record("swallowed", detail: String(format: "%.1f s begun while someone was still speaking: %@", reply.seconds, reply.text.trimmingCharacters(in: .whitespaces)))
            }
            if playUntil <= t { return } // nothing of Stand's was being heard
        } else {
            held = nil
        }
        // A note that stops Stand's speech makes the model report an interruption too.
        // That cut has been made, and Stand has been told where it was.
        if let landed = noteLandedAt, t - landed < 1.5 {
            noteLandedAt = nil
            cutSpeech(at: t)
            onFlush?()
            return
        }
        // In a discussion the service reports an interruption whenever someone starts to
        // speak while the model is still working on its turn, even a turn in which it was
        // deciding to say nothing. With nothing playing, nothing was cut off.
        if settings.attending, playUntil <= t {
            record("turn_dropped")
            return
        }
        let unheard = max(0, playUntil - t)
        tellWhereCut(at: t, unheard: playUntil - t)
        cutSpeech(at: t)
        if sectionGiven >= 0, !floorIsOpen { unheardAtCut = unheard }
        interruptions += 1
        // Cut off before reaching the end of the talk: the floor is not open after all.
        if let at = floorOpenAt, t < at {
            floorOpenAt = nil
            floorCancelled = true
            record("floor_not_open_after_all")
        }
        cutOff = true // until Stand speaks again
        stoppedForNote = false
        if sectionGiven >= 0, !floorIsOpen { sectionCutShort = true }
        record("interrupted")
        onFlush?()
        onUpdate?(.interrupted)
    }

    /// Tells Stand the last words the audience heard, when an interruption has thrown
    /// away speech it believes it gave. Without this it resumes after the part it only
    /// generated, and the audience never hears that part.
    private func tellWhereCut(at t: Double, unheard: Double) {
        let (tail, lostPieces) = forgetUnheard(at: t)
        // In a discussion a remark is short. One that was stopped before the model had
        // finished producing it is unfinished, however little of it was waiting to be
        // played, and without being told so Stand takes its point for made.
        let unfinished = settings.attending && saidThisTurn
        guard settings.tellWhereCutAfter > 0, unheard >= settings.tellWhereCutAfter || unfinished else { return }
        let message: String
        // Cut off as it began a new turn in a talk: nothing of this turn was heard whole,
        // and the last words heard are the end of what came before. Quoted those, Stand
        // said that sentence again. It is told to start what it had just begun afresh.
        // (The model may have finished producing the turn before a word of it was heard, so
        // the section's own words, each from the moment its sound began, are asked as well.)
        let asItBegan = !settings.attending && ((piecesThisTurn > 0 && lostPieces >= piecesThisTurn)
            || (sectionGiven >= 0 && !sectionPieces.isEmpty && sectionPieces.allSatisfy { $0.startsAt > t - 0.8 }))
        if asItBegan {
            message = cutOffUnknownText
            record("cut_off_note", detail: String(format: "%.1f s unheard; cut off as it began", unheard))
        } else if let tail, lostPieces > 0 || unfinished {
            message = cutOffText.replacingOccurrences(of: "{heard}", with: tail)
            record("cut_off_note", detail: String(format: "%.1f s unheard; heard up to: %@", unheard, tail))
        } else {
            // The model's transcript of itself is sometimes empty or far too short to quote.
            message = cutOffUnknownText
            record("cut_off_note", detail: String(format: "%.1f s unheard; no usable transcript", unheard))
        }
        live?.nudge(message)
    }

    /// How many of the pieces have been heard in full by `t`. A piece's sound runs from
    /// its own start to the next piece's, or to the end of the speech for the last one.
    private func piecesHeard(by t: Double) -> Int {
        var count = 0
        for i in spokenPieces.indices {
            let end = i + 1 < spokenPieces.count ? spokenPieces[i + 1].startsAt : playUntil
            if end <= t + 0.15 { count = i + 1 } else { break }
        }
        return count
    }

    /// Drops the pieces that were generated but not heard in full by `t`: as far as anyone
    /// listening knows, they were never said. Returns the last words that were heard, when
    /// there are enough to quote, and how many pieces were dropped.
    private func forgetUnheard(at t: Double) -> (tail: String?, lost: Int) {
        let heard = piecesHeard(by: t)
        let lost = spokenPieces.count - heard
        spokenPieces.removeSubrange(heard...)
        let words = spokenPieces.map(\.text).joined().split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return (nil, lost) }
        return ((words.count > 14 ? "… " : "") + words.suffix(14).joined(separator: " "), lost)
    }

    // MARK: Notes from Stand's human

    /// True when Stand's own sound is quiet from now until `ahead` seconds from now: a
    /// pause in its speech. The sound for the next moments is already here, because the
    /// model sends speech faster than it is spoken.
    private func inPause(at t: Double, ahead: Double) -> Bool {
        let rate = GeminiLive.speechRate
        let from = t - 0.04, to = t + ahead
        guard to < playUntil else { return false } // the speech received so far ends first
        var window = [Int16](repeating: 0, count: Int((to - from) * rate))
        for segment in standSegments.reversed() {
            if segment.start + PCM.seconds(segment.pcm, rate: rate) <= from { break } // in order: nothing earlier reaches this far
            if segment.start >= to { continue }
            let samples = PCM.samples(segment.pcm)
            let offset = Int(((segment.start - from) * rate).rounded())
            for (i, sample) in samples.enumerated() where offset + i >= 0 && offset + i < window.count { window[offset + i] = sample }
        }
        // Quiet all the way through, 20 ms at a time. Speech runs in the thousands; a pause,
        // with a breath in it, stays under 500.
        let frame = Int(0.02 * rate)
        var i = 0
        while i + frame <= window.count {
            var sum = 0.0
            for sample in window[i..<(i + frame)] { sum += Double(sample) * Double(sample) }
            if (sum / Double(frame)).squareRoot() > 600 { return false }
            i += frame
        }
        return true
    }

    /// The words heard up to the pause Stand is in at `t`. A pause comes where the writing
    /// has a mark, so of the marks in what Stand has said, this takes the one that the
    /// pieces' own timing puts nearest to `t`, and forgets everything after it. That timing
    /// is only good to about a second either way, which is why the moment to stop is taken
    /// from the sound and only the wording from here. A long pause is more likely the end
    /// of a sentence than a comma, so then a comma has to be clearly nearer to be taken.
    /// Nil when no mark is near.
    private func heardUpToMark(near t: Double, longPause: Bool) -> String? {
        var best: (piece: Int, length: Int, distance: Double)?
        for i in spokenPieces.indices.reversed() {
            let start = spokenPieces[i].startsAt
            let end = i + 1 < spokenPieces.count ? spokenPieces[i + 1].startsAt : playUntil
            if start - t > 1.5 { continue }
            if t - end > 1.5 { break }
            let characters = Array(spokenPieces[i].text)
            for (offset, character) in characters.enumerated() where ".?!,;:".contains(character) {
                var next = offset + 1
                while next < characters.count, "\"'”’)".contains(characters[next]) { next += 1 }
                guard next == characters.count || characters[next].isWhitespace else { continue } // "3.5" closes nothing
                let at = start + (end - start) * Double(next) / Double(characters.count)
                guard abs(at - t) <= 1.5 else { continue }
                let distance = abs(at - t) * (longPause && ",;:".contains(character) ? 1.6 : 1)
                if distance < (best?.distance ?? .infinity) { best = (i, next, distance) }
            }
        }
        guard let best else { return nil }
        spokenPieces[best.piece].text = String(Array(spokenPieces[best.piece].text)[..<best.length])
        spokenPieces.removeSubrange((best.piece + 1)...)
        let words = spokenPieces.map(\.text).joined().split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        return (words.count > 14 ? "… " : "") + words.suffix(14).joined(separator: " ")
    }

    /// Hands Stand the notes its human has passed, at a moment a person would read one: at
    /// once when Stand is silent, and at the end of the sentence when it is talking. Called
    /// when a note is passed, and on every tick while one is waiting.
    private func landNotes() {
        guard let first = notesWaiting.first, !isClosed else { return }
        // A remark Stand has just begun, still held back, is played: the note comes after it.
        if let reply = held, reply.opening, !reply.audio.isEmpty { releaseHeld() }
        let t = now
        let waited = t - first.since
        if first.from == .prompter {
            // A point from the prompter is about a moment, and it gives way to everything
            // else. No opening has come for it; or Stand has spoken since, and may just
            // have made this very point by itself, as it did with the date of the next
            // session; or a note from its human or an answer it promised is waiting, which
            // Stand once said two lines late because the prompter's point went first.
            var why: String?
            if waited > settings.cueKeepsFor {
                why = String(format: "no opening in %.0f s", waited)
            } else if lastStandAudio > first.since {
                why = "Stand spoke first"
            } else if quietCues.contains(first.text), lastRoomVoice > first.since {
                why = "someone else spoke first"
            } else if notesWaiting.contains(where: { $0.from != .prompter }) {
                why = "a note came first"
            }
            if let why {
                notesWaiting.removeFirst()
                quietCues.remove(first.text)
                // Unless its moment has simply passed, the prompter may raise it again: it
                // will have seen by then what Stand said.
                if waited <= settings.cueKeepsFor { cuesPassed.removeAll { $0 == first.text } }
                record("cue_dropped", detail: "\(why): \(first.text)")
                landNotes()
                return
            }
        }
        // A point from the prompter waits for a real opening: nobody heard, Stand included,
        // for a second and a half. Handed over the moment Stand finished an answer, it was
        // cut across by the next person and came out later, where it no longer fitted.
        if first.from == .prompter, settings.attending, t - max(lastRoomVoice, min(t, playUntil)) < 1.5 { return }
        // Stand is in the middle of looking something up, or has just been handed the answer
        // and not yet said it. A note now would take the turn in which it says the answer:
        // a point from the prompter did, and the date Stand had gone to check was never said.
        if !lookUps.isEmpty { return }
        if let answered = lookUpAnsweredAt, lastStandAudio < answered, t - answered < 4 { return }
        // Notes from one sender at a time: its human, its brain with an answer it promised, or the prompter.
        let batch = notesWaiting.prefix { $0.from == first.from }.count
        let note = notesWaiting.prefix(batch).map(\.text).joined(separator: " / ")
        let openings = [NoteFrom.human: noteFromHuman, .brain: noteFromBrain, .prompter: noteFromPrompter]
        let opening = (openings[first.from] ?? noteFromHuman).replacingOccurrences(of: "{note}", with: note)
        let left = standSegments.isEmpty ? 0 : playUntil - t

        if left > 0.5 {
            // In a discussion what Stand says is a sentence or two, and nothing tells it to
            // carry on afterwards. So it is not stopped for a note: the note waits until it
            // has finished.
            if settings.attending { return }
            // Stand is talking. Let it reach the pause at the end of the sentence; failing
            // that, any pause; and after that, stop it where it is.
            let late = waited >= settings.noteLandsWithin
            let pause = inPause(at: t, ahead: late ? 0.1 : 0.3)
            guard pause || waited >= settings.noteLandsWithin + 3 else { return }
            notesWaiting.removeFirst(batch)
            var tail = pause ? heardUpToMark(near: t, longPause: !late) : nil
            var lost = 1
            if tail == nil { (tail, lost) = forgetUnheard(at: t) }
            cutSpeech(at: t)
            onFlush?()
            if let at = floorOpenAt, t < at {
                floorOpenAt = nil
                floorCancelled = true
                record("floor_not_open_after_all")
            }
            cutOff = true // until Stand speaks again
            stoppedForNote = true
            if sectionGiven >= 0, !floorIsOpen {
                sectionCutShort = true
                unheardAtCut = max(0, left)
            }
            noteLandedAt = t
            let message: String
            if let tail, lost > 0 {
                // After a whole sentence Stand starts a new one; anywhere else it picks up mid-sentence.
                let atSentenceEnd = pause && (tail.last.map { ".?!\"'”’)".contains($0) } ?? false)
                message = (atSentenceEnd ? noteMidSpeechText : noteMidSentenceText).replacingOccurrences(of: "{heard}", with: tail)
            } else {
                message = noteMidSpeechUnknownText
            }
            record("note_landed", detail: String(format: "%@, %.1f s after it was passed, with %.1f s of speech still to come%@",
                                                 !pause ? "mid-sentence" : late ? "in a short pause" : "in a long pause", waited, left,
                                                 tail.map { "; heard up to: \($0)" } ?? ""))
            live?.nudge(message.replacingOccurrences(of: "{opening}", with: opening))
            held = Held(since: t)
            return
        }
        if left > 0 { return } // the last half second of what Stand is saying: let it finish

        // In a discussion the people speaking are mostly not speaking to Stand. A note
        // handed to it under their words was taken in and then not acted on: an answer
        // from its human went unsaid twice in three runs. So the note waits for them to pause.
        if settings.attending, t - lastRoomVoice < 0.6 { return }
        // The room has gone quiet, but its last utterance is still open, waiting out the
        // pause. It is ended now, and Stand takes its turn on what was said before it is
        // handed the note. Handed both at once, it answered the first with silence, and
        // the note went with it.
        if settings.marksActivity, marker.isOpen {
            endOpenUtterance(at: t)
            notesHeldUntil = t + 1.5
            return
        }
        if let until = notesHeldUntil {
            if t < until { return }
            notesHeldUntil = nil
        }
        notesWaiting.removeFirst(batch)
        if t - lastRoomVoice < 0.6 {
            // Someone is speaking to Stand. It gets the note now, so that it can use it in
            // its answer, and anything it starts to say before they finish is not played.
            record("note_landed", detail: String(format: "while someone was speaking, %.1f s after it was passed", waited))
            live?.inform(noteWhileListeningText.replacingOccurrences(of: "{opening}", with: opening))
            held = Held(since: t, whileListening: true)
        } else {
            record("note_landed", detail: String(format: "while Stand was silent, %.1f s after it was passed", waited))
            // A note from its human is acted on. A point from the prompter is Stand's to make or to let go.
            live?.nudge((first.from == .prompter ? cueText : noteText).replacingOccurrences(of: "{opening}", with: opening))
            held = Held(since: t)
            noteHandedAt = t
        }
    }

    /// Keeps the prompter going: gives it what has been said since its last sheet, passes
    /// the new sheet to Stand in a quiet moment, and, in a discussion, hands Stand any
    /// point it thinks worth making, the way a note is handed. In a talk the sheet is
    /// Stand's memory of everything older than the few minutes the voice model keeps:
    /// where the talk stands, what was asked and answered, what it owes. The transcript
    /// is used for this and nothing else: what Stand hears and says still goes from
    /// sound to sound.
    private func keepPrompter(at t: Double) {
        guard settings.hasPrompter, let prompter else { return }
        let attending = settings.attending
        // A sheet that has been written is passed on when nobody is speaking. It asks for no
        // reply, so it costs no turn of the model.
        // In a talk, never in the moment after someone in the audience has spoken: Stand
        // is about to answer them, and a message slipped in then takes that turn. One
        // sent as a question ended left the question unanswered for 26 seconds. So there
        // it goes when Stand's own speech has run out, just ahead of "carry on", or when
        // the room has been quiet for a while.
        let afterItsOwnSpeech = !standSegments.isEmpty && !cutOff && lastRoomVoice < playUntil + 0.3
        let clear = attending || afterItsOwnSpeech || t - lastRoomVoice > 6
        if let waiting = sheetToTell, clear, !roomSpeaking, !standSpeaking, held == nil, t - sheetToldAt >= settings.sheetAtMostEvery {
            sheetToTell = nil
            let text = waiting.forStand
            if !text.isEmpty {
                live?.inform(sheetMessage.replacingOccurrences(of: "{sheet}", with: text))
                sheetTold = waiting
                sheetToldAt = t
                record("sheet", detail: text)
                onUpdate?(.prompted(sheet: text, cue: nil))
            }
        }
        if prompterInFlight {
            // It answers in about two seconds. One that has not after twenty is given up on.
            if t - prompterAskedAt > 20 {
                prompter.giveUp()
                prompterInFlight = false
            }
            return
        }
        // Not just after Stand has spoken: its words reach the transcript a moment late, and a
        // prompter that has not seen them hands Stand the point it has just made.
        let sinceAsked = t - prompterAskedAt
        // In a talk Stand is speaking most of the time, so the prompter is asked while it speaks.
        guard attending ? sinceAsked >= 2 && !standSpeaking && t - lastStandAudio > 2.5 : sinceAsked >= settings.prompterEvery else { return }
        // What has been said since it was last asked, leaving out a line that is still being added to.
        var said = [String]()
        var characters = 0
        var upTo = (line: seenLines, characters: seenCharacters)
        var heardTo = heardGiven
        if attending {
            for i in seenLines..<transcript.count {
                let line = transcript[i]
                guard line.updated < t - 1.2 else { break }
                let fresh = Self.oneLine(i == seenLines ? String(line.text.dropFirst(seenCharacters)) : line.text)
                upTo = (i, line.text.count)
                guard !fresh.isEmpty else { continue }
                said.append("\(line.who == .stand ? "Stand" : "In the meeting"): \(fresh)")
                characters += fresh.count
            }
        } else {
            // In a talk the model's transcript of itself runs far ahead of the sound, and
            // what is cut off is never heard. So Stand's side is taken from the pieces
            // that have been played, each at the moment its sound began, and the
            // audience's side from the transcript.
            var parts = [(at: Double, stand: Bool, text: String)]()
            for i in seenLines..<transcript.count {
                let line = transcript[i]
                if line.who == .stand { upTo = (i, line.text.count); continue }
                guard line.updated < t - 1.2 else { break }
                let fresh = Self.oneLine(i == seenLines ? String(line.text.dropFirst(seenCharacters)) : line.text)
                upTo = (i, line.text.count)
                if !fresh.isEmpty { parts.append((line.t, false, fresh)) }
            }
            for piece in spokenPieces where piece.startsAt > heardGiven && piece.startsAt <= t - 0.5 {
                parts.append((piece.startsAt, true, piece.text))
                heardTo = piece.startsAt
            }
            for part in parts.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
                let who = part.stand ? "Stand" : "In the meeting"
                if part.stand, let last = said.last, last.hasPrefix("Stand: ") {
                    said[said.count - 1] = last + part.text
                } else {
                    said.append("\(who): \(part.stand ? part.text.trimmingCharacters(in: .whitespaces) : part.text)")
                }
                characters += part.text.count
            }
            said = said.map { Self.oneLine($0) }
        }
        // Enough has been said, and nobody is in the middle of saying more (unless they have
        // been at it for a long time).
        // Quiet since the last voice was heard. For Stand's own that is when its speech ran
        // out, not when the sound arrived from the service, which is seconds earlier.
        let heardUntil = max(lastRoomVoice, min(t, playUntil))
        let quietFor = min(600, t - heardUntil)
        // In a talk about twenty seconds of speech at a time is enough to keep its place.
        let enough = attending
            ? sinceAsked >= settings.prompterEvery && characters >= settings.prompterAfterCharacters && (!roomSpeaking || sinceAsked >= 25)
            : characters >= settings.prompterAfterCharactersInTalk && !roomSpeaking
        // Or the room has fallen quiet. Once in each silence the prompter is asked what the
        // quiet means, whether or not anything new has been said since it last looked: a
        // question may be hanging that Stand did not take for its own, or one put to the
        // whole room that nobody has answered. When the last voice was Stand's, only if it
        // has not seen the words yet.
        let roomSpokeLast = lastRoomVoice > min(t, playUntil)
        let lull = quietFor >= settings.prompterAtLull && lullAskedAt < heardUntil && (characters >= 20 || (attending && roomSpokeLast && !transcript.isEmpty))
        guard enough || lull,
              let ask = try? PrompterSheet.request(root: root, brief: settings.brief, last: sheet, passed: cuesPassed,
                                                   said: said.joined(separator: "\n"), quietFor: quietFor) else { return }
        prompterInFlight = true
        prompterAskedAt = t
        let inQuiet = quietFor >= settings.prompterAtLull
        if inQuiet { lullAskedAt = t }
        let queue = self.queue
        Task { [weak self] in
            let answer = try? await prompter.answer(ask)
            queue.async {
                guard let self, !self.isClosed else { return }
                self.prompterInFlight = false
                // A reply that is not a sheet leaves everything as it was, and the same lines are given again next time.
                guard let answer, let new = PrompterSheet(reply: answer) else { return }
                self.seenLines = upTo.line
                self.seenCharacters = upTo.characters
                self.heardGiven = heardTo
                self.sheet = new
                let told = self.sheetTold
                // In a talk the thread is the news: where the talk stands is what Stand loses first.
                if told == nil || !Self.alike(new.inPlay, told?.inPlay ?? "") || !Self.alike(new.owed, told?.owed ?? "")
                    || (!attending && new.soFar != told?.soFar) || self.now - self.sheetToldAt >= self.settings.sheetEvery {
                    self.sheetToTell = new
                }
                // A talk has its plan: the prompter keeps Stand's memory there and does not prompt it to speak.
                guard attending else { return }
                // A point worth making is passed once, the way a note is: at a pause, and never over someone.
                // The prompter is a few seconds behind. If Stand has spoken or gone to look
                // something up since it was asked, Stand may just have made this very point,
                // so it is left for the next sheet, which will have Stand's words in it.
                let cue = new.worthSaying
                if !cue.isEmpty, self.lastStandAudio > self.prompterAskedAt || !self.lookUps.isEmpty {
                    self.record("cue_held_back", detail: cue)
                } else if !cue.isEmpty, inQuiet, self.lastRoomVoice > t {
                    // It was asked what a silence meant, and the silence is over: someone
                    // has spoken in the two seconds it took to answer. If a question was
                    // hanging, the person it was put to is answering it. The point is not
                    // counted as passed, so the prompter may raise it again if it still holds.
                    self.record("cue_overtaken", detail: cue)
                } else if !cue.isEmpty, !self.cuesPassed.contains(where: { Self.alike($0, cue) }) {
                    self.cuesPassed.append(cue)
                    if inQuiet { self.quietCues.insert(cue) }
                    self.record("cue", detail: cue)
                    self.onUpdate?(.prompted(sheet: new.forStand, cue: cue))
                    self.notesWaiting.append((cue, self.now, .prompter))
                    self.landNotes()
                }
            }
        }
    }

    /// Whether two short texts say much the same thing: most of their longer words are shared.
    /// The prompter rewords what has not changed, and that is not news.
    private static func alike(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 || $0.allSatisfy(\.isNumber) }.map(String.init))
        }
        let (x, y) = (words(a), words(b))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    private func addTranscript(_ who: Speaker, _ text: String) {
        guard !text.isEmpty else { return }
        let t = now
        // The model's pieces carry their own spaces, except where one remark ends and the next begins.
        var text = text
        if who == .stand, let line = transcript.last, line.who == .stand, let last = line.text.last, ".?!".contains(last),
           let first = text.first, !first.isWhitespace {
            text = " " + text
        }
        if who == .stand {
            if ProcessInfo.processInfo.environment["STAND_DEBUG_PIECES"] != nil {
                record("piece", at: max(t, playUntil), detail: text)
            }
            spokenPieces.append((startsAt: max(t, playUntil), text: text))
            piecesThisTurn += 1
            if spokenPieces.count > 400 { spokenPieces.removeFirst(spokenPieces.count - 400) }
            if sectionGiven >= 0, !floorIsOpen { sectionPieces.append((startsAt: max(t, playUntil), text: text)) }
        }
        if let last = transcript.last, last.who == who, t - last.updated < 2.5 {
            transcript[transcript.count - 1].text += text
            transcript[transcript.count - 1].updated = t
        } else {
            transcript.append(Line(who: who, t: t, updated: t, text: text))
        }
        onUpdate?(.transcript(who, text))
    }

    // MARK: The stage manager

    private var floorIsOpen: Bool {
        guard let at = floorOpenAt else { return false }
        return now >= at
    }

    private func spoken() -> Double {
        let t = now
        return standSegments.reduce(0) { $0 + max(0, min(PCM.seconds($1.pcm, rate: GeminiLive.speechRate), t - $1.start)) }
    }

    private func tick() {
        guard isOpen, !isClosed else { return }
        let t = now
        let speaking = !standSegments.isEmpty && t < playUntil + 0.15
        if speaking != standSpeaking {
            standSpeaking = speaking
            // `at` is when the speech actually ran out, a little before this tick noticed.
            if speaking { record("stand_start") } else { record("stand_stop", at: playUntil) }
            sendState()
        }
        if roomSpeaking, t - lastRoomVoice > 0.6 {
            roomSpeaking = false
            record("room_stop")
            sendState()
        }
        landNotes()
        keepPrompter(at: t)
        if let reply = held, reply.whileListening, t - lastRoomVoice > 0.4 || t - reply.since > 20 {
            if reply.audio.isEmpty, t - lastRoomVoice > 3 { held = nil } else if !reply.audio.isEmpty { releaseHeld() }
        }

        // While the brain is looking something up, the silence is Stand waiting for the
        // answer, not stalling, so hold "carry on" for a few seconds. If the brain takes
        // longer, the talk carries on and the answer follows when Stand next pauses.
        if lookUps.values.contains(where: { !$0.told && t - $0.asked < settings.lookUpHold }) { return }
        // Then give Stand a moment to start saying the answer it was just handed.
        if let answered = lookUpAnsweredAt {
            if lastStandAudio > answered || t - answered > 4 { lookUpAnsweredAt = nil } else { return }
        }

        // A note has just reached Stand. Give it a moment to act on it before anything else is said to it.
        if let handed = noteHandedAt {
            if lastStandAudio > handed || t - handed > 2 { noteHandedAt = nil } else { return }
        }

        // In a discussion nobody is waiting for Stand to go on: silence is the usual state.
        guard !settings.attending else { return }

        // Stand was sent back to the section it had been stopped in, and said nothing: there
        // was nothing left of it to say. The talk goes on with the next one. Left there, it
        // sat silent for twelve seconds after an "mm-hm" in the last second of a section.
        if let sent = resumeSentAt {
            if lastStandAudio > sent || lastRoomVoice > sent || floorIsOpen {
                resumeSentAt = nil
            } else if t - sent > settings.resumeDrawsNothingAfter {
                resumeSentAt = nil
                nothingLeftOfSection = true
                nudged = false
                carryOnNow = true
            }
        }

        // Once per silence, tell Stand to carry on. A voice model speaks one turn and then
        // waits, so this is what keeps a talk moving.
        guard let beganAt, !nudged else { return }
        let quietSince = max(playUntil, lastRoomVoice, beganAt)
        // The margin keeps Stand's own echo in the microphone from counting as the room speaking last.
        let standSpokeLast = !standSegments.isEmpty && !cutOff && lastRoomVoice < playUntil + 0.3
        let turnDone = turnCompleteAt.map { $0 >= lastStandAudio } ?? false
        let wait = cutOff && stoppedForNote ? settings.carryOnAfterNote // a note stopped it mid-talk: it should simply go on
            : cutOff ? settings.carryOnAfterCut // someone cut Stand off: it usually answers or resumes by itself
            : !standSpokeLast ? settings.carryOnAfterRoom // the room spoke last: give Stand time to answer
            : turnDone ? settings.carryOnAfterTurn
            : settings.carryOnAfterSpeech
        guard carryOnNow || t - quietSince > wait else { return }
        carryOnNow = false
        nudged = true

        // Stand is waiting on purpose, not stalled, if it has said so, or if the last
        // "carry on" drew only a line or nothing. Leave it alone until the room speaks:
        // each nudge would push it to fill the silence, then to say goodbye.
        // With sections still to hand over, a short reply was a short section, not a sign that Stand is waiting.
        let sectionsLeft = !sections.isEmpty && !floorCancelled && sectionGiven + 1 < sections.count
        let shortReply = !sectionsLeft && (lastCarryOn.map { lastRoomVoice < $0.t && spoken() - $0.spoken < settings.shortReply } ?? false)
        if floorIsOpen || (standSpokeLast && shortReply) {
            record("left_waiting", detail: floorIsOpen ? "Stand opened the floor" : "its last reply was short")
            // Stand had already said once that the talk was over. A short reply now means
            // it is waiting again, so stop prompting it for the rest of the session.
            if !floorIsOpen, floorCancelled {
                floorOpenAt = t
                floorCancelled = false
                record("floor_open", at: t, detail: "taken from its short reply")
                sendState()
            }
            return
        }
        if standSpokeLast { lastCarryOn = (t, spoken()) }
        carryOns += 1
        // After an ending that was cut off, the message also asks Stand to open the floor again.
        // In a talk with sections, the message says which section comes now.
        let why = cutOff ? "cut" : standSpokeLast ? "stand" : "room"
        if !floorCancelled, let next = nextInTalk(afterItsOwnTurn: standSpokeLast) {
            live?.nudge(next.message)
            record("nudge", detail: "\(why): \(next.what)")
        } else {
            live?.nudge(floorCancelled ? finishText : carryOnText)
            record("nudge", detail: why)
        }
        onUpdate?(.carryOn)
    }

    /// What keeps a talk with numbered sections moving: the section that comes now, with
    /// its points. Nil for a talk without sections, which gets a plain "carry on".
    private func nextInTalk(afterItsOwnTurn: Bool) -> (message: String, what: String)? {
        guard !sections.isEmpty, sectionGiven >= 0 else { return nil }
        let was = sections[sectionGiven]
        // Stand was stopped while giving the section, or was spoken to and has said nothing since.
        let stopped = (sectionCutShort || !afterItsOwnTurn) && !nothingLeftOfSection
        sectionCutShort = false
        nothingLeftOfSection = false
        let left = stopped ? leftUnsaid(of: was, silentSince: !afterItsOwnTurn).joined(separator: "\n") : ""
        if !stopped {
            // It gave this section unstopped: how closely does it keep to the plan's words?
            let made = pointsMade(of: was)
            pointsMatched += made.filter { $0 }.count
            pointsGiven += made.count
        }
        let back = (fill(sectionResumeText, with: was, points: left), "back to section \(was.number)")
        if !afterItsOwnTurn, !left.isEmpty {
            resumeSentAt = now
            return back
        }
        guard sectionGiven + 1 < sections.count else {
            return left.isEmpty ? (sectionsDoneText, "every section has been given") : back
        }
        sectionGiven += 1
        sectionGivenAt = now
        sectionPieces.removeAll()
        unheardAtCut = 0 // nothing has been lost of the section that starts now
        let next = sections[sectionGiven]
        var message = fill(left.isEmpty ? sectionText : sectionAfterCutText, with: next)
            .replacingOccurrences(of: "{was}", with: was.number)
            .replacingOccurrences(of: "{wasTitle}", with: was.title)
            .replacingOccurrences(of: "{wasPoints}", with: left)
        if sectionGiven == sections.count - 1 { message += "\n\n" + sectionLastText }
        let points = left.split(separator: "\n").count
        return (message, "section \(next.number) of \(sections.count)\(left.isEmpty ? "" : ", after \(points) \(points == 1 ? "point" : "points") left of \(was.number)")")
    }

    private func fill(_ text: String, with section: TalkPlan.Section, points: String? = nil) -> String {
        text.replacingOccurrences(of: "{number}", with: section.number)
            .replacingOccurrences(of: "{title}", with: section.title)
            .replacingOccurrences(of: "{time}", with: section.time.map { " (\($0))" } ?? "")
            .replacingOccurrences(of: "{points}", with: points ?? section.points)
    }

    /// What is left of a section Stand was stopped in, for the audience to hear, going by
    /// its own words since the section was handed over: the points after the last one it
    /// plainly made. Only those: it shortens points as it goes, and told that the audience
    /// "had not heard" one of them, it said the whole of it again.
    /// - If it has said nothing since it was stopped, that is what is left, and all of the
    ///   section when none of its points can be found in what it said. Unless it was
    ///   stopped in its last second: then nothing was lost.
    /// - If it has spoken since, it answered, and as a rule went on with the section. One
    ///   point that cannot be found is then most often a point it put in its own words
    ///   (given back, it was said a second time in 3 cases of 4). Two or more were not said.
    private func leftUnsaid(of section: TalkPlan.Section, silentSince: Bool) -> [String] {
        let points = section.points.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("-") }
        let tail = pointsMade(of: section).lastIndex(of: true).map { Array(points[($0 + 1)...]) }
        if silentSince { return unheardAtCut < 1.0 ? [] : tail ?? points }
        return (tail?.count ?? 0) >= 2 ? tail ?? [] : []
    }

    /// For each point of a section, whether it can be found in what Stand has said since
    /// the section was handed over: half of the point's longer words.
    private func pointsMade(of section: TalkPlan.Section) -> [Bool] {
        func words(_ text: String) -> Set<String> {
            // Longer words only, without their endings and cut to five letters, so that
            // "joins" and "join", "speaking" and "speaks", "changes" and "changing" are one.
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 4 }.map { word -> String in
                var word = Substring(word)
                if word.count > 6, word.hasSuffix("ing") { word = word.dropLast(3) } else if word.count > 5, word.hasSuffix("ed") { word = word.dropLast(2) }
                else if word.count > 4, word.hasSuffix("s") { word = word.dropLast(1) }
                return String(word.prefix(5))
            })
        }
        let points = section.points.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("-") }
        let said = words(sectionPieces.map(\.text).joined(separator: " "))
        return points.map { point in
            let wanted = words(point)
            return wanted.count >= 4 && Double(wanted.intersection(said).count) >= Double(wanted.count) * 0.5
        }
    }

    private func sendState() {
        onUpdate?(.state(standSpeaking: standSpeaking, roomSpeaking: roomSpeaking, floorOpen: floorIsOpen))
    }

    // MARK: Ending and writing the run

    private func finish(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        live?.close()
        for (_, done) in asks { done.resume(returning: false) }
        asks = [:]
        brain?.stop()
        prompter?.stop()
        var written: URL?
        if isOpen {
            record("closed", detail: reason)
            do {
                try writeRun(reason: reason)
                written = folder
            } catch {
                onUpdate?(.error("Could not save the run: \(error)"))
            }
            try? eventsFile?.close()
        }
        onUpdate?(.closed(reason: reason, folder: written))
    }

    private func record(_ type: String, at: Double? = nil, detail: String? = nil) {
        let event = Event(t: now, type: type, at: at, detail: detail)
        events.append(event)
        var json: [String: Any] = ["t": Int((event.t * 1000).rounded()), "type": type]
        if let at { json["at"] = Int((at * 1000).rounded()) }
        if let detail { json["detail"] = detail }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            eventsFile?.write(data + Data("\n".utf8))
        }
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func writeRun(reason: String) throws {
        let end = now
        let speechRate = GeminiLive.speechRate
        let speech = standSegments.reduce(0) { $0 + PCM.seconds($1.pcm, rate: speechRate) }
        let lastSpeechEnd = standSegments.reduce(0) { max($0, $1.start + PCM.seconds($1.pcm, rate: speechRate)) }

        // stand.wav puts Stand's speech on the session timeline; recording.wav adds the room.
        var timeline = [Int16](repeating: 0, count: Int((max(end, lastSpeechEnd) * speechRate).rounded()))
        for segment in standSegments {
            PCM.mix(PCM.samples(segment.pcm), into: &timeline, at: Int((segment.start * speechRate).rounded()))
        }
        try PCM.writeWav(PCM.data(timeline), rate: speechRate, to: folder.appendingPathComponent("stand.wav"))
        if !roomChunks.isEmpty {
            let room = roomChunks.reduce(into: Data()) { $0.append($1) }
            try PCM.writeWav(room, rate: GeminiLive.microphoneRate, to: folder.appendingPathComponent("room.wav"))
            let resampled = PCM.resample(PCM.samples(room), from: GeminiLive.microphoneRate, to: speechRate)
            PCM.mix(resampled, into: &timeline, at: Int(((roomStart ?? 0) * speechRate).rounded()))
            try PCM.writeWav(PCM.data(timeline), rate: speechRate, to: folder.appendingPathComponent("recording.wav"))
        }

        let markers = [
            "begin": "the talk was started",
            "joined": "Stand joined the discussion",
            "interrupted": "Stand stopped mid-speech",
            "nudge": "the stage manager told Stand to carry on",
            "floor_too_early": "Stand signalled the end with sections still to give, which was not taken",
            "passed_over": "a short sound did not stop Stand",
            "floor_open": "Stand signalled that the talk is over and the floor is open",
            "hush": "its human told Stand to stop talking",
            "cut_off_note": "the stage manager told Stand where it was cut off",
            "told": "its human passed Stand a private note",
            "note_landed": "the note reached Stand",
            "swallowed": "a stray word from Stand was not played",
            "kept_quiet": "Stand chose to say nothing",
            "sheet": "Stand's brain passed it the sheet",
            "cue": "its brain thought this worth saying",
            "cue_dropped": "a point from its brain was let go",
            "cue_held_back": "a point from its brain was held back, because Stand had spoken in the meantime",
            "cue_overtaken": "a point from its brain about a silence was let go, because someone else had spoken by then",
            "memory": "how much it remembers",
            "lookup_slow": "Stand was told the answer is taking a moment",
            "brain": "the brain is",
            "ask": "the brain asked Stand's human for a yes to",
            "ask_answer": "the answer was",
            "human_asked": "Stand asked its human",
            "human_answer": "its human answered",
            "lookup": "Stand asked its brain",
            "lookup_answer": "the brain answered",
        ]
        // Markers first, so a marker comes before a line at the same instant (the sort is stable).
        var entries = events.compactMap { e in
            markers[e.type].map { (t: e.t, text: "_(\($0)\(e.type.hasPrefix("lookup") || ["cut_off_note", "told", "note_landed", "swallowed", "brain", "ask", "ask_answer", "sheet", "cue", "cue_dropped", "cue_held_back", "cue_overtaken", "memory", "human_asked", "human_answer", "nudge", "floor_too_early", "passed_over"].contains(e.type) ? ": " + (e.detail ?? "") : ""))_") }
        }
        entries += transcript.map { (t: $0.t, text: "**\($0.who == .stand ? "Stand" : "Room"):** \($0.text.trimmingCharacters(in: .whitespaces))") }
        let ordered = entries.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        let body = ordered.map { "- \(Self.clock($0.t)) \($0.text)" }.joined(separator: "\n")
        try "# Transcript\n\n\(body)\n".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        // Every turn of the model is billed for its whole context: see `Spend`. The service
        // says what it counted, one message for each turn it completed; without those, the
        // session's own events are counted up.
        let (rebuilt, rebuiltTurns) = Spend.rebuilt(events: events, instructionsCharacters: instructionsCharacters)
        let counted = reported.messages > 0
        let cost = counted ? reported.dollars : rebuilt, turns = counted ? reported.messages : rebuiltTurns
        summary = [
            "provider": "gemini",
            "model": model,
            "voice": voice,
            "talk": settings.talk,
            "mode": settings.attending ? "discussion" : "talk",
            "speechMarkedBy": settings.marksActivity ? "this program" : "the voice service",
            "startedAt": ISO8601DateFormatter().string(from: t0),
            "endedBecause": reason,
            "durationSeconds": Int(end.rounded()),
            "standSpeechSeconds": Int(speech.rounded()),
            "interruptions": interruptions,
            "nudges": carryOns,
            "sections": sections.count,
            "sectionsGiven": sectionGiven + 1,
            "pointsGiven": pointsGiven,
            "pointsMatched": pointsMatched,
            "briefed": !settings.brief.isEmpty,
            "notesPassed": notesPassed,
            "estimatedCostUsd": (cost * 10000).rounded() / 10000,
            "costBasis": (counted ? "the service's own count of tokens" : "rebuilt from this session's events")
                + ", at the prices of 2026-11-12: each of the model's \(turns) turns is billed for the instructions and all the speech so far",
            "rebuiltCostUsd": (rebuilt * 10000).rounded() / 10000,
            "costModel": 2,
            "turns": turns,
        ]
        if reported.messages > 0 { summary["reportedByTheService"] = reported.json }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("summary.json"))
    }
}

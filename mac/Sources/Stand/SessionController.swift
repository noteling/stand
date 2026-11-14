import AppKit
import StandCore

/// What the window shows and what its buttons do. It owns one session at a time, wired
/// to the real microphone, the system audio tap and the speakers.
@MainActor
final class SessionController: ObservableObject {
    enum Phase { case idle, connecting, running, stopping }

    /// One place Stand's notes come from, as the panel lists it.
    struct SourceRow: Identifiable {
        let id: String
        let name: String
        let place: String
        var detail: String
        var problem: String?
        /// Its position in brain.json's "sources". Nil for the project's own folder, which stays.
        let index: Int?
    }

    /// Something Stand wants to know from its human, to pass on to the meeting.
    struct Question: Identifiable {
        let id: String
        let text: String
    }

    /// Something Stand's brain wants a yes for before it does it.
    struct Ask: Identifiable {
        let id: String
        let what: String
        let until: Date
    }

    @Published var phase = Phase.idle
    @Published var standSpeaking = false
    @Published var roomSpeaking = false
    @Published var floorOpen = false
    @Published var lookingUp = false
    /// What the brain is doing just now, when it is doing more than reading the notes.
    @Published var brainBusy: String?
    /// The brain's open question to its human, if there is one.
    @Published var ask: Ask?
    @Published var elapsed = 0
    @Published var standText = ""
    @Published var roomText = ""
    @Published var message: String?
    @Published var lastRun: URL?
    @Published var lastRunSummary: String?
    @Published var talks = [String]()
    /// The talk Stand will give, as a path. Empty when it gives none and joins the discussion.
    @Published var talk = "talks/introducing-stand.md" { didSet { if talk != oldValue, isLive { UserDefaults.standard.set(talk, forKey: "StandTalk") } } }
    var attending: Bool { talk.isEmpty }
    /// The voices Stand can speak with, and the one chosen, by name. The choice is kept on this Mac.
    @Published var voices = [Voice]()
    @Published var voice = Voices.usual {
        didSet {
            guard voice != oldValue else { return }
            samplePlayer.stop() // the sample of the voice just left is not heard on under the new name
            hearing = nil
            playWhenFetched = nil
            if isLive { UserDefaults.standard.set(voice, forKey: "StandVoice") }
        }
    }
    /// The voice whose sample has been asked for and has not made a sound yet.
    @Published var hearing: String?

    /// What the human wrote about the next meeting. Kept in brief.md.
    @Published var brief = "" { didSet { if brief != oldValue { briefChanged() } } }
    /// "14 files from 2 places", or what is wrong.
    @Published var notesLine = "Looking for notes…"
    @Published var sources = [SourceRow]()
    @Published var showingSources = false
    @Published var checkingSources = false
    @Published var sourcesMessage: String?
    /// While the brain is writing a talk for the meeting described in the brief: what it is doing just now.
    @Published var preparing: String?
    /// The talk the brain last wrote here, said in a line, until another talk is chosen.
    @Published var preparedLine: String?
    /// What the prompter last put in front of Stand, and the last point it thought worth saying.
    @Published var sheet: String?
    @Published var cue: String?
    /// What Stand has asked its human and is waiting on, oldest first, and the answer being typed.
    @Published var questions = [Question]()
    @Published var reply = ""
    /// The note being typed to Stand during a meeting, and the ones already passed.
    @Published var note = ""
    @Published var passed = [String]()
    /// True until this Mac has a key for the voice model. The panel then asks for one, once.
    @Published var needsKey = false
    /// What stands in the way of looking things up on this Mac, if anything does.
    @Published var brainNotice: String?
    /// What the sessions kept here add up to, by their own estimates. The voice service is
    /// paid from a balance Stand cannot see, and this is the only number to watch it by.
    @Published var spendLine: String?
    /// Which build this is, on a packaged app: shown small, so that a report from another Mac can say.
    let build = Bundle.main.object(forInfoDictionaryKey: "StandBuild") as? String

    /// Counts up each time the note field should take the keyboard.
    @Published var noteFocusRequests = 0
    /// Called when a note has been passed or given up, so the keyboard can go back where it was.
    var onNoteDone: (() -> Void)?

    private var session: StandSession?
    private var audio: AudioIO?
    /// The samples already fetched, so that hearing a voice a second time costs nothing; the
    /// ones on their way; and what plays them.
    private var samples = [String: Data]()
    private var fetching = Set<String>()
    /// A voice asked for again while its sample was still on its way and no longer playing: it is played once it is all here.
    private var playWhenFetched: String?
    private let samplePlayer: SpeechPlayer
    /// How much of the sample now playing has come out of the speakers, in seconds. For the check that presses "Hear it" with nobody there.
    var samplePlayed: Double { samplePlayer.played }
    private var clock: Timer?
    private var linkedCheck: Timer?
    private var briefSave: DispatchWorkItem?
    private var startedAt = Date()
    private let root: URL?
    /// False for a controller that only draws a picture of the panel. It must never write
    /// to disk: its brief is made up.
    private let isLive: Bool

    var status: String {
        switch phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .stopping: return "Saving the run…"
        case .running:
            if standSpeaking { return "Stand is speaking" }
            if lookingUp { return brainBusy.map { "Checking: \($0)" } ?? "Checking its notes" }
            if roomSpeaking { return "Hearing someone" }
            return floorOpen ? "Waiting for questions" : attending ? "In the meeting, listening" : "Listening"
        }
    }

    /// `live` is false for a controller that only draws a picture of the panel: it reads
    /// nothing from the network and starts no timers. `sampleVolume` is how loud a sample
    /// of a voice is played; zero is for checking "Hear it" without a sound.
    init(live: Bool = true, sampleVolume: Float = 1) {
        isLive = live
        samplePlayer = SpeechPlayer(volume: sampleVolume)
        root = try? Project.root()
        guard let root else {
            message = "Stand's text files were not found. Rebuild the app from the repo with mac/scripts/build.sh."
            notesLine = "No notes"
            return
        }
        talks = Project.talks(root: root)
        // What was chosen last time, a talk or none, is chosen again.
        if live, let last = UserDefaults.standard.string(forKey: "StandTalk"), last.isEmpty || talks.contains(last) { talk = last }
        if !talk.isEmpty, !talks.contains(talk) { talk = talks.first ?? "" }
        voices = Voices.all(root: root)
        if live, let last = UserDefaults.standard.string(forKey: "StandVoice"), voices.contains(where: { $0.name == last }) { voice = last }
        brief = Project.brief(root: root)
        guard live else { return }
        needsKey = (try? Project.geminiKey(root: root)) == nil
        lookForBrain(root: root)
        addUpSpend()
        refreshSources(check: true)
        // Linked repositories are checked every ten minutes, in a meeting or out of one.
        linkedCheck = Timer.scheduledTimer(withTimeInterval: LinkedRepos.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSources(check: true) }
        }
    }

    /// Looking for the brain can mean asking a shell where it is, which takes a moment: not on the main thread.
    private func lookForBrain(root: URL) {
        Task.detached(priority: .utility) {
            let notice = BrainFactory.missing(root: root)
            await MainActor.run { [weak self] in self?.brainNotice = notice }
        }
    }

    /// Adds up what the sessions kept here cost, off the main thread: there can be hundreds.
    private func addUpSpend() {
        guard isLive, let root else { return }
        Task.detached(priority: .utility) {
            let line = Spend.total(root: root).line
            await MainActor.run { [weak self] in self?.spendLine = line }
        }
    }

    // MARK: The meeting

    func start() {
        guard phase == .idle else { return }
        phase = .connecting
        message = nil
        standText = ""
        roomText = ""
        floorOpen = false
        passed = []
        note = ""
        samplePlayer.stop() // a sample of a voice must not play on into the meeting
        hearing = nil
        playWhenFetched = nil
        saveBriefNow()
        Task {
            do {
                let root = try Project.root()
                guard await AudioIO.microphoneAllowed() else {
                    throw StandError("Stand needs the microphone. Allow it in System Settings > Privacy & Security > Microphone, then start again.")
                }
                var settings = StandSession.Settings()
                settings.talk = talk
                settings.brief = brief
                settings.voice = voice
                settings.echoSettle = 1.0 // the echo canceller leaks Stand's first second
                let session = StandSession(root: root, label: "app", settings: settings)
                let audio = AudioIO()
                session.onSpeech = { [weak audio] pcm in audio?.play(pcm) }
                session.onFlush = { [weak audio] in audio?.flush() }
                session.onUpdate = { [weak self] update in
                    Task { @MainActor in self?.apply(update) }
                }
                try await session.open()
                audio.onHeard = { [weak session] pcm in session?.hear(pcm) }
                do {
                    try audio.start()
                } catch {
                    session.close(reason: "the audio could not start")
                    throw error
                }
                self.session = session
                self.audio = audio
                phase = .running
                startedAt = Date()
                elapsed = 0
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.elapsed = Int(Date().timeIntervalSince(self.startedAt))
                    }
                }
                session.begin()
                refreshSources(check: false) // the session has just checked the linked repositories itself
            } catch {
                message = "\(error)"
                // A key the service will not take is asked for again, the way a missing one is.
                if message == GeminiLive.keyRefused { needsKey = true }
                phase = .idle
            }
        }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        session?.close(reason: "stopped from the app")
    }

    /// The override: Stand stops talking at once and waits to be spoken to.
    func hush() {
        guard phase == .running else { return }
        session?.hush()
    }

    /// Passes Stand what is in the note field. Only Stand gets it; nothing is said of the note itself.
    func tell() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .running, !text.isEmpty else { return }
        session?.tell(text)
        note = ""
        onNoteDone?()
    }

    /// Escape in the note field: nothing is passed.
    func dropNote() {
        note = ""
        onNoteDone?()
    }

    /// Keeps the key for the voice model, in .env in Stand's folder on this Mac.
    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !key.isEmpty else { return }
        do {
            try Project.save(setting: "GEMINI_API_KEY", value: key, root: root)
            needsKey = false
            message = nil
        } catch {
            message = "The key could not be saved: \(error.localizedDescription)"
        }
    }

    /// The human's answer to what the brain asked to do.
    func answerAsk(_ allow: Bool) {
        guard let ask else { return }
        session?.answer(ask: ask.id, allow: allow)
        self.ask = nil
    }

    /// Answers the oldest question Stand has put to its human with what is typed, or,
    /// with `nothing`, tells Stand there is no answer.
    func answerQuestion(nothing: Bool = false) {
        guard let question = questions.first else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nothing || !text.isEmpty else { return }
        session?.answer(question: question.id, with: nothing ? nil : text)
        reply = ""
        onNoteDone?()
    }

    /// Puts the keyboard in the note field, from the hotkey.
    func focusNote() {
        guard phase == .running else { return }
        noteFocusRequests += 1
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Makes the one file to send when something went wrong, and shows it in the Finder.
    func makeProblemReport() {
        guard let root else { return }
        Task.detached(priority: .utility) {
            do {
                let zip = try ProblemReport.make(root: root)
                await MainActor.run { [weak self] in self?.reveal(zip) }
            } catch {
                await MainActor.run { [weak self] in self?.message = "The report could not be made: \(error)" }
            }
        }
    }

    func openProjectFolder() {
        if let root { NSWorkspace.shared.open(root) }
    }

    // MARK: Whose voice

    /// Says a few lines in the chosen voice, so that it can be chosen by ear. The first
    /// time for each voice the lines come from the voice service, a second or so before
    /// the first word and about a quarter of a cent; after that they are kept until Stand quits.
    func hearVoice() {
        guard phase == .idle, let root else { return }
        let name = voice
        if let pcm = samples[name] {
            let stretch = samplePlayer.begin()
            samplePlayer.play(pcm, of: stretch)
            rest(stretch, after: pcm)
            return
        }
        if fetching.contains(name) {
            // On its way already. If it is no longer playing as it comes (another voice was chosen
            // in between), it is played from the start once the rest has arrived.
            if hearing != name, samplePlayer.played == 0 {
                hearing = name
                playWhenFetched = name
            }
            return
        }
        fetching.insert(name)
        hearing = name
        message = nil
        let player = samplePlayer
        let stretch = player.begin()
        Task.detached(priority: .userInitiated) {
            do {
                let pcm = try await Voices.sample(name, root: root) { piece in
                    player.play(piece, of: stretch)
                    Task { @MainActor [weak self] in
                        // The first sound ends the wait, unless this sample is now only being fetched to be played afterwards.
                        if self?.hearing == name, self?.playWhenFetched != name { self?.hearing = nil }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.samples[name] = pcm
                    self.fetching.remove(name)
                    if self.hearing == name { self.hearing = nil }
                    if self.playWhenFetched == name {
                        self.playWhenFetched = nil
                        if self.voice == name, self.phase == .idle { self.hearVoice() } // now from what is kept
                    } else {
                        self.rest(stretch, after: pcm)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.fetching.remove(name)
                    if self.hearing == name { self.hearing = nil }
                    if self.playWhenFetched == name { self.playWhenFetched = nil }
                    self.message = "\(error)"
                    if self.message == GeminiLive.keyRefused { self.needsKey = true }
                }
            }
        }
    }

    /// Lets go of the speakers once a sample has had time to play out, unless another has begun.
    private func rest(_ stretch: Int, after pcm: Data) {
        let seconds = Double(pcm.count / 2) / GeminiLive.speechRate + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.samplePlayer.stop(ifStill: stretch)
        }
    }

    // MARK: Preparing a talk

    /// Has the brain write a talk for the meeting the brief describes, from the notes and
    /// the code, and chooses that talk. It takes a few minutes; nothing else waits on it.
    func prepare() {
        guard phase == .idle, preparing == nil, let root else { return }
        saveBriefNow()
        let request = brief
        preparing = "getting ready"
        preparedLine = nil
        message = nil
        Task.detached(priority: .userInitiated) {
            do {
                let talk = try await Preparation.prepare(root: root, request: request) { what in
                    Task { @MainActor [weak self] in
                        if self?.preparing != nil { self?.preparing = what }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.preparing = nil
                    self.talks = Project.talks(root: root)
                    self.talk = talk.path
                    self.preparedLine = "Its brain wrote “\(talk.title)”: \(talk.sections) sections, in \(Int(talk.seconds / 60) + 1) min. Read it before the meeting."
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.preparing = nil
                    self?.message = "\(error)"
                }
            }
        }
    }

    /// Opens the chosen talk's file, to read or change.
    func openTalk() {
        guard let root, !talk.isEmpty else { return }
        NSWorkspace.shared.open(Project.file(talk, root: root))
    }

    // MARK: The brief

    private func briefChanged() {
        guard isLive else { return }
        // Saved a moment after the typing stops, and again when a meeting starts.
        briefSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveBriefNow() }
        briefSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveBriefNow() {
        briefSave?.cancel()
        briefSave = nil
        guard isLive, let root, brief.trimmingCharacters(in: .whitespacesAndNewlines) != Project.brief(root: root) else { return }
        do { try Project.saveBrief(brief, root: root) } catch { message = "The brief could not be saved: \(error.localizedDescription)" }
    }

    // MARK: Where the notes come from

    /// Reads the notes again and says what was found. With `check`, linked repositories
    /// are checked on GitHub first.
    func refreshSources(check: Bool) {
        guard let root else { return }
        if check {
            guard !checkingSources else { return }
            checkingSources = true
        }
        Task.detached(priority: .utility) {
            let library = NotesLibrary(root: root, settings: BrainSettings.load(root: root))
            let statuses = check ? await LinkedRepos.refresh(root: root, sources: library.sources)
                : LinkedRepos.statuses(root: root, sources: library.sources)
            let notes = library.current()
            await MainActor.run { [weak self] in self?.show(library: library, notes: notes, statuses: statuses, checked: check) }
        }
    }

    private func show(library: NotesLibrary, notes: Notes, statuses: [LinkedRepos.Status], checked: Bool) {
        if checked { checkingSources = false }
        var rows = [SourceRow]()
        var problems = library.problems
        for (source, count) in zip(library.sources, notes.counts) {
            var detail = count.files + count.others == 0 ? "nothing to read here"
                : count.others == 0 ? "\(count.files) \(count.files == 1 ? "file" : "files")"
                : "\(count.files) \(count.files == 1 ? "note" : "notes"), \(count.others) other \(count.others == 1 ? "file" : "files") to search"
            var problem: String?
            if let status = statuses.first(where: { $0.name == source.name }), source.repo != nil {
                if let error = status.error {
                    problem = status.sha == nil ? error : "Not updated: \(error)"
                } else if let sha = status.sha {
                    detail += ", at \(sha.prefix(7)), checked \(Self.ago(status.checkedAt))"
                }
            } else if source.repo == nil, !FileManager.default.fileExists(atPath: source.folder.path) {
                problem = "This folder is not there."
            }
            if problem != nil { problems.append("\(source.name): \(problem!)") }
            rows.append(SourceRow(id: "\(source.index ?? -1)-\(source.name)", name: source.name, place: source.place,
                                  detail: detail, problem: problem, index: source.index))
        }
        sources = rows
        let settings = BrainSettings.load(root: root ?? URL(fileURLWithPath: "/"))
        let big = notes.fits(within: settings.docsStuffLimitChars) ? "" : " (a lot: answers will take longer)"
        // Without notes the brain can still look further, if brain.json lets it.
        let beyond = settings.web ? "the web" : !settings.mcpConfig.isEmpty || settings.claudeCodeSetup ? "its tools" : nil
        notesLine = notes.isEmpty ? (beyond.map { "No notes. Stand can still look things up on \($0)" } ?? "No notes: Stand will say when it does not know")
            : "Notes: \(notes.summary)\(big)"
        sourcesMessage = (problems + notes.leftOut).first
    }

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "just now" : seconds < 3600 ? "\(seconds / 60) min ago" : "\(seconds / 3600) h ago"
    }

    /// Asks for a folder and adds it to the places Stand looks things up.
    func addFolder() {
        guard let root else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Stand will look things up in this folder: its documents, its code, whatever is kept there. It reads nothing outside it without being asked to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BrainSettings.add(source: BrainSettings.source(from: url.path, root: root), root: root)
            refreshSources(check: false)
        } catch {
            sourcesMessage = "\(error)"
        }
    }

    /// Adds a GitHub repository from whatever was pasted for it. Returns false, with the
    /// reason shown, when the text is not a repository address.
    @discardableResult
    func addRepository(_ text: String) -> Bool {
        guard let root else { return false }
        do {
            try BrainSettings.add(source: BrainSettings.source(from: text, root: root), root: root)
            checkingSources = false
            refreshSources(check: true)
            return true
        } catch {
            sourcesMessage = "\(error)"
            return false
        }
    }

    func removeSource(_ row: SourceRow) {
        guard let root, let index = row.index else { return }
        do {
            try BrainSettings.removeSource(at: index, root: root)
            refreshSources(check: false)
        } catch {
            sourcesMessage = "\(error)"
        }
    }

    // MARK: What the session reports

    private func apply(_ update: StandSession.Update) {
        switch update {
        case .state(let stand, let room, let floor):
            standSpeaking = stand
            roomSpeaking = room
            floorOpen = floor
        case .transcript(.stand, let text):
            standText = String((standText + text).suffix(220))
        case .transcript(.room, let text):
            roomText = String((roomText + text).suffix(140))
        case .interrupted:
            standText = ""
        case .carryOn:
            break
        case .lookingUp:
            lookingUp = true
        case .lookedUp:
            lookingUp = false
            brainBusy = nil
        case .brainBusy(let what):
            // Reading the notes is the ordinary case and needs no words of its own.
            brainBusy = what == "reading the notes" ? nil : what
        case .asking(let id, let what, let seconds):
            ask = Ask(id: id, what: what, until: Date().addingTimeInterval(seconds))
        case .asked(let id, _):
            if ask?.id == id { ask = nil }
        case .prompted(let text, let point):
            sheet = text.isEmpty ? sheet : text
            if let point { cue = point }
        case .askingHuman(let id, let question):
            questions.append(Question(id: id, text: question))
        case .humanAnswered(let id, let answer):
            questions.removeAll { $0.id == id }
            if let answer { passed.append(answer) }
        case .told(let text):
            passed.append(text)
        case .error(let text):
            message = text
        case .closed(let reason, let folder):
            clock?.invalidate()
            clock = nil
            audio?.stop()
            audio = nil
            if let folder, let summary = session?.summary {
                lastRun = folder
                let cost = summary["estimatedCostUsd"] as? Double ?? 0
                lastRunSummary = String(format: "Last run: %d:%02d, about $%.2f", elapsed / 60, elapsed % 60, cost)
            }
            if phase != .stopping { message = "The session ended: \(reason)" }
            addUpSpend()
            session = nil
            standSpeaking = false
            roomSpeaking = false
            lookingUp = false
            brainBusy = nil
            ask = nil
            questions = []
            reply = ""
            sheet = nil
            cue = nil
            phase = .idle
        }
    }
}

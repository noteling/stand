import SwiftUI

/// The small window that floats over the call. Deliberately plain for now.
///
/// Before a meeting it holds what Stand is given to work with: the talk, a brief for this
/// meeting, and the places it looks things up. During one it shows what is being said
/// and takes notes for Stand that only Stand sees.
struct PanelView: View {
    @ObservedObject var controller: SessionController
    @FocusState private var noteFocused: Bool
    @FocusState private var replyFocused: Bool
    @State private var repository = ""
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                Text(controller.status).font(.headline)
                Spacer()
                if controller.phase == .running {
                    Text(String(format: "%d:%02d", controller.elapsed / 60, controller.elapsed % 60))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if controller.phase == .idle {
                beforeTheMeeting
            } else {
                duringTheMeeting
            }

            HStack {
                switch controller.phase {
                case .idle:
                    Button(controller.attending ? "Join the meeting" : "Start the talk") { controller.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.needsKey)
                case .connecting, .stopping:
                    ProgressView().controlSize(.small)
                case .running:
                    Button("Hush  ⌃⌥S") { controller.hush() }
                    Button("Stop") { controller.stop() }
                }
                Spacer()
                Button("Stand's files") { controller.openProjectFolder() }
                    .buttonStyle(.link)
            }

            if let message = controller.message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if controller.phase == .idle, let build = controller.build {
                Text("Build \(build)").font(.caption2).foregroundStyle(.tertiary)
            }
            if controller.phase == .idle, let spend = controller.spendLine {
                Text(spend).font(.caption2).foregroundStyle(.tertiary)
            }
            if controller.phase == .idle, let run = controller.lastRun, let summary = controller.lastRunSummary {
                HStack {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show it") { controller.reveal(run.appendingPathComponent("recording.wav")) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        // The hotkey goes to Stand's question when there is one, and to the note field otherwise.
        .onChange(of: controller.noteFocusRequests) {
            if controller.questions.isEmpty { noteFocused = true } else { replyFocused = true }
        }
    }

    // MARK: Before the meeting

    @ViewBuilder private var beforeTheMeeting: some View {
        if controller.needsKey {
            // The one thing Stand cannot do without, asked for once on a Mac that does not have it yet.
            VStack(alignment: .leading, spacing: 6) {
                Text("Stand's voice needs a Gemini API key. Paste one here; it is kept in Stand's folder on this Mac.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Gemini API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { controller.saveKey(key); key = "" }
                    Button("Save") { controller.saveKey(key); key = "" }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.18)))
        }
        Picker("Talk", selection: $controller.talk) {
            ForEach(controller.talks, id: \.self) { path in
                Text(path.replacingOccurrences(of: "talks/", with: "").replacingOccurrences(of: ".md", with: "")).tag(path)
            }
            Divider()
            // No talk: Stand sits in the meeting, and speaks when spoken to or when the brief gives it a reason.
            Text("None: join the discussion").tag("")
        }
        if controller.talkShowsPages, controller.phase == .idle {
            // Where the pages go up: Stand's own window needs nothing allowed; Chrome is the
            // person's own, with what they are signed in to.
            Picker("Pages", selection: $controller.pagesInChrome) {
                Text("In a window of Stand's own").tag(false)
                Text("In Chrome").tag(true)
            }
            // The one thing its human has to do for a talk with pages, said before it starts.
            HStack(alignment: .firstTextBaseline) {
                Text(controller.pagesInChrome ? "Stand opens a window in your Chrome for this talk's pages. Share that window in the call."
                     : "This talk shows pages, in a window of their own. Share that window in the call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Open it") { controller.showScreenNow() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if !controller.talkPagesMissing.isEmpty {
                // Nothing is asked: Stand gives such a section without its page, and says so.
                let missing = controller.talkPagesMissing
                Text((missing.count == 1 ? "One of its pages is not there, and that section will be given without it. " : "\(missing.count) of its pages are not there, and those sections will be given without them. ") + missing.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(missing.joined(separator: "\n"))
            }
        }
        if !controller.voices.isEmpty { voiceRow }

        VStack(alignment: .leading, spacing: 4) {
            Text("For this meeting").font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $controller.brief)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if controller.brief.isEmpty {
                    Text("Who is there, what it is for, what to push for or avoid. Stand reads this before it starts, and tells no one.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            // The brain can write the talk itself, from the notes and the code, for the meeting described above.
            HStack(spacing: 6) {
                if let doing = controller.preparing {
                    ProgressView().controlSize(.small)
                    Text("Its brain is writing the talk: \(doing)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button("Prepare a talk from this") { controller.prepare() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(controller.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if !controller.attending {
                        Button("Read the talk") { controller.openTalk() }.buttonStyle(.link).font(.callout)
                    }
                }
            }
            if let line = controller.preparedLine, controller.preparing == nil {
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if controller.attending {
                Text(controller.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "With nothing written here, Stand speaks only when someone speaks to it."
                     : "Stand listens, answers when spoken to, and speaks up where this gives it a reason.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack {
            Text(controller.notesLine).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button(controller.showingSources ? "Done" : "Notes…") { controller.showingSources.toggle() }
                .buttonStyle(.link)
        }
        if controller.showingSources { sources }
        if let notice = controller.brainNotice {
            Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whose voice Stand speaks with. The menu gives each voice as the voice service
    /// describes it; "Hear it" says a few lines in the chosen one, which is how to choose.
    @ViewBuilder private var voiceRow: some View {
        HStack(spacing: 6) {
            Text("Voice")
            Menu {
                Picker("Voice", selection: $controller.voice) {
                    ForEach(["woman", "man", "neither"], id: \.self) { whose in
                        let group = controller.voices.filter { $0.whose == whose }
                        if !group.isEmpty {
                            Section(whose == "woman" ? "Women" : whose == "man" ? "Men" : "Neither") {
                                ForEach(group) { voice in
                                    Text(voice.manner.isEmpty ? voice.name : "\(voice.name): \(voice.manner)").tag(voice.name)
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(controller.voice)
            }
            .fixedSize()
            if let chosen = controller.voices.first(where: { $0.name == controller.voice }), !chosen.manner.isEmpty {
                Text(chosen.manner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if controller.hearing != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Hear it") { controller.hearVoice() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(controller.needsKey)
            }
        }
    }

    /// Where Stand looks things up: the project's own folder, more folders, GitHub repositories.
    @ViewBuilder private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.sources) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.callout).bold()
                        Text("\(row.place) · \(row.detail)").font(.caption).foregroundStyle(.secondary)
                        if let problem = row.problem {
                            Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if row.index != nil {
                        Button("Remove") { controller.removeSource(row) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            Divider()
            // An address is one of two things, and only its human knows which: a repository
            // Stand fetches by itself, or a page it reads through their browser, signed in as they are.
            TextField("A GitHub repository's address, or a page's", text: $repository)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Add repository", action: addRepository)
                Button("Add page", action: addPage)
                Spacer()
            }
            .disabled(repository.trimmingCharacters(in: .whitespaces).isEmpty)
            HStack {
                Button("Add a folder…") { controller.addFolder() }
                Button(controller.checkingSources || controller.readingPages ? "Checking…" : "Check now") { controller.checkSources() }
                    .disabled(controller.checkingSources || controller.readingPages)
                Spacer()
            }
            if let message = controller.sourcesMessage {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func addRepository() {
        if controller.addRepository(repository) { repository = "" }
    }

    private func addPage() {
        if controller.addPage(repository) { repository = "" }
    }

    // MARK: During the meeting

    @ViewBuilder private var duringTheMeeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("Stand", controller.standText)
            line("Room", controller.roomText)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)

        if let screen = controller.screenSays {
            // What last came of asking the screen for a page: what the audience sees, or that it did not change.
            Text(screen)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(screen)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let watch = controller.watchSays {
            // What the brain's watch last changed: the talk waits, goes on, or has moved to another section.
            Text(watch)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(watch)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if controller.cue != nil || controller.sheet != nil {
            // What its brain, following the meeting, has put in front of it. Stand decides what to do with it.
            VStack(alignment: .leading, spacing: 2) {
                if let cue = controller.cue {
                    Text("\(Text("Its brain thinks worth saying: ").bold())\(cue)").lineLimit(2)
                }
                if let sheet = controller.sheet {
                    Text("\(Text("On its sheet: ").bold())\(sheet)").lineLimit(3).truncationMode(.tail).help(sheet)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let ask = controller.ask {
            // The brain reads and searches by itself. For anything more it needs a yes, and no answer is a no.
            VStack(alignment: .leading, spacing: 6) {
                Text("Stand's brain asks to \(ask.what).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow") { controller.answerAsk(true) }
                    Button("No") { controller.answerAsk(false) }
                    Spacer()
                    Text(timerInterval: Date.distantPast...ask.until, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.18)))
        }

        if let question = controller.questions.first {
            // Stand was asked something only its human can say. It has told the meeting it
            // will come back to it, and passes on what is typed here.
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text("Stand asks you: ").bold())\(question.text)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Your answer, for Stand to pass on.  ⌃⌥N", text: $controller.reply)
                        .textFieldStyle(.roundedBorder)
                        .focused($replyFocused)
                        .onSubmit { controller.answerQuestion() }
                    Button("No answer") { controller.answerQuestion(nothing: true) }
                }
                if controller.questions.count > 1 {
                    Text("\(controller.questions.count - 1) more after this one").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.22)))
        }

        VStack(alignment: .leading, spacing: 3) {
            TextField("Tell Stand something. Only Stand sees it.  ⌃⌥N", text: $controller.note)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .onSubmit { controller.tell() }
                .onExitCommand { controller.dropNote() }
                .disabled(controller.phase != .running)
            if let last = controller.passed.last {
                Text("Passed: \(last)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var dotColor: Color {
        guard controller.phase == .running else { return .gray }
        if controller.standSpeaking { return .purple }
        return controller.roomSpeaking ? .orange : .green
    }

    private func line(_ who: String, _ text: String) -> some View {
        Text("\(Text("\(who): ").bold())\(text.isEmpty ? "…" : text)")
            .font(.callout)
            .foregroundStyle(who == "Stand" ? .primary : .secondary)
            .lineLimit(3)
            .truncationMode(.head)
    }
}

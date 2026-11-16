import Foundation

/// Something the voice model sent. Delivered on a background queue.
public enum LiveEvent {
    /// Stand's speech: mono 16-bit little-endian PCM at 24 kHz.
    case audio(Data)
    /// A fragment of what the room said, as the model transcribed it.
    case heard(String)
    /// A fragment of what Stand said.
    case said(String)
    /// The model cut its own speech short because someone spoke. Drop anything not yet played.
    case interrupted
    /// The model finished a turn and is now waiting.
    case turnComplete
    /// Stand used its one tool to say the talk is over and it is waiting for the audience.
    case floorOpened
    /// Stand used its tool for saying nothing, in place of a spoken reply.
    case keptQuiet
    /// Stand asked its brain a question. Answer with `GeminiLive.respond`.
    case lookUp(id: String, question: String)
    /// Stand has a question for its human. Acknowledge with `GeminiLive.respond(askHuman:)`;
    /// the answer itself goes to Stand later, as a note does.
    case askHuman(id: String, question: String)
    /// Someone asked to see a page, and Stand asks for the page of that section of the
    /// talk to be put on the screen. Answer with `GeminiLive.respond(showPage:)`.
    case showPage(id: String, section: String)
    /// Someone asked for the page to be scrolled, and Stand asks for it: "down" or "up".
    /// Answer with `GeminiLive.respond(scrollPage:)`.
    case scrollPage(id: String, direction: String)
    /// The connection was replaced by a new one that carries the same conversation.
    case reconnected(String)
    /// What the service says it counted: tokens it was given (text and audio), tokens it
    /// produced, and tokens of thinking.
    case usage(promptText: Int, promptAudio: Int, responseAudio: Int, responseText: Int, thoughts: Int)
    case closed(String)
}

/// A connection to Gemini Live over its WebSocket. The message shapes were captured from
/// Google's JavaScript SDK (@google/genai 3.2.0) talking to gemini-3.8-live on 2026-11-11.
///
/// A connection lasts about ten minutes. Before the server drops it, it says so, and this
/// class opens a new connection that resumes the same conversation and swaps it in.
public final class GeminiLive {
    public static let microphoneRate = 16_000.0
    public static let speechRate = 24_000.0
    static let floorTool = "open_the_floor"
    static let lookUpTool = "look_it_up"
    static let quietTool = "nothing_to_say"
    static let askHumanTool = "ask_my_human"
    static let showPageTool = "show_page"
    static let scrollPageTool = "scroll_page"

    private let urlSession = URLSession(configuration: .default)
    private let onEvent: (LiveEvent) -> Void
    private let lock = NSLock()

    // Guarded by `lock`.
    private var current: URLSessionWebSocketTask?
    private var retired = Set<ObjectIdentifier>()
    private var waitingForSetup = [ObjectIdentifier: CheckedContinuation<Void, Error>]()
    private var resumeHandle: String?
    private var resuming = false
    private var closed = false
    private var someoneSpeaking = false // with `marksActivity`: an utterance has been announced and not yet ended

    private var url = URL(string: "wss://generativelanguage.googleapis.com")!
    private var setup = [String: Any]()

    public init(onEvent: @escaping (LiveEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// The two refusals a person can do something about, in words that say what. The
    /// service's own wording is cut short by the connection, mid-address.
    public static let outOfCredit = "The Gemini account behind Stand's key has run out of credit, so Stand cannot speak. Add credit at ai.studio/projects, then start again."
    public static let keyRefused = "Gemini does not accept Stand's key. Paste a valid one."

    static func explain(_ reason: String) -> String? {
        let reason = reason.lowercased()
        if reason.contains("credits are depleted") { return outOfCredit }
        if reason.contains("api key not valid") { return keyRefused }
        return nil
    }

    /// `lookUp` is the description of the tool for asking the brain (prompts/tool-look-it-up.txt).
    /// Leave it out when there is no brain to ask, and Stand does not get the tool.
    /// `quiet` is the description of the tool for saying nothing (prompts/tool-nothing-to-say.txt):
    /// a voice model answers every message out loud unless it has another way to answer.
    /// `floor` is false when Stand gives no talk, and so has no floor to hand over.
    /// With `marksActivity` the service does not decide for itself when someone is speaking:
    /// this program tells it, with `activity(started:)`. Left to itself the service often
    /// loses the first word of anything said about a second after someone else finished.
    /// `context` is how much of the session the model keeps, in tokens (speech is 25 a
    /// second, and the instructions count too): when it reaches `limit` the oldest is
    /// dropped until `keep` is left. Left out, the service keeps about 105,000, more than
    /// an hour of talk, and every turn is billed for all of it.
    /// `voice` must be one of the names the live model takes (`Voices`): given any other,
    /// the service says nothing and speaks with a voice of its own choosing.
    /// `showPage` is the description of the tool for putting a page of the talk on the screen
    /// when someone asks to see it (prompts/tool-show-page.txt). Left out, as it is for a
    /// talk without a screen, Stand does not get the tool.
    public func connect(apiKey: String, instructions: String, model: String = "gemini-3.8-live", voice: String = Voices.usual,
                        lookUp: String? = nil, quiet: String? = nil, askHuman: String? = nil, showPage: String? = nil, scrollPage: String? = nil, floor: Bool = true,
                        marksActivity: Bool = false, context: (limit: Int, keep: Int)? = nil) async throws {
        var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        url = components.url!
        // NON_BLOCKING: Stand keeps talking while a call is handled.
        var tools = [[String: Any]]()
        if floor {
            tools.append([
                "name": Self.floorTool,
                "description": "Call this right after you have finished the talk and invited questions out loud. It tells the software running the session that you are now waiting for the audience, so it stops telling you to carry on.",
                "behavior": "NON_BLOCKING",
            ])
        }
        if let quiet {
            tools.append(["name": Self.quietTool, "description": quiet, "behavior": "NON_BLOCKING"])
        }
        if let lookUp {
            tools.append([
                "name": Self.lookUpTool,
                "description": lookUp,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["question": ["type": "STRING", "description": "The question, as a full sentence, with any names or numbers the person mentioned."]],
                    "required": ["question"],
                ],
                "behavior": "NON_BLOCKING",
            ])
        }
        if let askHuman {
            // The description of the tool for putting a question to Stand's human (prompts/tool-ask-my-human.txt).
            tools.append([
                "name": Self.askHumanTool,
                "description": askHuman,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["question": ["type": "STRING", "description": "The question for your human, as one full sentence, with what they need in order to answer it."]],
                    "required": ["question"],
                ],
                "behavior": "NON_BLOCKING",
            ])
        }
        if let showPage {
            tools.append([
                "name": Self.showPageTool,
                "description": showPage,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["section": ["type": "STRING", "description": "The number of the section of the talk whose page to show, as the talk numbers it: 3"]],
                    "required": ["section"],
                ],
                // Not NON_BLOCKING, unlike the others: Stand waits for the page before it says
                // anything more. Left free to keep talking, it once went straight on with the
                // talk while the page it had asked for came up under it.
            ])
        }
        if let scrollPage {
            // The same for scrolling at someone's asking (prompts/tool-scroll-page.txt): Stand waits for the page to move.
            tools.append([
                "name": Self.scrollPageTool,
                "description": scrollPage,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["direction": ["type": "STRING", "description": "Which way to move the page: down, up, or top."]],
                    "required": ["direction"],
                ],
            ])
        }
        setup = [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
            "systemInstruction": ["parts": [["text": instructions]], "role": "user"],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            // Without compression an audio session ends after 15 minutes.
            "contextWindowCompression": context.map { ["triggerTokens": String($0.limit), "slidingWindow": ["targetTokens": String($0.keep)]] }
                ?? ["slidingWindow": [String: Any]()],
        ]
        // A session with no tools at all (a sample of a voice) sends none, not an empty list.
        if !tools.isEmpty { setup["tools"] = [["functionDeclarations": tools]] }
        if marksActivity { setup["realtimeInputConfig"] = ["automaticActivityDetection": ["disabled": true]] }
        let task = try await open(resuming: nil)
        lock.withLock { current = task }
    }

    /// Microphone audio: mono 16-bit little-endian PCM at 16 kHz.
    public func sendMicrophone(_ pcm: Data) {
        send(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// Someone has started speaking, or has finished. Only for a connection made with
    /// `marksActivity`; the audio of what they say is sent in between.
    public func activity(started: Bool) {
        lock.withLock { someoneSpeaking = started }
        send(["realtimeInput": [started ? "activityStart" : "activityEnd": [String: Any]()]])
    }

    /// A message Stand must act on, such as "begin the talk".
    public func instruct(_ text: String) {
        send(["clientContent": ["turns": [["parts": [["text": text]], "role": "user"]], "turnComplete": true]])
    }

    /// A message Stand may answer with silence, such as "carry on if you are not done".
    public func nudge(_ text: String) {
        send(["realtimeInput": ["text": text]])
    }

    /// Something for Stand to know, added to the conversation without asking for a reply.
    /// Used while someone is speaking to it, when any other message would cut across them.
    public func inform(_ text: String) {
        send(["clientContent": ["turns": [["parts": [["text": text]], "role": "user"]], "turnComplete": false]])
    }

    /// The brain's answer to a `lookUp`. WHEN_IDLE: Stand says it once it has finished
    /// whatever it is saying, without being cut off. `quietly` (SILENT) lets Stand know
    /// the answer without saying anything.
    public func respond(lookUp id: String, answer: String, quietly: Bool = false) {
        send(["toolResponse": ["functionResponses": [[
            "id": id,
            "name": Self.lookUpTool,
            "response": ["result": answer],
            "scheduling": quietly ? "SILENT" : "WHEN_IDLE",
        ]]]])
    }

    /// Tells Stand its question has been put to its human. Without a sound when it has
    /// already said out loud that it will check; `aloud` when it has not, so that it says so now.
    public func respond(askHuman id: String, result: String, aloud: Bool = false) {
        send(["toolResponse": ["functionResponses": [[
            "id": id,
            "name": Self.askHumanTool,
            "response": ["result": result],
            "scheduling": aloud ? "WHEN_IDLE" : "SILENT",
        ]]]])
    }

    /// What came of putting a page on the screen at someone's asking. Stand has been
    /// waiting for this, and speaks when it has it.
    public func respond(showPage id: String, result: String) {
        send(["toolResponse": ["functionResponses": [[
            "id": id,
            "name": Self.showPageTool,
            "response": ["result": result],
        ]]]])
    }

    /// What came of scrolling the page at someone's asking.
    public func respond(scrollPage id: String, result: String) {
        send(["toolResponse": ["functionResponses": [[
            "id": id,
            "name": Self.scrollPageTool,
            "response": ["result": result],
        ]]]])
    }

    public func close() {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            closed = true
            return current
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Connections

    /// Opens a connection and returns once the server has accepted the setup.
    private func open(resuming handle: String?) async throws -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        task.resume()
        var setup = self.setup
        setup["sessionResumption"] = handle.map { ["handle": $0] } ?? [String: Any]()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { waitingForSetup[ObjectIdentifier(task)] = continuation }
            receive(on: task)
            send(["setup": setup], on: task)
        }
        return task
    }

    /// Replaces the connection with a new one that resumes the same conversation.
    private func resume(because why: String) {
        let handle = lock.withLock { () -> String? in
            guard !resuming, !closed, let handle = resumeHandle else { return nil }
            resuming = true
            return handle
        }
        guard let handle else { return }
        Task {
            do {
                let fresh = try await open(resuming: handle)
                let (old, midUtterance) = lock.withLock { () -> (URLSessionWebSocketTask?, Bool) in
                    let old = current
                    if let old { retired.insert(ObjectIdentifier(old)) }
                    current = fresh
                    resuming = false
                    return (old, someoneSpeaking)
                }
                // Someone is in the middle of speaking: the new connection has to be told, or
                // it takes the rest of what they say for nothing.
                if midUtterance { send(["realtimeInput": ["activityStart": [String: Any]()]], on: fresh) }
                old?.cancel(with: .goingAway, reason: nil)
                onEvent(.reconnected(why))
            } catch {
                let alreadyClosed = lock.withLock { () -> Bool in
                    resuming = false
                    let was = closed
                    closed = true
                    return was
                }
                if !alreadyClosed { onEvent(.closed("the connection could not be resumed after \(why): \(error)")) }
            }
        }
    }

    private func send(_ message: [String: Any], on task: URLSessionWebSocketTask? = nil) {
        guard let task = task ?? lock.withLock({ current }),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data): self.handle(data, from: task)
                case .string(let text): self.handle(Data(text.utf8), from: task)
                @unknown default: break
                }
                self.receive(on: task)
            case .failure(let error):
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
                    ?? error.localizedDescription
                self.ended(task, reason)
            }
        }
    }

    private func ended(_ task: URLSessionWebSocketTask, _ reason: String) {
        enum Outcome { case ignore, failedToStart(CheckedContinuation<Void, Error>), tryResume, closed }
        let outcome = lock.withLock { () -> Outcome in
            let id = ObjectIdentifier(task)
            if let pending = waitingForSetup.removeValue(forKey: id) { return .failedToStart(pending) }
            if retired.contains(id) || closed { return .ignore }
            guard task === current else { return .ignore }
            if resumeHandle != nil { return .tryResume }
            closed = true
            return .closed
        }
        switch outcome {
        case .ignore: break
        case .failedToStart(let pending):
            pending.resume(throwing: StandError(Self.explain(reason) ?? "Gemini closed the connection before the session started: \(reason)"))
        case .tryResume: resume(because: "the connection dropped (\(reason))")
        case .closed: onEvent(.closed(reason))
        }
    }

    private func handle(_ data: Data, from task: URLSessionWebSocketTask) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id = ObjectIdentifier(task)

        if message["setupComplete"] != nil {
            lock.withLock { waitingForSetup.removeValue(forKey: id) }?.resume()
        }
        guard !lock.withLock({ retired.contains(id) }) else { return }

        if let update = message["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true, let handle = update["newHandle"] as? String, !handle.isEmpty {
            lock.withLock { resumeHandle = handle }
        }
        if message["goAway"] != nil { resume(because: "the server announced it would disconnect") }
        if let usage = message["usageMetadata"] as? [String: Any] {
            // Counts come by kind of content where the service gives them, and as one number where it does not.
            func count(_ key: String, _ modality: String) -> Int {
                ((usage[key] as? [[String: Any]]) ?? []).filter { $0["modality"] as? String == modality }
                    .reduce(0) { $0 + ($1["tokenCount"] as? Int ?? 0) }
            }
            let prompt = usage["promptTokenCount"] as? Int ?? 0, response = usage["responseTokenCount"] as? Int ?? 0
            let promptAudio = count("promptTokensDetails", "AUDIO"), responseText = count("responseTokensDetails", "TEXT")
            onEvent(.usage(promptText: max(0, prompt - promptAudio), promptAudio: promptAudio,
                           responseAudio: max(0, response - responseText), responseText: responseText,
                           thoughts: usage["thoughtsTokenCount"] as? Int ?? 0))
        }

        if let content = message["serverContent"] as? [String: Any] {
            let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let encoded = (part["inlineData"] as? [String: Any])?["data"] as? String,
                   let audio = Data(base64Encoded: encoded), audio.count >= 2 {
                    onEvent(.audio(audio))
                }
            }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty { onEvent(.heard(text)) }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty { onEvent(.said(text)) }
            if content["interrupted"] as? Bool == true { onEvent(.interrupted) }
            if content["turnComplete"] as? Bool == true { onEvent(.turnComplete) }
        }

        let calls = (message["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] ?? []
        for call in calls {
            let name = call["name"] as? String ?? ""
            if name == Self.lookUpTool {
                let question = (call["args"] as? [String: Any])?["question"] as? String ?? ""
                onEvent(.lookUp(id: call["id"] as? String ?? "", question: question))
                continue // answered later, through respond(lookUp:answer:)
            }
            if name == Self.askHumanTool {
                let question = (call["args"] as? [String: Any])?["question"] as? String ?? ""
                onEvent(.askHuman(id: call["id"] as? String ?? "", question: question))
                continue // acknowledged by the session, through respond(askHuman:result:)
            }
            if name == Self.showPageTool {
                // A model may send the number as a number.
                let args = call["args"] as? [String: Any]
                let section = (args?["section"] as? String) ?? (args?["section"] as? NSNumber)?.stringValue ?? ""
                onEvent(.showPage(id: call["id"] as? String ?? "", section: section))
                continue // answered by the session once the screen has been looked at, through respond(showPage:result:)
            }
            if name == Self.scrollPageTool {
                let direction = (call["args"] as? [String: Any])?["direction"] as? String ?? "down"
                onEvent(.scrollPage(id: call["id"] as? String ?? "", direction: direction))
                continue // answered by the session once the page has moved, through respond(scrollPage:result:)
            }
            if name == Self.floorTool { onEvent(.floorOpened) }
            if name == Self.quietTool { onEvent(.keptQuiet) }
            // SILENT: note the result without prompting Stand to say anything about it.
            send(["toolResponse": ["functionResponses": [[
                "id": call["id"] as? String ?? "",
                "name": name,
                "response": ["result": "ok"],
                "scheduling": "SILENT",
            ]]]], on: task)
        }
    }
}

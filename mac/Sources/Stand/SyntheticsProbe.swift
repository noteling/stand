import Foundation
import StandCore

/// Maintained acceptance checks: real session control with deterministic voice/brain
/// connections, optionally followed by an actual Floor process on a scratch home.
/// No microphone, speakers, provider key or inference call is used by these checks.
enum SyntheticsProbe {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw StandError("Synthetics check failed: " + message) }
    }

    static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw StandError("Synthetics check timed out: " + message)
    }

    static func run(arguments: [String], root: URL) async throws {
        if arguments.contains("--expect-session-refusal") {
            let brain = SyntheticsBrain(command: ["/usr/bin/false"], home: "fixture", keyFile: "fixture", brief: "fixture")
            let problem = await brain.start()
            try check(problem?.contains("outside an employee work session") == true, "never strip an employee run fence")
            print("PASS employee work-session refusal before any child process")
            return
        }
        try await sessionChecks(root: root)
        func option(_ key: String) -> String? {
            arguments.firstIndex(of: key).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let python = option("--fixture-python") { try await protocolChecks(python: python) }
        if let python = option("--floor-python"), let home = option("--floor-home"), let key = option("--floor-key") {
            if arguments.contains("--expect-refused") {
                let brain = SyntheticsBrain(command: [python, "-m", "synthetics"], home: home, keyFile: key,
                                             brief: "Introduce yourself")
                defer { brain.stop() }
                let problem = await brain.start()
                try check(problem?.contains("not enabled") == true, "disabled Floor must refuse without becoming Stand")
                print("PASS actual Floor opt-in refusal")
            } else { try await floorChecks(python: python, home: home, key: key, expectedMemory: option("--expected-memory")) }
        }
        print("PASS Synthetics voice authority and meeting connection checks")
    }

    private static func sessionChecks(root: URL) async throws {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("stand-voice-check-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }
        for name in ["identity", "prompts", "talks"] {
            try manager.createSymbolicLink(at: scratch.appendingPathComponent(name), withDestinationURL: root.appendingPathComponent(name))
        }
        let employee = ProbeEmployee(), voice = ProbeVoice(), played = Counter()
        let humanQuestions = Counter()
        var settings = StandSession.Settings()
        settings.talk = ""; settings.brief = "Introduce yourself and discuss the team."
        settings.hasPrompter = false; settings.hasWatch = false; settings.hasEar = false
        settings.shortestRemark = 0; settings.shortestReplyToNote = 0; settings.lookUpPatience = 0.01
        let session = StandSession(root: scratch, label: "synthetics-check", settings: settings,
                                   brainFactory: { employee }, voiceFactory: { callback in voice.callback = callback; return voice },
                                   voiceKey: { "fixture-no-provider-call" })
        session.onSpeech = { data in played.add(data.count) }
        session.onUpdate = { update in
            if case .askingHuman = update { humanQuestions.add(1) }
        }
        try await session.open()
        defer { session.closeAndWait(reason: "fixture finished") }
        try check(voice.employeeResponses && !voice.askHuman, "voice must use employee response mode without a second human-answer path")
        try check(voice.instructions.contains("every substantive answer") && voice.instructions.contains("You are Aster"), "employee identity and response contract")
        try check(!voice.instructions.contains("# Your character") && !voice.instructions.contains("Stan is you"), "no inherited Stand personality")
        try check(session.speakerName == "Aster", "transcript attribution")
        voice.emit(.askHuman(id: "rogue-question", question: "A question invented by the voice")); _ = session.log
        try check(humanQuestions.value == 0, "the voice cannot create its own human questions")

        let pcm = Data(count: 4800)
        voice.emit(.said("independent content")); voice.emit(.audio(pcm))
        _ = session.log // drain the real session queue
        try check(played.value == 0 && session.lines.isEmpty, "unrequested voice output must never play or become a spoken line")
        voice.emit(.lookUp(id: "one", question: "Introduce yourself"))
        voice.emit(.turnComplete) // tool-call generation may finish before its result
        voice.emit(.audio(pcm))
        _ = session.log
        try check(played.value == 0, "no speech while the employee is thinking")
        try await wait("first employee answer") { voice.responseCount > 0 }
        voice.emit(.said("I am Aster, the engineer.")); voice.emit(.audio(pcm)); voice.emit(.turnComplete)
        _ = session.log
        try check(played.value == pcm.count, "correlated employee answer permits its voice turn")
        voice.emit(.audio(pcm)); _ = session.log
        try check(played.value == pcm.count, "a completed turn cannot reuse its permit")

        for (number, boundary) in [LiveEvent.interrupted, .reconnected("fixture")].enumerated() {
            let before = voice.responseCount
            voice.emit(.lookUp(id: "cut-\(number)", question: "A response"))
            try await wait("response before boundary") { voice.responseCount > before }
            voice.emit(boundary); voice.emit(.audio(pcm)); _ = session.log
            try check(played.value == pcm.count, "interruption/reconnection revokes permission")
        }
        let beforeCorrection = voice.responseCount
        voice.emit(.lookUp(id: "corrected", question: "Old question")); _ = session.log
        session.tell("A correction before the response"); _ = session.log
        try await wait("overtaken response") { voice.responseCount > beforeCorrection }
        voice.emit(.audio(pcm)); _ = session.log
        try check(played.value == pcm.count, "a panel correction invalidates an earlier response")
        let beforeFailure = voice.responseCount
        voice.emit(.lookUp(id: "fail", question: "fail"))
        try await wait("failed response") { voice.responseCount > beforeFailure }
        voice.emit(.audio(pcm)); _ = session.log
        try check(played.value == pcm.count, "a failed employee cannot become a voice fallback")
        session.tell("A panel correction"); _ = session.log
        voice.emit(.heard("An unidentified person in the room")); _ = session.log
        try await wait("observations") { employee.observationCount >= 3 }

        // The same maintained session remains unrestricted when it has no employee brain.
        let ordinaryVoice = ProbeVoice(), ordinaryPlayed = Counter()
        let ordinary = StandSession(root: scratch, label: "ordinary-check", settings: settings,
                                     brainFactory: { nil }, voiceFactory: { callback in ordinaryVoice.callback = callback; return ordinaryVoice },
                                     voiceKey: { "fixture-no-provider-call" })
        try await ordinary.open()
        defer { ordinary.closeAndWait(reason: "fixture finished") }
        ordinary.onSpeech = { ordinaryPlayed.add($0.count) }
        ordinaryVoice.emit(.said("I am Stand.")); ordinaryVoice.emit(.audio(pcm)); _ = ordinary.log
        try check(ordinaryPlayed.value == pcm.count && !ordinaryVoice.employeeResponses, "ordinary Stand must keep its existing voice path")
        employee.onMeetingEnded?("fixture connection loss")
        _ = session.log
        try check(session.closed, "employee connection loss must close the voice session")
        print("PASS real StandSession: denied independent audio, correlated answer, one turn, cancellation boundaries, failure, observations and ordinary-mode guard")
    }

    private static func floorChecks(python: String, home: String, key: String, expectedMemory: String?) async throws {
        let brain = SyntheticsBrain(command: [python, "-m", "synthetics"], home: home, keyFile: key,
                                     brief: "Introduce yourself and discuss the team.")
        if let problem = await brain.start() { throw StandError(problem) }
        defer { brain.stop() }
        try check(brain.identity?.name == "Aster", "actual Floor identity")
        brain.observe(.heard("A question from an unidentified speaker"))
        brain.observe(.note("The panel supplied this correction"))
        let answer = try await brain.answer("Introduce yourself")
        try check(answer.contains("Aster"), "actual Floor answer")
        if let expectedMemory {
            let recalled = try await brain.answer("What project code name is stored in your memory? Use memory_search to check it.")
            try check(recalled.contains(expectedMemory), "employee must retrieve its durable memory")
            print("PASS employee response retrieved the expected durable memory")
        }
        brain.observe(.spoken(answer, played: false, cutAt: nil))
        brain.observe(.spoken(answer, played: true, cutAt: nil))
        let slow = Task { try await brain.answer("slow fixture request") }
        try await Task.sleep(nanoseconds: 50_000_000)
        brain.giveUp()
        do { _ = try await slow.value; throw StandError("Cancelled Floor request returned an answer") }
        catch let error as StandError {
            try check(!error.description.contains("returned an answer"), error.description)
        }
        let ended = await brain.end()
        try check(ended, "actual Floor process must finish its normal end")
        print("PASS actual Floor process: identity, observations, answer and cancellation; awaiting normal end/wrap in the fixture driver")
    }

    private static func protocolChecks(python: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stand-floor-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("floor.py")
        try #"""
import json,sys
mode=sys.argv[1]
def emit(**item):
    print(json.dumps(dict(v=1,**item)),flush=True)
first=json.loads(sys.stdin.readline())
if mode=="denied":
    emit(type="error",message="meetings are not enabled")
    raise SystemExit(2)
if mode=="malformed":
    print("not json",flush=True)
    raise SystemExit(2)
if mode=="bool-version":
    print(json.dumps(dict(v=True,type="ready",name="Aster",persona="Aster")),flush=True)
else:
    emit(type="waiting")
    emit(type="ready",name="Aster",persona="You are Aster.",aliases=[])
for raw in sys.stdin:
    line=json.loads(raw)
    if line["type"]=="end":
        emit(type="ended")
        break
    if line["type"]!="ask": continue
    if mode=="crash": raise SystemExit(3)
    if mode=="timeout": continue
    if mode=="stale":
        emit(type="stale",id=line["id"])
    elif mode=="wrong-rev":
        emit(type="answer",id=line["id"],rev=line["rev"]+1,text="wrong revision")
    else:
        if mode=="old-id": emit(type="answer",id="old",rev=line["rev"],text="old answer")
        emit(type="answer",id=line["id"],rev=line["rev"],text="fresh answer")
"""#.write(to: script, atomically: true, encoding: .utf8)
        for mode in ["denied", "malformed", "bool-version", "stale", "wrong-rev", "crash", "timeout", "old-id"] {
            let brain = SyntheticsBrain(command: [python, script.path, mode], home: directory.path, keyFile: "fixture-key-path",
                                         brief: "fixture", startSeconds: 1, answerSeconds: 0.08)
            let problem = await brain.start()
            if ["denied", "malformed", "bool-version"].contains(mode) {
                try check(problem != nil, "bad startup must fail closed: " + mode)
            } else {
                try check(problem == nil, "valid startup: " + mode)
                if mode == "old-id" {
                    let answer = try await brain.answer("current")
                    try check(answer == "fresh answer", "old response ID must never win")
                    let cancelled = Task { () throws -> String in
                        await Task.yield()
                        return try await brain.answer("cancel before registration")
                    }
                    cancelled.cancel()
                    do { _ = try await cancelled.value; throw StandError("pre-cancelled task returned content") }
                    catch is CancellationError {}
                } else {
                    do { _ = try await brain.answer("current"); throw StandError("invalid response returned content: " + mode) }
                    catch let error as StandError {
                        try check(!error.description.contains("returned content"), error.description)
                    }
                }
            }
            let ended = await brain.end()
            try check(ended, "owned fixture process must exit: " + mode)
        }
        print("PASS Floor client: refused/malformed startup, bool version, stale/old IDs, wrong revision, crash, timeout and pre-registration cancellation")
    }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ value: Int) { lock.lock(); defer { lock.unlock() }; count += value }
    }

    private final class ProbeEmployee: EmployeeBrain {
        var onAsk: (@Sendable (BrainAsk) async -> Bool)?
        var onActivity: (@Sendable (String) -> Void)?
        var onMeetingEnded: (@Sendable (String) -> Void)?
        let summary = "fixture employee"
        let identity: EmployeeVoiceIdentity? = .init(name: "Aster", persona: "You are Aster, an engineer.", aliases: [])
        private let lock = NSLock()
        private var observed = 0
        var observationCount: Int { lock.lock(); defer { lock.unlock() }; return observed }
        func observe(_ observation: MeetingObservation) { lock.lock(); defer { lock.unlock() }; observed += 1 }
        func start() async -> String? { nil }
        func stop() {}
        func giveUp() {}
        func answer(_ question: String) async throws -> String {
            try await Task.sleep(nanoseconds: 50_000_000)
            if question == "fail" { throw StandError("fixture failure") }
            return "I am Aster, the engineer."
        }
    }

    private final class ProbeVoice: VoiceConnection {
        var callback: ((LiveEvent) -> Void)?
        var employeeResponses = false, askHuman = false
        var instructions = ""
        private let lock = NSLock()
        private var responses = 0
        var responseCount: Int { lock.lock(); defer { lock.unlock() }; return responses }
        func emit(_ event: LiveEvent) { callback?(event) }
        func connect(apiKey: String, instructions: String, model: String, voice: String,
                     lookUp: String?, quiet: String?, askHuman: String?, showPage: String?, scrollPage: String?,
                     floor: Bool, marksActivity: Bool, context: (limit: Int, keep: Int)?, employeeResponses: Bool) async throws {
            self.instructions = instructions; self.employeeResponses = employeeResponses; self.askHuman = askHuman != nil
        }
        func respond(lookUp id: String, answer: String, quietly: Bool) { lock.lock(); defer { lock.unlock() }; responses += 1 }
        func respond(askHuman id: String, result: String, aloud: Bool) {}
        func respond(showPage id: String, result: String) {}
        func respond(scrollPage id: String, result: String) {}
        func sendMicrophone(_ pcm: Data) {}
        func activity(started: Bool) {}
        func instruct(_ text: String) {}
        func nudge(_ text: String) {}
        func inform(_ text: String) {}
        func close() {}
    }
}

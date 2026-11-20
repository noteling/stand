import Foundation
import CoreFoundation

/// One Floor attach process per meeting. The employee home remains owned by Synthetics;
/// Stand only exchanges the versioned line protocol and never opens its databases.
// Mutable protocol state is confined to queue; callback access has its own lock.
public final class SyntheticsBrain: EmployeeBrain, @unchecked Sendable {
    private let callbacks = NSLock()
    private var askCallback: (@Sendable (BrainAsk) async -> Bool)?
    private var activityCallback: (@Sendable (String) -> Void)?
    private var endedCallback: (@Sendable (String) -> Void)?
    public var onMeetingEnded: (@Sendable (String) -> Void)? {
        get { callbacks.lock(); defer { callbacks.unlock() }; return endedCallback }
        set { callbacks.lock(); defer { callbacks.unlock() }; endedCallback = newValue }
    }
    public var onAsk: (@Sendable (BrainAsk) async -> Bool)? {
        get { callbacks.lock(); defer { callbacks.unlock() }; return askCallback }
        set { callbacks.lock(); defer { callbacks.unlock() }; askCallback = newValue }
    }
    public var onActivity: (@Sendable (String) -> Void)? {
        get { callbacks.lock(); defer { callbacks.unlock() }; return activityCallback }
        set { callbacks.lock(); defer { callbacks.unlock() }; activityCallback = newValue }
    }
    public var summary: String { "Synthetics employee through Floor" }
    public var identity: EmployeeVoiceIdentity? { queue.sync { persona } }

    private let queue = DispatchQueue(label: "stand.synthetics")
    private let queueKey = DispatchSpecificKey<Void>()
    private let command: [String], home: String, keyFile: String, brief: String
    private let startSeconds: Double, answerSeconds: Double
    private let meeting = "stand-" + UUID().uuidString.lowercased()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var persona: EmployeeVoiceIdentity?
    private var starting = [CheckedContinuation<String?, Never>]()
    private var pending: (id: String, rev: Int, done: CheckedContinuation<String, Error>)?
    private var stopped = false
    private var sequence = 0
    private var stopping = [CheckedContinuation<Bool, Never>]()
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); defer { lock.unlock() }; value = true }
    }

    public init(command: [String], home: String, keyFile: String, brief: String,
                startSeconds: Double = 90, answerSeconds: Double = 60) {
        self.command = command; self.home = home; self.keyFile = keyFile; self.brief = brief
        self.startSeconds = startSeconds; self.answerSeconds = answerSeconds
        queue.setSpecific(key: queueKey, value: ())
    }

    public func start() async -> String? {
        await withCheckedContinuation { done in
            queue.async {
                if self.stopped { done.resume(returning: "The employee meeting connection has ended."); return }
                if self.persona != nil { done.resume(returning: nil); return }
                self.starting.append(done)
                guard self.process == nil else { return }
                self.launch()
            }
        }
    }

    private func launch() {
        if let run = ProcessInfo.processInfo.environment["SYNTHETICS_SESSION_RUN"], !run.isEmpty {
            fail("Start the voice connection outside an employee work session.")
            return
        }
        guard let executable = command.first, executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable), !home.isEmpty, !keyFile.isEmpty,
              !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("Configure an executable syntheticsPython, syntheticsHome, syntheticsKeyFile and meeting brief.")
            return
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(command.dropFirst()) + ["--home", home, "floor", "attach", "--key-file", keyFile]
        // Preserve Floor's session refusal; this host process never promotes a session to owner.
        // The voice app's incidental provider environment must not reroute the
        // employee or select API billing. Floor currently uses its saved CLI login.
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !["ANTHROPIC_", "CLAUDE_CODE_", "OPENAI_", "CODEX_"].contains { key.hasPrefix($0) }
        }
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "SYNTHETICS_HOME")
        child.environment = env
        child.standardInput = stdin; child.standardOutput = stdout
        // Floor reports public failures through JSON. Never put arbitrary child stderr in the panel/log.
        child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        child.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.fail("The employee meeting process ended.")
                self?.output?.readabilityHandler = nil
                try? self?.output?.close(); self?.output = nil
                let waiters = self?.stopping ?? []; self?.stopping = []
                waiters.forEach { $0.resume(returning: true) }
            }
        }
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in self?.received(data) }
        }
        process = child
        do {
            try child.run()
            send(["type": "begin", "meeting": meeting, "goal": brief])
            queue.asyncAfter(deadline: .now() + startSeconds) { [weak self] in
                guard let self, self.persona == nil, !self.stopped else { return }
                self.fail("The employee was not ready in time. Ordinary work may still be yielding.")
            }
        } catch { fail("Could not start the configured employee meeting command.") }
    }

    public func answer(_ question: String) async throws -> String {
        let id = UUID().uuidString.lowercased(), cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { done in
                queue.async {
                    guard !cancellation.cancelled else { done.resume(throwing: CancellationError()); return }
                    guard !self.stopped, self.persona != nil else {
                        done.resume(throwing: StandError("The employee meeting is not ready.")); return
                    }
                    guard self.pending == nil else {
                        done.resume(throwing: StandError("The employee is already considering a response.")); return
                    }
                    self.pending = (id, self.sequence, done)
                    self.send(["type": "ask", "id": id, "rev": self.sequence, "question": question])
                    self.queue.asyncAfter(deadline: .now() + self.answerSeconds) { [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        self.cancel("The employee response timed out.")
                    }
                }
            }
        }, onCancel: { [weak self] in
            cancellation.cancel()
            self?.queue.async { [weak self] in
                guard let self, self.pending?.id == id else { return }
                self.cancel("The response was cancelled.")
            }
        })
    }

    public func giveUp() { queue.async { self.cancel("The response was cancelled.") } }

    private func cancel(_ reason: String) {
        guard let request = pending else { return }
        pending = nil
        send(["type": "cancel", "id": request.id])
        request.done.resume(throwing: StandError(reason))
    }

    public func observe(_ observation: MeetingObservation) {
        queue.async {
            guard self.persona != nil, !self.stopped else { return }
            var line: [String: Any]
            switch observation {
            case .heard(let text): line = ["type": "heard", "text": text]
            case .spoken(let text, let played, let cut):
                line = ["type": "spoken", "text": text, "played": played]
                if let cut { line["cut_at"] = cut }
            case .note(let text): line = ["type": "note", "text": text]
            }
            guard let text = line["text"] as? String, !text.isEmpty else { return }
            // Floor's per-line bound is 8192 bytes; preserve all words with ordered fragments.
            var fragment = ""
            for scalar in text.unicodeScalars {
                let next = String(scalar)
                if fragment.utf8.count + next.utf8.count > 8192 {
                    self.sequence += 1; line["seq"] = self.sequence; line["text"] = fragment; self.send(line)
                    fragment = ""
                }
                fragment += next
            }
            if !fragment.isEmpty {
                self.sequence += 1; line["seq"] = self.sequence; line["text"] = fragment; self.send(line)
            }
        }
    }

    private func send(_ item: [String: Any]) {
        guard let input else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: item.merging(["v": 1]) { _, new in new })
            try input.write(contentsOf: data + Data("\n".utf8))
        } catch { fail("The employee meeting connection could not accept input.") }
    }

    private func received(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty { fail("The employee meeting connection closed."); return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { fail("The employee sent an oversized protocol line."); return }
        while let end = buffer.firstIndex(of: 10) {
            let raw = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let line = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  integer(line["v"]) == 1, let type = line["type"] as? String else {
                fail("The employee sent an invalid protocol line."); return
            }
            switch type {
            case "waiting": onActivity?("waiting for the employee to finish current work")
            case "ready":
                guard persona == nil, let name = line["name"] as? String, !name.isEmpty,
                      let text = line["persona"] as? String, !text.isEmpty else {
                    fail("The employee meeting did not supply its identity."); return
                }
                persona = EmployeeVoiceIdentity(name: name, persona: text, aliases: line["aliases"] as? [String] ?? [])
                let waiters = starting; starting = []; waiters.forEach { $0.resume(returning: nil) }
            case "answer":
                guard let request = pending, line["id"] as? String == request.id else { continue }
                guard integer(line["rev"]) == request.rev, let text = line["text"] as? String, !text.isEmpty else {
                    cancel("The employee returned an invalid response revision."); continue
                }
                pending = nil
                request.done.resume(returning: text)
            case "stale", "cancelled":
                guard let request = pending, line["id"] as? String == request.id else { continue }
                pending = nil; request.done.resume(throwing: StandError("The meeting changed; ask the employee again."))
            case "ended": fail("The employee meeting ended.")
            case "error": fail("Employee meeting refused: \(line["message"] as? String ?? "unknown error")")
            default: fail("The employee sent an unsupported protocol line.")
            }
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { fail("The meeting has ended.") }
        else { queue.sync { fail("The meeting has ended.") } }
    }

    /// For process-owning hosts that are about to exit: allow the normal wrap to finish.
    /// False means the child did not exit within the bounded wait; it is not proof of cleanup.
    public func end() async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                self.fail("The meeting has ended.")
                guard self.process?.isRunning == true else { done.resume(returning: true); return }
                self.stopping.append(done)
                self.queue.asyncAfter(deadline: .now() + 15) {
                    let waiters = self.stopping; self.stopping = []
                    waiters.forEach { $0.resume(returning: false) }
                }
            }
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        onMeetingEnded?(reason)
        let waiters = starting; starting = []; waiters.forEach { $0.resume(returning: reason) }
        let request = pending; pending = nil; request?.done.resume(throwing: StandError(reason))
        // Normal end/EOF lets Floor stop its model, anchor its journal and release the hold.
        if process?.isRunning == true, let input,
           let data = try? JSONSerialization.data(withJSONObject: ["v": 1, "type": "end"]) {
            try? input.write(contentsOf: data + Data("\n".utf8))
        }
        try? input?.close(); input = nil
        // Keep draining stdout until exit: closing it now could break Floor's final
        // journal/wrap/hold-release path with a broken pipe.
        if let child = process {
            queue.asyncAfter(deadline: .now() + 10) { if child.isRunning { child.terminate() } }
        }
        if process?.isRunning != true {
            output?.readabilityHandler = nil; try? output?.close(); output = nil
        }
    }
}

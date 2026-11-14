import Foundation

/// A voice Stand can speak with.
public struct Voice: Equatable, Identifiable {
    /// The name the voice service knows it by: "Kore".
    public let name: String
    /// Whose voice the service says it is: "woman", "man" or "neither".
    public let whose: String
    /// How the service describes it: "firm, direct, authoritative".
    public let manner: String
    public var id: String { name }
}

/// Whose voice Stand speaks with. The voice service's live model takes thirty voices by
/// name and no others (prompts/voices-gemini.txt). The person chooses one in the panel.
public enum Voices {
    /// The voice Stand has when nobody has chosen one: every session before 2026-11-13 had it.
    public static let usual = "Kore"
    static let list = "prompts/voices-gemini.txt"

    /// The voices on the list, in its order. Empty when the list cannot be read.
    public static func all(root: URL) -> [Voice] {
        guard let text = try? Project.read(list, root: root) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return Voice(name: name, whose: parts.count > 1 ? parts[1] : "", manner: parts.count > 2 ? parts[2] : "")
        }
    }

    /// The voice of that name, however the name was typed. A name that is not on the
    /// list is an error here because it is not one to the service: asked for a voice it
    /// does not know, it says nothing and speaks with another.
    public static func named(_ name: String, root: URL) throws -> Voice {
        let voices = all(root: root)
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let voice = voices.first(where: { $0.name.lowercased() == wanted }) { return voice }
        if voices.isEmpty { throw StandError("The list of voices (\(list)) could not be read.") }
        throw StandError("Stand has no voice called \"\(name)\". The voices are: \(voices.map(\.name).joined(separator: ", ")).")
    }

    /// The lines a sample says: the last paragraph of prompts/voice-sample.md.
    public static func sampleLines(root: URL) -> String {
        (try? Project.read("prompts/voice-sample.md", root: root))?.components(separatedBy: "\n\n").last ?? ""
    }

    /// The same few lines said in that voice (prompts/voice-sample.md), as sound: mono
    /// 16-bit PCM at `GeminiLive.speechRate`. It is a short session of its own with the
    /// voice service, about a quarter of a cent, and is not kept among the runs. The sound
    /// comes at about the speed of speech; `onSound` gets each piece as it arrives, on a
    /// background thread, for whoever wants to play it without waiting for the rest.
    public static func sample(_ name: String, root: URL, onSound: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let voice = try named(name, root: root)
        let key = try Project.geminiKey(root: root)
        let instructions = try Project.read("prompts/voice-sample.md", root: root)
        let heard = Sample()
        let live = GeminiLive { event in
            switch event {
            case .audio(let pcm):
                heard.add(pcm)
                onSound?(pcm)
            case .turnComplete: heard.finish(nil)
            case .closed(let reason): heard.finish(GeminiLive.explain(reason) ?? "The voice service closed the connection: \(reason)")
            default: break
            }
        }
        defer { live.close() }
        try await live.connect(apiKey: key, instructions: instructions, voice: voice.name, floor: false)
        live.instruct("Go ahead.")
        let (pcm, problem) = await heard.wait(atMost: 25)
        if let problem { throw StandError(problem) }
        guard !pcm.isEmpty else { throw StandError("The voice service sent no sound for \(voice.name).") }
        return pcm
    }

    /// What one sample session has sent so far, and whoever is waiting for it to end.
    private final class Sample: @unchecked Sendable {
        private let lock = NSLock()
        private var pcm = Data()
        private var done = false
        private var problem: String?
        private var waiting: CheckedContinuation<(Data, String?), Never>?

        func add(_ more: Data) { lock.withLock { if !done { pcm.append(more) } } }

        /// The first call ends it: the turn finished, the connection closed, or time ran out.
        func finish(_ why: String?) {
            let (waiter, sound) = lock.withLock { () -> (CheckedContinuation<(Data, String?), Never>?, Data) in
                guard !done else { return (nil, Data()) }
                done = true
                problem = why
                defer { waiting = nil }
                return (waiting, pcm)
            }
            waiter?.resume(returning: (sound, why))
        }

        func wait(atMost seconds: Double) async -> (Data, String?) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finish("The voice service did not finish the sample within \(Int(seconds)) seconds.")
            }
            return await withCheckedContinuation { continuation in
                let already = lock.withLock { () -> (Data, String?)? in
                    if done { return (pcm, problem) }
                    waiting = continuation
                    return nil
                }
                if let already { continuation.resume(returning: already) }
            }
        }
    }
}

import AVFoundation
import Foundation
import SoundAnalysis

/// The ear: what tells someone calling for Stand from the other short sounds a room makes
/// while Stand is speaking.
///
/// The voice model cannot listen while it speaks. Until 2026-11-15 the only judge of a
/// sound made during its speech was a stopwatch: a sound counted as someone speaking once
/// 0.6 seconds of it had been loud (`SpeechMarker.cutsInAfter`). That lets a laugh pass,
/// and "excuse me" with it: a person said "hey", "excuse me" and "hello" five times in ten
/// seconds before a whole sentence stopped Stand. No length tells the two apart. Their
/// words were loud for 0.24 to 0.48 seconds, and the laugh that has to pass for 0.46.
///
/// The ear is asked about a sound the marker is still weighing, as soon as the sound has
/// gone quiet. It has two parts:
///
/// - The Mac's own sound classifier says whether the sound was words or a noise. It runs
///   on this Mac, takes about 45 milliseconds, and a noise goes no further.
/// - A small listening model, which understands what was said, says whether the words
///   were a call for the speaker ("excuse me", "hello?", its name) or anything else
///   ("yeah", "right", a remark between two other people). Its rules are prompts/ear.md.
///
/// Only a call stops Stand, and the sound then goes to the voice model as what was said.
/// Everything else is as it is without an ear: a sound that does not come to 0.6 seconds
/// is let pass. So the ear can make Stand stop sooner for a word meant for it, and can do
/// nothing else.
///
/// It is the one place where sound that did not stop Stand leaves this Mac: about a
/// second at a time, and only what the classifier took for words, to a listening model of
/// the voice service, under the same key.
public final class Ear {
    /// What the Mac's classifier made of a sound.
    public struct Kind {
        /// How sure it was, at its surest, that the sound was speech: 0 to 1.
        public var speech: Double
        /// What else it sounded most like, and how much, over the whole sound.
        public var other: String
        public var otherScore: Double
        /// How long the classifier took.
        public var seconds: Double

        public var described: String {
            let also = other.isEmpty ? "" : String(format: "; otherwise most like %@ (%.2f)", other.replacingOccurrences(of: "_", with: " "), otherScore)
            return String(format: "speech %.2f%@", speech, also)
        }
    }

    public enum Verdict: Equatable {
        /// Someone is calling for the speaker.
        case call
        case nothing
        /// The model answered with something other than the two words.
        case unclear(String)
        /// The model could not be asked.
        case failed(String)
    }

    public let model: String
    private let key: String
    private let rules: String
    private let question: String
    private let session: URLSession
    private let lock = NSLock()
    private var thinksLittle = true // guarded by `lock`: the model takes "think as little as you can"
    private var touchedAt = Date.distantPast // guarded by `lock`

    /// The classifier judges half a second at a time, which is its least.
    static let windowSeconds = 0.5

    public init(key: String, rules: String, question: String, model: String) {
        self.key = key
        self.rules = rules
        self.question = question
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// The ear as a talk has it, with its rules read from the project. Nil when the rules are not there.
    public static func make(root: URL, key: String, model: String) -> Ear? {
        guard let rules = try? Project.read("prompts/ear.md", root: root),
              let question = try? Project.read("prompts/ear-request.txt", root: root) else { return nil }
        return Ear(key: key, rules: rules, question: question.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
    }

    public var summary: String { "the Mac's own sound classifier for word or noise, and \(model) for whether the words are a call for Stand" }

    // MARK: Word or noise

    private final class Tally: NSObject, SNResultsObserving {
        var speech = 0.0
        var totals = [String: Double]()
        var windows = 0

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            windows += 1
            for found in result.classifications.prefix(8) {
                if found.identifier == "speech" {
                    speech = max(speech, found.confidence)
                } else if found.identifier != "music" { // what it makes of near-silence
                    totals[found.identifier, default: 0] += found.confidence
                }
            }
        }
    }

    /// What the Mac's sound classifier makes of a sound: mono 16-bit PCM at 16 kHz. Nil
    /// when the classifier could not be run. It takes a few hundredths of a second, and
    /// several times that the first time, when its model is loaded.
    public static func classify(_ pcm: Data) -> Kind? {
        let began = Date()
        var samples = PCM.samples(pcm)
        let least = Int(GeminiLive.microphoneRate * windowSeconds)
        if samples.count < least { samples += [Int16](repeating: 0, count: least - samples.count) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: GeminiLive.microphoneRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { out[i] = Float(sample) / 32768 }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 16000)
            request.overlapFactor = 0.8
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let tally = Tally()
            try analyzer.add(request, withObserver: tally)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
            guard tally.windows > 0 else { return nil }
            let other = tally.totals.max { $0.value < $1.value }
            return Kind(speech: tally.speech, other: other?.key ?? "", otherScore: (other?.value ?? 0) / Double(tally.windows),
                        seconds: Date().timeIntervalSince(began))
        } catch {
            return nil
        }
    }

    // MARK: A call, or not

    /// Asks the listening model whether the sound is someone calling for the speaker, and
    /// says how long the answer took. Never throws: a model that cannot be asked is a
    /// verdict of its own, and the sound is then let pass as it would be without an ear.
    public func listen(to pcm: Data) async -> (verdict: Verdict, seconds: Double) {
        let began = Date()
        func took() -> Double { Date().timeIntervalSince(began) }
        lock.withLock { touchedAt = Date() }
        var little = lock.withLock { thinksLittle }
        for _ in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request(pcm, thinksLittle: little))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
                let problem = ((json["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
                // A model that does not take the setting is asked again without it, and from then on.
                if status == 400, little, problem.lowercased().contains("thinking") {
                    little = false
                    lock.withLock { thinksLittle = false }
                    continue
                }
                guard status == 200 else { return (.failed(String(problem.prefix(160))), took()) }
                let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
                let text = ((content?["parts"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
                return (Self.verdict(text), took())
            } catch {
                return (.failed(error.localizedDescription), took())
            }
        }
        return (.failed("the listening model would not take the request"), took())
    }

    /// What a reply says. The rules ask for one word.
    public static func verdict(_ reply: String) -> Verdict {
        let first = reply.uppercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        switch first {
        case "CALL": return .call
        case "NOTHING": return .nothing
        default: return .unclear(String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
        }
    }

    private func request(_ pcm: Data, thinksLittle: Bool) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var generation: [String: Any] = ["temperature": 0, "maxOutputTokens": 80]
        if thinksLittle { generation["thinkingConfig"] = ["thinkingLevel": "minimal"] }
        let sound = PCM.wav(pcm, rate: GeminiLive.microphoneRate).base64EncodedString()
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": rules]]],
            "contents": [["role": "user", "parts": [["inlineData": ["mimeType": "audio/wav", "data": sound]], ["text": question]]]],
            "generationConfig": generation,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Gets ready ahead of the first sound: loads the classifier's model, and opens the
    /// connection to the listening model, which otherwise costs the first answer a few
    /// tenths of a second. Call it again when a sound begins: it does nothing if the
    /// connection was used in the last half minute.
    public func warm(classifier: Bool = false) {
        if classifier {
            DispatchQueue.global(qos: .utility).async { _ = Self.classify(PCM.silence(seconds: 0.6, rate: GeminiLive.microphoneRate)) }
        }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(touchedAt) > 30 else { return false }
            touchedAt = Date()
            return true
        }
        guard due else { return }
        // Asking what the model is costs nothing, and leaves the connection open.
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model)")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        session.dataTask(with: request) { _, _, _ in }.resume()
    }
}

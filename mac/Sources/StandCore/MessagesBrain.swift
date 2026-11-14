import Foundation

/// The brain over the Messages API: Anthropic directly, or a gateway that speaks the same
/// API (a base URL plus headers, with or without an Anthropic key). Raw HTTPS, because
/// there is no official Swift SDK. The request shapes follow Anthropic's raw-HTTP reference.
final class MessagesBrain: Brain {
    private static let apiVersion = "2026-10-21"
    /// Models where a safety decline can be re-run on another model server-side.
    private static let fallbackModels: Set = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    private let settings: BrainSettings
    private let apiKey: String?
    private let headers: [String: String]
    private let library: NotesLibrary
    private let instructions: String
    private let endpoint: URL
    private let isAnthropic: Bool
    private let urlSession: URLSession

    // This brain is one request to a model: nothing to keep open, nothing to ask its human.
    var onAsk: (@Sendable (BrainAsk) async -> Bool)?
    var onActivity: (@Sendable (String) -> Void)?
    func start() async -> String? { nil }
    func stop() {}
    func giveUp() {}

    var summary: String {
        let notes = library.current()
        return "the Messages API at \(endpoint.host ?? "?"), \(settings.model), effort \(settings.effort), \(notes.summary) \(notes.fits(within: settings.docsStuffLimitChars) ? "sent whole" : "read through tools")"
    }

    init(settings: BrainSettings, apiKey: String?, headers: [String: String], library: NotesLibrary, instructions: String) {
        self.settings = settings
        self.apiKey = apiKey
        self.headers = headers
        self.library = library
        self.instructions = instructions
        let base = settings.apiBaseURL.isEmpty ? "https://api.anthropic.com" : settings.apiBaseURL
        endpoint = URL(string: base.hasSuffix("/") ? base + "v1/messages" : base + "/v1/messages")!
        isAnthropic = endpoint.host?.lowercased() == "api.anthropic.com"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: configuration)
    }

    func answer(_ question: String) async throws -> String {
        // The notes as they are now: a file saved a minute ago is in them.
        let notes = library.current()
        guard notes.hasDocuments else { return "NOT FOUND. There are no notes to look this up in." }
        // This brain has the notes and no more: it has no tools of its own to search a
        // folder with, so whatever else the sources hold is out of its reach.
        let inline = notes.fits(within: settings.docsStuffLimitChars)
        let system = inline
            ? instructions + "\n\n# The notes\n\n" + notes.inlined
            : instructions + "\n\nThe notes are in files, and each path begins with the name of the place the file comes from. Find the answer with list_files, then search_files or read_file. Read as little as you need."
        var messages: [[String: Any]] = [["role": "user", "content": question]]
        for _ in 0..<6 {
            let response = try await send(messages, system: system, tools: !inline)
            let stop = response["stop_reason"] as? String ?? ""
            let content = response["content"] as? [[String: Any]] ?? []
            if stop == "refusal" { return "NOT FOUND. The model declined to answer that." }
            if stop == "max_tokens" { throw StandError("The brain's answer was cut off at the token limit.") }

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            if stop == "tool_use", !toolUses.isEmpty {
                // The assistant turn goes back exactly as it came, thinking blocks included.
                messages.append(["role": "assistant", "content": content])
                messages.append(["role": "user", "content": toolUses.map { result(for: $0, in: notes) }])
                continue
            }
            if stop == "pause_turn" {
                messages.append(["role": "assistant", "content": content])
                continue
            }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StandError("The brain's model returned no text (stop reason: \(stop)).") }
            return text
        }
        throw StandError("The brain did not reach an answer within six rounds of reading.")
    }

    private var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            ["name": name, "description": description,
             "input_schema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        return [
            tool("list_files", "List every notes file with its size.", [:], required: []),
            tool("read_file", "Read one notes file.", ["path": ["type": "string", "description": "A path exactly as list_files gave it."]], required: ["path"]),
            tool("search_files", "Find the lines in the notes that contain a word or phrase, ignoring case.",
                 ["query": ["type": "string", "description": "The word or phrase to look for."]], required: ["query"]),
        ]
    }

    private func result(for toolUse: [String: Any], in notes: Notes) -> [String: Any] {
        let input = toolUse["input"] as? [String: Any] ?? [:]
        var content: String
        var isError = false
        switch toolUse["name"] as? String {
        case "list_files":
            content = notes.list()
        case "read_file":
            if let text = notes.read(input["path"] as? String ?? "") {
                content = text
            } else {
                content = "There is no such file. Use a path exactly as list_files gave it."
                isError = true
            }
        case "search_files":
            content = notes.search(input["query"] as? String ?? "")
        default:
            content = "There is no such tool."
            isError = true
        }
        if content.isEmpty { content = "(empty)" }
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUse["id"] as? String ?? "", "content": content]
        if isError { block["is_error"] = true }
        return block
    }

    private func send(_ messages: [[String: Any]], system: String, tools withTools: Bool) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 4000,
            // The instructions and the notes are the same on every question, so cache them.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
        if !settings.effort.isEmpty { body["output_config"] = ["effort": settings.effort] }
        if withTools { body["tools"] = tools }
        // Anthropic's own API can re-run a safety decline on another model. A gateway may not know the parameter.
        let withFallback = isAnthropic && Self.fallbackModels.contains(settings.model)
        if withFallback { body["fallbacks"] = "default" }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        if withFallback { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }

        for attempt in 0..<2 {
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200 { return json }
            // Rate limits and server trouble are worth one quick retry; anything else is a mistake in the request.
            if attempt == 0, status == 429 || status >= 500 {
                try await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw StandError("The brain's request failed (HTTP \(status)): \(message)")
        }
        throw StandError("The brain's request failed twice.")
    }
}

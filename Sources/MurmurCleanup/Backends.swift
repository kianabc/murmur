import Foundation

// The JSON shape every provider is asked to return.
private let cleanedSchema: [String: Any] = [
    "type": "object",
    "properties": ["cleaned": ["type": "string"]],
    "required": ["cleaned"],
    "additionalProperties": false,
]

private func post(
    _ url: URL,
    body: [String: Any],
    headers: [String: String],
    session: URLSession
) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 20

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CleanupError.malformed("no HTTP response")
    }
    guard http.statusCode == 200 else {
        // Kept for a debugger, never rendered into errorDescription.
        let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
        throw CleanupError.http(http.statusCode, String(detail))
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CleanupError.malformed("body is not an object")
    }
    return json
}

// MARK: - Anthropic

struct AnthropicBackend: CleanupBackend {
    let provider = CleanupProvider.anthropic

    func send(
        prompt: CleanupPrompt, model: CleanupModelSpec, key: String, session: URLSession
    ) async throws -> RawCompletion {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 2048,
            "system": [[
                "type": "text", "text": prompt.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": prompt.user]],
            "output_config": ["format": ["type": "json_schema", "schema": cleanedSchema]],
        ]
        // Newer Claude models think by default, which we don't want on a
        // latency-critical path. Haiku 4.5 predates the parameter and rejects it.
        if model.id != "claude-haiku-4-5" {
            body["thinking"] = ["type": "disabled"]
            body["output_config"] = [
                "effort": "low",
                "format": ["type": "json_schema", "schema": cleanedSchema],
            ]
        }

        let json = try await post(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            body: body,
            headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
            session: session
        )

        let content = json["content"] as? [[String: Any]] ?? []
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        // input_tokens is the *uncached remainder*; cache fields are separate.
        let usage = json["usage"] as? [String: Any] ?? [:]
        return RawCompletion(
            text: text,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }
}

// MARK: - OpenAI

struct OpenAIBackend: CleanupBackend {
    let provider = CleanupProvider.openAI

    func send(
        prompt: CleanupPrompt, model: CleanupModelSpec, key: String, session: URLSession
    ) async throws -> RawCompletion {
        let body: [String: Any] = [
            "model": model.id,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user],
            ],
            // json_object rather than json_schema: the strict-schema form isn't
            // supported on every model in the list, and the prompt already
            // states the shape.
            "response_format": ["type": "json_object"],
        ]

        let json = try await post(
            URL(string: "https://api.openai.com/v1/chat/completions")!,
            body: body,
            headers: ["Authorization": "Bearer \(key)"],
            session: session
        )

        let choices = json["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""

        let usage = json["usage"] as? [String: Any] ?? [:]
        // OpenAI reports the *total* prompt including cached tokens, with the
        // cached portion broken out separately — the opposite of Anthropic.
        let promptTokens = usage["prompt_tokens"] as? Int ?? 0
        let cachedTokens = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        return RawCompletion(
            text: text,
            inputTokens: max(0, promptTokens - cachedTokens),
            outputTokens: usage["completion_tokens"] as? Int ?? 0,
            cacheReadTokens: cachedTokens
        )
    }
}

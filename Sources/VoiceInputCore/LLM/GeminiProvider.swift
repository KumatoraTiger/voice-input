import Foundation

/// `LLMProvider` over Google's Gemini API
/// (`POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`).
///
/// Two things make this provider look different from the other two:
///
/// - **The model goes in the URL path**, not the body, so the endpoint is built per
///   request rather than fixed. `baseURL` is what tests override.
/// - **The key travels in the `x-goog-api-key` header.** Google also accepts
///   `?key=…`, but a secret in a query string ends up in proxy logs and crash
///   reports; the header is the only shape used here.
public struct GeminiProvider: LLMProvider, @unchecked Sendable {
    public static let defaultBaseURL = URL(
        string: "https://generativelanguage.googleapis.com/v1beta")!

    public let id: LLMProviderID = .gemini
    public let displayName = "Google Gemini"
    public let suggestedModels = [
        "gemini-3.5-flash-lite",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-2.5-flash",
    ]
    /// The fast / low-cost tier: transcript cleanup is a short, mechanical task.
    public let defaultModel = "gemini-3.5-flash-lite"
    public let apiKeyURL = URL(string: "https://aistudio.google.com/apikey")!

    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = GeminiProvider.defaultBaseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    public func send(_ request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputError.missingAPIKey(.gemini)
        }

        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? defaultModel : model
        guard let url = Self.endpoint(base: baseURL, model: resolvedModel) else {
            throw VoiceInputError.invalidModelName(provider: displayName, model: resolvedModel)
        }

        // The system prompt stays in its own slot, never merged into the transcript
        // turn — that separation is the prompt-injection defence (docs/SECURITY.md).
        let systemInstruction = request.systemPrompt.flatMap { prompt in
            prompt.isEmpty ? nil : Payload.Content(role: nil, parts: [.init(text: prompt)])
        }

        let payload = Payload(
            systemInstruction: systemInstruction,
            contents: request.messages.map {
                Payload.Content(role: Self.role(for: $0.role), parts: [.init(text: $0.content)])
            },
            generationConfig: Payload.GenerationConfig(
                maxOutputTokens: request.maxOutputTokens,
                temperature: Self.supportsSamplingParameters(model: resolvedModel)
                    ? request.temperature
                    : nil,
                thinkingConfig: Self.supportsThinkingLevel(model: resolvedModel)
                    ? .init(thinkingLevel: "minimal")
                    : nil
            )
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data = try await ProviderHTTP.send(urlRequest, session: session, provider: displayName)
        let decoded = try ProviderHTTP.decode(Response.self, from: data, provider: displayName)

        guard let candidate = decoded.candidates?.first else {
            throw VoiceInputError.providerDecodingFailed(
                provider: displayName,
                detail: "candidates が空です。"
            )
        }

        let text = (candidate.content?.parts ?? [])
            .compactMap(\.text)
            .joined()

        guard !text.isEmpty else {
            // A candidate with no text is almost always `MAX_TOKENS` (the budget was
            // spent before any answer) or a safety block, so the reason is worth
            // surfacing — it is the difference between "raise the limit" and
            // "rephrase". It is a status word, never user content.
            throw VoiceInputError.providerDecodingFailed(
                provider: displayName,
                detail: "テキストが含まれていません（finishReason: \(candidate.finishReason ?? "不明")）。"
            )
        }

        return LLMResponse(
            text: text,
            inputTokens: decoded.usageMetadata?.promptTokenCount,
            outputTokens: decoded.usageMetadata?.candidatesTokenCount,
            model: decoded.modelVersion
        )
    }

    // MARK: - Model-family gates

    /// Gemini 3 deprecated `temperature` / `top_p` / `top_k`: the newest models
    /// ignore them today and Google has said future ones will reject them, and the
    /// Gemini 3 guide asks callers to leave temperature at its default. `LLMRequest`
    /// asks for 0 by default, so it is dropped for that family rather than sent.
    /// The model field is free text, so this is a prefix match rather than a list.
    static func supportsSamplingParameters(model: String) -> Bool {
        !model.lowercased().hasPrefix("gemini-3")
    }

    /// Gemini 3 models think by default (most at `high`), which for a
    /// short rewrite is latency the user feels — and worse, thinking tokens are
    /// charged against `maxOutputTokens`, so a long think can consume the whole
    /// budget and return a candidate with no text at all. `minimal` is requested
    /// explicitly for that family. Older models use the legacy `thinkingBudget`
    /// field and would reject `thinkingLevel`, so nothing is sent for them.
    static func supportsThinkingLevel(model: String) -> Bool {
        model.lowercased().hasPrefix("gemini-3")
    }

    /// Gemini names the assistant turn `model`.
    static func role(for role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "model"
        }
    }

    /// `…/v1beta/models/{model}:generateContent`.
    ///
    /// A user may type either `gemini-3.5-flash` or the fully qualified
    /// `models/gemini-3.5-flash`; both mean the same model, and doubling the prefix
    /// would 404.
    static func endpoint(base: URL, model: String) -> URL? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare =
            trimmed.hasPrefix("models/")
            ? String(trimmed.dropFirst("models/".count))
            : trimmed
        guard !bare.isEmpty,
            let encoded = bare.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        var prefix = base.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return URL(string: "\(prefix)/models/\(encoded):generateContent")
    }

    // MARK: - Wire format

    private struct Payload: Encodable {
        struct Part: Encodable {
            let text: String
        }
        struct Content: Encodable {
            /// Omitted on `systemInstruction`, which has no turn.
            let role: String?
            let parts: [Part]
        }
        struct ThinkingConfig: Encodable {
            let thinkingLevel: String
        }
        struct GenerationConfig: Encodable {
            let maxOutputTokens: Int
            let temperature: Double?
            let thinkingConfig: ThinkingConfig?
        }
        let systemInstruction: Content?
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct Response: Decodable {
        struct Part: Decodable {
            let text: String?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
        }
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
        let modelVersion: String?
    }
}

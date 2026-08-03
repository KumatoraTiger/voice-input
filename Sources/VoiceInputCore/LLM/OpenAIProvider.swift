import Foundation

/// `LLMProvider` over OpenAI's Chat Completions API.
public struct OpenAIProvider: LLMProvider, @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public let id: LLMProviderID = .openAI
    public let displayName = "OpenAI"
    public let suggestedModels = ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"]
    public let defaultModel = "gpt-4.1-mini"
    public let apiKeyURL = URL(string: "https://platform.openai.com/api-keys")!

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = OpenAIProvider.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    public func send(_ request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputError.missingAPIKey(.openAI)
        }

        var messages: [Payload.Message] = []
        if let system = request.systemPrompt, !system.isEmpty {
            messages.append(Payload.Message(role: "system", content: system))
        }
        messages.append(
            contentsOf: request.messages.map {
                Payload.Message(role: $0.role.rawValue, content: $0.content)
            }
        )

        let payload = Payload(
            model: request.model,
            messages: messages,
            max_completion_tokens: request.maxOutputTokens,
            temperature: request.temperature
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data = try await ProviderHTTP.send(urlRequest, session: session, provider: displayName)
        let decoded = try ProviderHTTP.decode(Response.self, from: data, provider: displayName)

        guard let text = decoded.choices.first?.message.content else {
            throw VoiceInputError.providerDecodingFailed(
                provider: displayName,
                detail: "choices が空です。"
            )
        }

        return LLMResponse(
            text: text,
            inputTokens: decoded.usage?.prompt_tokens,
            outputTokens: decoded.usage?.completion_tokens,
            model: decoded.model
        )
    }

    // MARK: - Wire format

    private struct Payload: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let max_completion_tokens: Int
        let temperature: Double?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }
}

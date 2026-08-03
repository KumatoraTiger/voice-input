import Foundation

/// `LLMProvider` over Anthropic's Messages API
/// (`POST https://api.anthropic.com/v1/messages`).
public struct AnthropicProvider: LLMProvider, @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Pinned wire version required on every Messages API request.
    public static let apiVersion = "2023-06-01"

    public let id: LLMProviderID = .anthropic
    public let displayName = "Anthropic"
    public let suggestedModels = [
        "claude-haiku-4-5",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-opus-5",
    ]
    /// The fast / low-cost tier: transcript cleanup is a short, mechanical task.
    public let defaultModel = "claude-haiku-4-5"
    public let apiKeyURL = URL(string: "https://console.anthropic.com/settings/keys")!

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = AnthropicProvider.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    public func send(_ request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceInputError.missingAPIKey(.anthropic)
        }

        let payload = Payload(
            model: request.model,
            max_tokens: request.maxOutputTokens,
            system: request.systemPrompt?.isEmpty == false ? request.systemPrompt : nil,
            messages: request.messages.map {
                Payload.Message(role: $0.role.rawValue, content: $0.content)
            },
            temperature: Self.supportsSamplingParameters(model: request.model)
                ? request.temperature
                : nil
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data = try await ProviderHTTP.send(urlRequest, session: session, provider: displayName)
        let decoded = try ProviderHTTP.decode(Response.self, from: data, provider: displayName)

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()

        guard !text.isEmpty else {
            throw VoiceInputError.providerDecodingFailed(
                provider: displayName,
                detail: "テキストブロックが含まれていません。"
            )
        }

        return LLMResponse(
            text: text,
            inputTokens: decoded.usage?.input_tokens,
            outputTokens: decoded.usage?.output_tokens,
            model: decoded.model
        )
    }

    /// Recent Claude models reject `temperature` / `top_p` / `top_k` with a 400,
    /// so the parameter is dropped for anything in those families. The model
    /// field is free text, so this is a prefix match rather than a fixed list.
    static func supportsSamplingParameters(model: String) -> Bool {
        let withoutSampling = [
            "claude-opus-5",
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos",
        ]
        let normalized = model.lowercased()
        return !withoutSampling.contains { normalized.hasPrefix($0) }
    }

    // MARK: - Wire format

    private struct Payload: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]
        let temperature: Double?
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        let model: String?
        let content: [Block]
        let usage: Usage?
    }
}

import Foundation

public enum LLMProviderID: String, Codable, Sendable, CaseIterable, Hashable {
    case openAI
    case anthropic
    case gemini
}

// Makes `[LLMProviderID: String]` encode as a JSON object rather than a flat array.
extension LLMProviderID: CodingKeyRepresentable {}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable { case user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> LLMMessage { .init(role: .user, content: text) }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: String
    public var systemPrompt: String?
    public var messages: [LLMMessage]
    public var maxOutputTokens: Int
    public var temperature: Double?

    public init(
        model: String,
        systemPrompt: String? = nil,
        messages: [LLMMessage],
        maxOutputTokens: Int = 2048,
        temperature: Double? = 0
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

public struct LLMResponse: Sendable, Equatable {
    public var text: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var model: String?

    public init(
        text: String, inputTokens: Int? = nil, outputTokens: Int? = nil, model: String? = nil
    ) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
    }
}

/// A chat-completion backend used for text formatting (and, later, voice commands).
///
/// Implementations must never log or persist the API key or the prompt body.
public protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }
    var displayName: String { get }
    /// Model ids offered in Settings. The field stays free-text so a user can type a
    /// newer model without waiting for an app update.
    var suggestedModels: [String] { get }
    var defaultModel: String { get }
    /// Where the user gets a key, shown as a link in Settings.
    var apiKeyURL: URL { get }
    func send(_ request: LLMRequest, apiKey: String) async throws -> LLMResponse
}

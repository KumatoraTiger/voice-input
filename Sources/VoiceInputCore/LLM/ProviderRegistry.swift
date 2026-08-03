import Foundation

/// The set of chat-completion backends the app knows about.
public struct LLMProviderRegistry: Sendable {
    public let all: [any LLMProvider]

    public init(all: [any LLMProvider]) {
        self.all = all
    }

    public func provider(for id: LLMProviderID) -> (any LLMProvider)? {
        all.first { $0.id == id }
    }

    /// The production registry. `session` is injectable so tests can stub the
    /// transport with a `URLProtocol`.
    public static func live(session: URLSession = .shared) -> LLMProviderRegistry {
        LLMProviderRegistry(all: [
            OpenAIProvider(session: session),
            AnthropicProvider(session: session),
            GeminiProvider(session: session),
        ])
    }
}

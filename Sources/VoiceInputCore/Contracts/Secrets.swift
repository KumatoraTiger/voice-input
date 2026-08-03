import Foundation

/// Identifies one secret in the store. Values are never written to disk in plain
/// text, never logged, and never included in exported settings.
public struct SecretKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static func apiKey(for provider: LLMProviderID) -> SecretKey {
        SecretKey(rawValue: "llm.apiKey.\(provider.rawValue)")
    }

    /// Cloud STT credentials are keyed separately so a user can, for example, use
    /// Anthropic for formatting and OpenAI only for transcription.
    public static func transcriptionAPIKey(for engine: TranscriptionEngineID) -> SecretKey {
        SecretKey(rawValue: "asr.apiKey.\(engine.rawValue)")
    }
}

/// Secure storage for API keys. The production implementation is the macOS Keychain.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Passing `nil` deletes the entry.
    func setSecret(_ value: String?, for key: SecretKey) throws
    func hasSecret(for key: SecretKey) -> Bool
}

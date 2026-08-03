import Foundation
import Observation
import VoiceInputCore

/// Drives the API キー tab.
///
/// Stored keys are **never** read back into the UI: the model only tracks whether
/// a slot has a value, and the draft the user is currently typing. Drafts are
/// dropped the moment they are written to the Keychain.
@MainActor
@Observable
final class APIKeysModel {
    /// One editable credential.
    struct Slot: Identifiable, Hashable {
        let key: SecretKey
        let title: String
        let subtitle: String
        let helpURL: URL?
        /// Which provider a connection test should go through, if any.
        let testProvider: LLMProviderID?
        /// Cloud speech-to-text keys are tested against the transcription endpoint.
        let testTranscriptionEngine: TranscriptionEngineID?

        var id: String { key.rawValue }
    }

    enum TestResult: Equatable {
        case running
        case success(String)
        case failure(String)
    }

    private(set) var slots: [Slot] = []
    private(set) var saved: [SecretKey: Bool] = [:]
    private(set) var results: [SecretKey: TestResult] = [:]
    var drafts: [SecretKey: String] = [:]
    /// Set when the Keychain itself refuses to cooperate.
    private(set) var storeError: String?

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let providers: LLMProviderRegistry

    init(secrets: any SecretStore, providers: LLMProviderRegistry) {
        self.secrets = secrets
        self.providers = providers
        self.slots = Self.makeSlots(providers: providers)
        refresh()
    }

    // MARK: - Queries

    func isSaved(_ key: SecretKey) -> Bool { saved[key] ?? false }

    func draft(for key: SecretKey) -> String { drafts[key] ?? "" }

    func setDraft(_ value: String, for key: SecretKey) { drafts[key] = value }

    func refresh() {
        var result: [SecretKey: Bool] = [:]
        for slot in slots {
            result[slot.key] = secrets.hasSecret(for: slot.key)
        }
        saved = result
    }

    // MARK: - Mutations

    func save(_ slot: Slot) {
        let value = draft(for: slot.key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try secrets.setSecret(value, for: slot.key)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        drafts[slot.key] = ""
        results[slot.key] = nil
        refresh()
    }

    func delete(_ slot: Slot) {
        do {
            try secrets.setSecret(nil, for: slot.key)
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
        drafts[slot.key] = ""
        results[slot.key] = nil
        refresh()
    }

    // MARK: - Connection test

    /// Makes exactly one minimal request so the user finds out about a bad key
    /// here rather than mid-dictation.
    func test(_ slot: Slot, settings: AppSettings) async {
        let typed = draft(for: slot.key).trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (try? secrets.secret(for: slot.key)) ?? nil
        guard let key = typed.isEmpty ? stored : typed, !key.isEmpty else {
            results[slot.key] = .failure("先に API キーを保存してください。")
            return
        }

        results[slot.key] = .running
        do {
            let detail = try await runTest(slot, apiKey: key, settings: settings)
            results[slot.key] = .success(detail)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results[slot.key] = .failure(message.truncated(to: 160))
        }
    }

    private func runTest(
        _ slot: Slot,
        apiKey: String,
        settings: AppSettings
    ) async throws -> String {
        if let engineID = slot.testTranscriptionEngine {
            return try await testTranscription(
                engineID: engineID, apiKey: apiKey, settings: settings)
        }
        guard
            let providerID = slot.testProvider,
            let provider = providers.provider(for: providerID)
        else {
            throw VoiceInputError.transcriptionFailed("このキーは接続テストに対応していません。")
        }
        let model =
            settings.models[providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? provider.defaultModel
        let response = try await provider.send(
            LLMRequest(
                model: model,
                systemPrompt: nil,
                messages: [.user("ping")],
                maxOutputTokens: 16,
                temperature: 0
            ),
            apiKey: apiKey
        )
        return "接続できました（\(response.model ?? model)）"
    }

    /// Uploads a fraction of a second of synthesised audio. The endpoint answering
    /// at all — even with an empty transcript — proves the key is accepted.
    private func testTranscription(
        engineID: TranscriptionEngineID,
        apiKey: String,
        settings: AppSettings
    ) async throws -> String {
        let scratch = InMemorySecretStore([.transcriptionAPIKey(for: engineID): apiKey])
        let engine = OpenAITranscriptionEngine(secrets: scratch)
        let configuration = TranscriptionConfiguration(
            locale: settings.locale,
            format: .capture,
            contextualStrings: [],
            model: settings.transcriptionModel.nilIfBlank
        )
        let session = try await engine.makeSession(configuration: configuration)
        await session.append(FakeAudioCapture.tone(seconds: 0.4))
        do {
            _ = try await session.finish()
        } catch VoiceInputError.emptyTranscript {
            // Expected: a 0.4s test tone contains no speech.
            return "接続できました（音声は認識されませんでした）"
        }
        return "接続できました"
    }

    // MARK: - Slots

    private static func makeSlots(providers: LLMProviderRegistry) -> [Slot] {
        var slots: [Slot] = LLMProviderID.allCases.map { id in
            let provider = providers.provider(for: id)
            return Slot(
                key: .apiKey(for: id),
                title: provider?.displayName ?? id.rawValue,
                subtitle: "テキスト整形に使用します。",
                helpURL: provider?.apiKeyURL,
                testProvider: id,
                testTranscriptionEngine: nil
            )
        }
        slots.append(
            Slot(
                key: .transcriptionAPIKey(for: .openAICloud),
                title: "OpenAI（音声認識）",
                subtitle: "クラウド音声認識に使用します。未設定の場合は上の OpenAI キーを使います。",
                helpURL: providers.provider(for: .openAI)?.apiKeyURL,
                testProvider: nil,
                testTranscriptionEngine: .openAICloud
            )
        )
        return slots
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

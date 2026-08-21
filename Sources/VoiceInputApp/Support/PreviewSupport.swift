#if DEBUG
import Foundation
import VoiceInputCore
import VoiceInputPlatform

extension AppEnvironment {
    /// An environment wired entirely to Core's fakes: no microphone, no
    /// Keychain, no network, no hotkey registration (previews never call
    /// `start()`).
    static func previewEnvironment(
        settings: AppSettings = AppSettings(),
        secrets: [SecretKey: String] = [:]
    ) -> AppEnvironment {
        let secretStore = InMemorySecretStore(secrets)
        let settingsStore = InMemorySettingsStore(settings)
        let engines = StaticEngineResolver(engines: [
            FakeTranscriptionEngine(id: .appleOnDevice, displayName: "Apple 音声認識（オンデバイス）"),
            FakeTranscriptionEngine(
                id: .appleSpeechAnalyzer,
                displayName: "Apple SpeechAnalyzer",
                availability: EngineAvailability(
                    status: .unsupportedOS("macOS 26 以降が必要です"),
                    detail: "SpeechAnalyzer は macOS 26 以降が必要です。"
                )
            ),
            FakeTranscriptionEngine(
                id: .openAICloud,
                displayName: "OpenAI（クラウド）",
                availability: EngineAvailability(
                    status: .needsAPIKey,
                    detail: "OpenAI の API キーが必要です。"
                )
            ),
        ])
        let providers = LLMProviderRegistry(all: [
            FakeLLMProvider(id: .openAI),
            FakeLLMProvider(id: .anthropic),
            FakeLLMProvider(id: .gemini),
        ])
        let output = FakeOutputSink()
        let sound = SoundFeedback(isEnabled: false)
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            engines: engines,
            providers: providers,
            settingsStore: settingsStore,
            secrets: secretStore,
            output: output,
            feedback: sound
        )
        let speech = SystemSpeechSynthesizer(localeIdentifier: settings.localeIdentifier)
        let narration = NarrationCoordinator(
            sources: [
                .selection: FakeNarrationSource(),
                .clipboard: FakeNarrationSource(),
            ],
            synthesizer: FakeSpeechSynthesizer(),
            providers: providers,
            secrets: secretStore,
            settings: { coordinator.settings }
        )
        return AppEnvironment(
            coordinator: coordinator,
            narration: narration,
            permissions: PermissionsService(),
            engines: engines,
            providers: providers,
            secrets: secretStore,
            output: output,
            sound: sound,
            speech: speech
        )
    }
}
#endif

import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Settings store")
struct SettingsStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "io.github.voiceinput.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("round-trips every field through UserDefaults")
    func roundTrip() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.transcriptionEngine = .openAICloud
        settings.localeIdentifier = "en-US"
        settings.transcriptionModel = "whisper-1"
        settings.vocabulary = ["Shaperon", "SwiftPM"]
        settings.llmProvider = .anthropic
        settings.models = [.openAI: "gpt-4.1", .anthropic: "claude-haiku-4-5"]
        settings.formattingEnabled = false
        settings.autoPasteEnabled = true
        settings.playSounds = false
        settings.historyLimit = 5
        settings.hotkey = HotkeyBinding(keyCode: 12, modifiers: 34)
        settings.hotkeyMode = .pushToTalk
        settings.launchAtLogin = true

        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test("corrupt data falls back to defaults instead of crashing")
    func corruptDataFallsBack() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            Data("{ this is not settings".utf8), forKey: UserDefaultsSettingsStore.defaultKey)
        let store = UserDefaultsSettingsStore(defaults: defaults)

        #expect(store.load() == AppSettings())
    }

    @Test("a settings format change never bricks the app")
    func unknownShapeFallsBack() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Valid JSON, wrong shape — e.g. a future version's layout.
        let payload = try JSONSerialization.data(withJSONObject: ["version": 99])
        defaults.set(payload, forKey: UserDefaultsSettingsStore.defaultKey)

        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == AppSettings())

        // …and saving over it recovers.
        try store.save(AppSettings(localeIdentifier: "en-GB"))
        #expect(store.load().localeIdentifier == "en-GB")
    }

    @Test("missing key yields defaults")
    func missingKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsSettingsStore(defaults: defaults).load() == AppSettings())
    }

    @Test("in-memory store round-trips")
    func inMemoryStore() throws {
        let store = InMemorySettingsStore()
        #expect(store.load() == AppSettings())
        try store.save(AppSettings(historyLimit: 3))
        #expect(store.load().historyLimit == 3)
    }
}

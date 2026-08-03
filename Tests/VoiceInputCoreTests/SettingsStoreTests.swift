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
        settings.llmProvider = .gemini
        settings.models = [
            .openAI: "gpt-4.1",
            .anthropic: "claude-haiku-4-5",
            .gemini: "gemini-3.5-flash-lite",
        ]
        settings.formattingEnabled = false
        settings.autoPasteEnabled = true
        settings.playSounds = false
        settings.historyLimit = 5
        settings.hotkey = HotkeyBinding(keyCode: 12, modifiers: 34)
        settings.hotkeyMode = .pushToTalk
        settings.launchAtLogin = true
        settings.styles = [
            FormattingStyle(
                name: "チャット",
                instructions: "短く",
                hotkey: HotkeyBinding(keyCode: 18, modifiers: 4096)
            ),
            FormattingStyle(name: "ショートカットなし", instructions: ""),
        ]
        settings.activeStyleID = settings.styles.first?.id

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

    /// Styles gained `hotkey` after the first release, so settings written before
    /// it existed have to keep loading — otherwise an update silently resets every
    /// preference the user has.
    @Test("settings saved before styles had shortcuts still load")
    func stylesWithoutHotkeyStillDecode() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = AppSettings()
        settings.localeIdentifier = "en-US"
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let styles = try #require(object["styles"] as? [[String: Any]])
        object["styles"] = styles.map { style in
            style.filter { $0.key != "hotkey" }
        }
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: UserDefaultsSettingsStore.defaultKey
        )

        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()

        #expect(loaded.localeIdentifier == "en-US")
        #expect(loaded.styles.count == FormattingStyle.builtIns.count)
        #expect(loaded.styles.allSatisfy { $0.hotkey == nil })
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

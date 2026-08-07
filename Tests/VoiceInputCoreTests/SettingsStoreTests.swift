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
        settings.vocabulary = ["Contoso", "SwiftPM"]
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
        settings.askHotkey = HotkeyBinding(keyCode: 19, modifiers: 4096)
        settings.askModels = [.openAI: "gpt-4.1", .anthropic: "claude-sonnet-5"]
        settings.askAnswerStyle = .detailed
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

        // Valid JSON, wrong shape — e.g. a future version's layout. Every key the
        // decoder wants is absent, so it lands on the defaults field by field; a
        // key present with the wrong *type* throws and `load()` falls back instead.
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

    /// The reason `AppSettings` decodes field by field. A build that adds a setting
    /// must still read the previous build's JSON, or the update silently resets
    /// every preference the user has — shortcut, provider, edited styles, all of it.
    @Test("settings saved before the ask feature existed still load, keeping the rest")
    func settingsWithoutAskFieldsStillDecode() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = AppSettings()
        settings.localeIdentifier = "en-US"
        settings.hotkey = HotkeyBinding(keyCode: 12, modifiers: 4096)
        settings.llmProvider = .anthropic
        settings.historyLimit = 7

        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in ["askHotkey", "askModels", "askAnswerStyle"] {
            object.removeValue(forKey: key)
        }
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: UserDefaultsSettingsStore.defaultKey
        )

        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()

        #expect(loaded.localeIdentifier == "en-US")
        #expect(loaded.hotkey == HotkeyBinding(keyCode: 12, modifiers: 4096))
        #expect(loaded.llmProvider == .anthropic)
        #expect(loaded.historyLimit == 7)
        // The new settings arrive at their defaults, which is what "opt-in" means.
        #expect(loaded.askHotkey == nil)
        #expect(loaded.askModels.isEmpty)
        #expect(loaded.askAnswerStyle == .concise)
    }

    /// Same hazard as `stylesWithoutHotkeyStillDecode`, one release later: a
    /// required `screenContext` key would have reset every existing install.
    @Test("settings saved before screen context existed still load, and read as off")
    func settingsWithoutScreenContextStillDecode() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = AppSettings()
        settings.localeIdentifier = "en-US"
        settings.screenContextEnabled = true
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["screenContext"] != nil)
        object.removeValue(forKey: "screenContext")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: UserDefaultsSettingsStore.defaultKey
        )

        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()

        #expect(loaded.localeIdentifier == "en-US")
        #expect(loaded.screenContextEnabled == false)
    }

    /// The tolerant decoder has to carry the *newest* field too. Left out of
    /// `init(from:)`, `screenContext` would round-trip as nil and quietly turn the
    /// feature off for anyone who had enabled it.
    @Test("screen context survives a round trip through the tolerant decoder")
    func screenContextRoundTrips() throws {
        var settings = AppSettings()
        settings.screenContextEnabled = true

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        #expect(decoded.screenContextEnabled)
        #expect(decoded.screenContext == settings.screenContext)
    }

    @Test("screen context is off in a fresh install")
    func screenContextDefaultsOff() {
        #expect(AppSettings().screenContextEnabled == false)
        #expect(AppSettings().screenContext == nil)
    }

    /// The same tolerance, stated as a rule rather than for one release's fields.
    @Test("any single missing key falls back to its default, not to a wholesale reset")
    func anyMissingKeyFallsBackIndividually() throws {
        var settings = AppSettings()
        settings.localeIdentifier = "en-GB"
        settings.historyLimit = 9

        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "historyLimit")
        object.removeValue(forKey: "playSounds")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.localeIdentifier == "en-GB")
        #expect(decoded.historyLimit == AppSettings().historyLimit)
        #expect(decoded.playSounds == AppSettings().playSounds)
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

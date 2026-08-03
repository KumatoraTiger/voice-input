import Foundation

/// Persists `AppSettings` as a single JSON blob in `UserDefaults`.
public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let defaultKey = "io.github.voiceinput.settings"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsSettingsStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// A settings-format change must never brick the app: anything unreadable
    /// falls back to defaults, and the next `save` overwrites it.
    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}

/// Non-persistent `SettingsStore` for tests and SwiftUI previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}

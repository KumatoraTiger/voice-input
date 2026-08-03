import Foundation

/// Non-persistent `SecretStore` for tests and SwiftUI previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecretKey: String]

    public init(_ storage: [SecretKey: String] = [:]) {
        self.storage = storage
    }

    public func secret(for key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func hasSecret(for key: SecretKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }
}

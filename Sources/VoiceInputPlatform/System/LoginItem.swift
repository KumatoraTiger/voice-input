import Foundation
import ServiceManagement

/// Whether the app is set to launch at login.
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    /// Registered, but the user has to switch it on in System Settings → General →
    /// Login Items (macOS asks for this after a re-registration).
    case requiresApproval
    /// Launch at login cannot work for this build — e.g. a bare executable run out
    /// of `.build/` rather than a signed `.app` bundle.
    case unsupported(String)
}

public enum LoginItemError: Error, LocalizedError {
    case unsupported(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "ログイン時に起動する設定を変更できません: \(detail)"
        case .operationFailed(let detail):
            return "ログイン項目の更新に失敗しました: \(detail)"
        }
    }
}

/// Launch-at-login via `SMAppService.mainApp`.
///
/// Every call fails soft: running from the build directory is the normal state
/// during development and must surface as an explanation, never a crash.
public enum LoginItem {
    private static let unsignedBundleReason =
        ".app バンドルとして署名・配置されていないビルドでは利用できません。"

    /// True when the process is actually running from an `.app` bundle.
    /// `SMAppService.mainApp` requires one; a raw SwiftPM binary has none.
    public static var isSupported: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var status: LoginItemStatus {
        guard isSupported else { return .unsupported(unsignedBundleReason) }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unsupported("ログイン項目の登録が見つかりません。")
        @unknown default: return .notRegistered
        }
    }

    public static var isEnabled: Bool { status == .enabled }

    public static func setEnabled(_ enabled: Bool) throws {
        guard isSupported else {
            throw LoginItemError.unsupported(unsignedBundleReason)
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            throw LoginItemError.operationFailed(error.localizedDescription)
        }
    }

    /// Opens System Settings → General → Login Items, for the `requiresApproval`
    /// case where the user has to finish the job themselves.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

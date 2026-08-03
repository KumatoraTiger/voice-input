import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import Observation
import Speech
import VoiceInputCore

/// State of one TCC permission.
public enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    /// Blocked by policy (MDM / parental controls); asking again will not help.
    case restricted

    public var isGranted: Bool { self == .granted }

    /// Whether prompting the user can still change the outcome.
    public var canRequest: Bool { self == .notDetermined }
}

/// Which System Settings privacy pane to send the user to.
public enum PrivacyPane: String, Sendable, CaseIterable {
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

/// Single entry point for every TCC check and request the app makes.
///
/// The observable properties are a cache refreshed by `refresh()` and by each
/// request; the `probe` statics read the live system state and are safe to call
/// from any isolation domain (the engines use them).
@MainActor
@Observable
public final class PermissionsService {
    public private(set) var microphone: PermissionStatus
    public private(set) var speechRecognition: PermissionStatus
    /// Accessibility has no "not determined" state: the process is trusted or not.
    public private(set) var accessibility: PermissionStatus
    /// Same shape as accessibility — granted or not, never "not determined".
    /// Only consulted when the user turns on screen context.
    public private(set) var screenRecording: PermissionStatus

    public init() {
        microphone = Self.microphoneStatus()
        speechRecognition = Self.speechRecognitionStatus()
        accessibility = Self.accessibilityStatus()
        screenRecording = Self.screenRecordingStatus()
    }

    /// Re-reads all three from the system. Cheap; call it when Settings appears or
    /// when the app becomes active.
    public func refresh() {
        microphone = Self.microphoneStatus()
        speechRecognition = Self.speechRecognitionStatus()
        accessibility = Self.accessibilityStatus()
        screenRecording = Self.screenRecordingStatus()
    }

    // MARK: - Requests

    @discardableResult
    public func requestMicrophone() async -> PermissionStatus {
        if Self.microphoneStatus() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        microphone = Self.microphoneStatus()
        return microphone
    }

    @discardableResult
    public func requestSpeechRecognition() async -> PermissionStatus {
        if Self.speechRecognitionStatus() == .notDetermined {
            _ = await Self.requestSpeechAuthorization()
        }
        speechRecognition = Self.speechRecognitionStatus()
        return speechRecognition
    }

    /// Everything dictation needs before recording can start.
    /// Throws the specific `VoiceInputError` the UI knows how to explain.
    public func requireDictationPermissions() async throws {
        if await requestMicrophone() != .granted {
            throw VoiceInputError.microphonePermissionDenied
        }
        if await requestSpeechRecognition() != .granted {
            throw VoiceInputError.speechPermissionDenied
        }
    }

    /// Shows the system "grant Accessibility access" alert. Only needed for
    /// auto-paste. The result is asynchronous and out of our control, so this only
    /// refreshes the cached value with what is true right now.
    @discardableResult
    public func promptForAccessibility() -> PermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        accessibility = Self.accessibilityStatus()
        return accessibility
    }

    /// Shows the system screen-recording prompt. Nothing calls this unless the
    /// user turns screen context on — that switch is the consent moment.
    @discardableResult
    public func promptForScreenRecording() -> PermissionStatus {
        _ = CGRequestScreenCaptureAccess()
        screenRecording = Self.screenRecordingStatus()
        return screenRecording
    }

    // MARK: - System Settings deep links

    public func openSettings(for pane: PrivacyPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    public func openMicrophoneSettings() { openSettings(for: .microphone) }
    public func openSpeechRecognitionSettings() { openSettings(for: .speechRecognition) }
    public func openAccessibilitySettings() { openSettings(for: .accessibility) }
    public func openScreenRecordingSettings() { openSettings(for: .screenRecording) }

    // MARK: - Live probes (isolation-free)

    public nonisolated static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    public nonisolated static func speechRecognitionStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    public nonisolated static func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Preflight rather than request: reading the state must never pop a dialog.
    public nonisolated static func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Bridges the last completion-handler API in this file so nothing else has to.
    private nonisolated static func requestSpeechAuthorization() async
        -> SFSpeechRecognizerAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

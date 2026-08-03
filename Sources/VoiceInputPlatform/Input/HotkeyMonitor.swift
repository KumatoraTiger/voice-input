import AppKit
import Carbon.HIToolbox
import Foundation
import VoiceInputCore

/// Failures specific to registering a global shortcut. Kept out of
/// `VoiceInputError` because they are recoverable inside Settings (pick another
/// key) rather than a dictation-pipeline failure.
public enum HotkeyError: Error, LocalizedError, Equatable {
    case registrationFailed(OSStatus)
    case handlerInstallationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "ショートカットキーを登録できませんでした。"
        case .handlerInstallationFailed:
            return "ショートカットキーの監視を開始できませんでした。"
        }
    }

    public var recoverySuggestion: String? {
        "他のアプリが同じキーを使用している可能性があります。別のキーを設定してください。"
    }
}

/// Global hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys are used instead of a `CGEventTap` because they work without
/// Accessibility permission — the app should be able to record on first launch and
/// only ask for Accessibility if the user turns auto-paste on.
@MainActor
public final class HotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var mode: HotkeyMode = .toggle
    private var onPress: () -> Void = {}
    private var onRelease: () -> Void = {}

    /// 'VINP' — namespaces our hot key IDs against other apps in the process.
    private static let signature: OSType = 0x5649_4E50
    private static var nextIdentifier: UInt32 = 1

    public init() {}

    deinit {
        // Carbon teardown touches no Swift state, so it is safe from a nonisolated
        // deinit. `MainActor.assumeIsolated` is not needed and would trap here.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    public private(set) var currentBinding: HotkeyBinding?

    /// Registers (or re-registers) the global shortcut. Safe to call repeatedly as
    /// the user edits the binding in Settings.
    public func register(
        _ binding: HotkeyBinding,
        mode: HotkeyMode,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) throws {
        unregister()

        self.mode = mode
        self.onPress = onPress
        self.onRelease = onRelease

        try installEventHandlerIfNeeded()

        Self.nextIdentifier &+= 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextIdentifier)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            self.onPress = {}
            self.onRelease = {}
            throw HotkeyError.registrationFailed(status)
        }

        hotKeyRef = ref
        currentBinding = binding
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        currentBinding = nil
        onPress = {}
        onRelease = {}
    }

    // MARK: - Formatting conveniences for the Settings UI

    public func displayString(for binding: HotkeyBinding) -> String {
        HotkeyFormatting.displayString(for: binding)
    }

    public func binding(from event: NSEvent) -> HotkeyBinding? {
        HotkeyFormatting.binding(from: event)
    }

    // MARK: - Carbon plumbing

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            throw HotkeyError.handlerInstallationFailed(status)
        }
        eventHandler = handler
    }

    fileprivate func handle(eventKind: UInt32) {
        switch mode {
        case .toggle:
            // Only key-down toggles; the release is meaningless in this mode.
            if eventKind == UInt32(kEventHotKeyPressed) { onPress() }
        case .pushToTalk:
            if eventKind == UInt32(kEventHotKeyPressed) {
                onPress()
            } else if eventKind == UInt32(kEventHotKeyReleased) {
                onRelease()
            }
        }
    }
}

/// Carbon hands us a bare C function, so the monitor travels through `userData`.
private let hotkeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)

    // The dispatcher target is the main event loop, so this already runs on the main
    // thread; the fallback keeps ordering intact if that ever stops being true.
    if Thread.isMainThread {
        MainActor.assumeIsolated { monitor.handle(eventKind: kind) }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { monitor.handle(eventKind: kind) }
        }
    }
    return noErr
}

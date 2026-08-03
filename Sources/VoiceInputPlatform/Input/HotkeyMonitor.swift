import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import VoiceInputCore

/// Failures specific to registering a global shortcut. Kept out of
/// `VoiceInputError` because they are recoverable inside Settings (pick another
/// key) rather than a dictation-pipeline failure.
public enum HotkeyError: Error, LocalizedError, Equatable {
    case registrationFailed(OSStatus)
    case handlerInstallationFailed(OSStatus)
    /// A modifier-only shortcut was requested but the app is not trusted for
    /// Accessibility, so it cannot see `flagsChanged` outside its own windows.
    case accessibilityRequired
    /// A modifier-only shortcut with fewer than two modifiers.
    case tooFewModifiers

    public var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "ショートカットキーを登録できませんでした。"
        case .handlerInstallationFailed:
            return "ショートカットキーの監視を開始できませんでした。"
        case .accessibilityRequired:
            return "修飾キーだけのショートカットには「アクセシビリティ」の許可が必要です。"
        case .tooFewModifiers:
            return "修飾キーだけのショートカットには 2 つ以上の修飾キーが必要です。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .registrationFailed, .handlerInstallationFailed:
            return "他のアプリが同じキーを使用している可能性があります。別のキーを設定してください。"
        case .accessibilityRequired:
            return "システム設定 → プライバシーとセキュリティ → アクセシビリティ で VoiceInput を許可してください。"
        case .tooFewModifiers:
            return "⇧⌃ のように 2 つ以上を組み合わせるか、通常のキーと組み合わせてください。"
        }
    }
}

/// Global hotkey, over one of two mechanisms depending on the binding.
///
/// **Key + modifiers** (⌥Space) goes through Carbon's `RegisterEventHotKey` rather
/// than a `CGEventTap`, because that works without Accessibility permission — the
/// app should be able to record on first launch and only ask for Accessibility if
/// the user turns auto-paste on.
///
/// **Modifiers only** (⇧⌃) cannot be expressed in Carbon at all, so it falls back
/// to `NSEvent` monitors on `flagsChanged`, with `ModifierHotkeyDetector` deciding
/// when that counts as a press. The *global* monitor needs Accessibility; the
/// *local* one is what makes the shortcut work while VoiceInput's own window is
/// frontmost.
@MainActor
public final class HotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var mode: HotkeyMode = .toggle
    private var onPress: () -> Void = {}
    private var onRelease: () -> Void = {}

    // Modifier-only backend.
    private var detector: ModifierHotkeyDetector?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    /// Installed only for the duration of a hold — see `syncKeyDownMonitors`.
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    /// 'VINP' — namespaces our hot key IDs against other apps in the process.
    private static let signature: OSType = 0x5649_4E50
    private static var nextIdentifier: UInt32 = 1

    public init() {}

    deinit {
        // Carbon teardown touches no Swift state, so it is safe from a nonisolated
        // deinit. `MainActor.assumeIsolated` is not needed and would trap here.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
        if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
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

        do {
            if let keyCode = binding.keyCode {
                try registerCarbon(keyCode: keyCode, modifiers: binding.modifiers)
            } else {
                try registerModifierOnly(binding)
            }
        } catch {
            self.onPress = {}
            self.onRelease = {}
            throw error
        }

        currentBinding = binding
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        syncKeyDownMonitors(holding: false)
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        detector = nil
        currentBinding = nil
        onPress = {}
        onRelease = {}
    }

    /// Whether the *currently configured* binding can actually fire right now.
    /// A modifier-only shortcut silently stops working if Accessibility is revoked,
    /// so Settings re-checks this rather than trusting the last registration.
    public var isOperational: Bool {
        guard let currentBinding else { return false }
        return !currentBinding.isModifierOnly || AXIsProcessTrusted()
    }

    // MARK: - Formatting conveniences for the Settings UI

    public func displayString(for binding: HotkeyBinding) -> String {
        HotkeyFormatting.displayString(for: binding)
    }

    public func binding(from event: NSEvent) -> HotkeyBinding? {
        HotkeyFormatting.binding(from: event)
    }

    // MARK: - Backend: key + modifiers (Carbon)

    private func registerCarbon(keyCode: UInt32, modifiers: UInt32) throws {
        try installEventHandlerIfNeeded()

        Self.nextIdentifier &+= 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextIdentifier)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw HotkeyError.registrationFailed(status)
        }
        hotKeyRef = ref
    }

    // MARK: - Backend: modifiers only (NSEvent flagsChanged)

    private func registerModifierOnly(_ binding: HotkeyBinding) throws {
        guard binding.modifierCount >= 2 else { throw HotkeyError.tooFewModifiers }
        guard AXIsProcessTrusted() else { throw HotkeyError.accessibilityRequired }

        detector = ModifierHotkeyDetector(required: binding.modifiers, mode: mode)

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.feedDetector(event) }
        }
        // Global monitors never see events aimed at our own windows, so Settings
        // and the HUD would otherwise be dead zones for the shortcut.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.feedDetector(event) }
            return event
        }
    }

    private func feedDetector(_ event: NSEvent) {
        guard var detector else { return }
        let input: ModifierHotkeyDetector.Input =
            event.type == .flagsChanged
            ? .flagsChanged(HotkeyFormatting.carbonModifiers(from: event.modifierFlags))
            : .keyDown

        let output = detector.handle(input)
        self.detector = detector
        syncKeyDownMonitors(holding: detector.isHolding)

        switch output {
        case .press: onPress()
        case .release: onRelease()
        case .none: break
        }
    }

    /// Watches key-down events **only while the shortcut's modifiers are held**.
    ///
    /// `.toggle` has to know that some other key was pressed during the hold, or
    /// ⇧⌃ would fire every time the user typed ⌃⇧→. That is the whole reason the
    /// app looks at key-down at all, so the monitor is installed for the duration
    /// of the hold and torn down immediately afterwards rather than running for the
    /// life of the process. Only `event.type` is ever read — never the character.
    /// `.pushToTalk` does not need this at all.
    private func syncKeyDownMonitors(holding: Bool) {
        let wanted = holding && mode == .toggle
        guard wanted != (globalKeyDownMonitor != nil || localKeyDownMonitor != nil) else {
            return
        }

        if wanted {
            globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.noteKeyDown() }
            }
            localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.noteKeyDown() }
                return event
            }
        } else {
            if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
            if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
            globalKeyDownMonitor = nil
            localKeyDownMonitor = nil
        }
    }

    private func noteKeyDown() {
        guard var detector else { return }
        _ = detector.handle(.keyDown)
        self.detector = detector
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

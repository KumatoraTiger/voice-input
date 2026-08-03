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
    /// A modifier-only shortcut was asked for somewhere only Carbon can serve —
    /// today that means a formatting style. See `HotkeyPlan`.
    case modifierOnlyUnsupported

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
        case .modifierOnlyUnsupported:
            return HotkeyRejection.modifierOnlyUnsupported.message
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
        case .modifierOnlyUnsupported:
            return "通常のキーと修飾キーを組み合わせてください（例: ⌃⇧1）。"
        }
    }
}

/// Every global shortcut the app claims, over one of two mechanisms depending on
/// the binding.
///
/// **Key + modifiers** (⌥Space) goes through Carbon's `RegisterEventHotKey` rather
/// than a `CGEventTap`, because that works without Accessibility permission — the
/// app should be able to record on first launch and only ask for Accessibility if
/// the user turns auto-paste on. Any number of these can be live at once, which is
/// what gives each formatting style its own shortcut; the Carbon event carries the
/// `EventHotKeyID`, so a press is routed back to the `HotkeyPurpose` that owns it.
///
/// **Modifiers only** (⇧⌃) cannot be expressed in Carbon at all, so it falls back
/// to `NSEvent` monitors on `flagsChanged`, with `ModifierHotkeyDetector` deciding
/// when that counts as a press. The *global* monitor needs Accessibility; the
/// *local* one is what makes the shortcut work while VoiceInput's own window is
/// frontmost. Exactly one binding — the main dictation one — may take this path:
/// it is the only shape that costs a permission and a permanent event monitor.
@MainActor
public final class HotkeyMonitor {
    private struct CarbonRegistration {
        let ref: EventHotKeyRef
        let purpose: HotkeyPurpose
        let mode: HotkeyMode
    }

    private var carbon: [UInt32: CarbonRegistration] = [:]
    private var eventHandler: EventHandlerRef?
    private var onPress: (HotkeyPurpose) -> Void = { _ in }
    private var onRelease: (HotkeyPurpose) -> Void = { _ in }

    // Modifier-only backend. At most one, always the dictation shortcut.
    private var detector: ModifierHotkeyDetector?
    private var modifierPurpose: HotkeyPurpose?
    private var modifierMode: HotkeyMode = .toggle
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
        for registration in carbon.values { UnregisterEventHotKey(registration.ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
        if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
    }

    /// What was last asked for, in order — including anything that failed. The
    /// caller compares against this to decide whether a re-registration is needed
    /// at all, so a failing shortcut must not silently drop out of it.
    public private(set) var assignments: [HotkeyAssignment] = []

    /// Why each of those is not live, if it is not. Empty when everything took.
    public private(set) var failures: [HotkeyPurpose: HotkeyError] = [:]

    /// The main dictation binding, when one is registered.
    public var dictationBinding: HotkeyBinding? {
        assignments.first { $0.purpose == .dictation }?.binding
    }

    /// Registers (or re-registers) every shortcut. Safe to call repeatedly as the
    /// user edits bindings in Settings.
    ///
    /// A shortcut that cannot be claimed does not take the others down with it:
    /// failures come back per purpose, and everything else stays live. That
    /// matters because one style bound to a combination another app already owns
    /// must not cost the user their dictation shortcut.
    @discardableResult
    public func register(
        _ wanted: [HotkeyAssignment],
        onPress: @escaping (HotkeyPurpose) -> Void,
        onRelease: @escaping (HotkeyPurpose) -> Void
    ) -> [HotkeyPurpose: HotkeyError] {
        unregister()

        self.onPress = onPress
        self.onRelease = onRelease

        var failures: [HotkeyPurpose: HotkeyError] = [:]
        var registeredCount = 0

        for assignment in wanted {
            do {
                if let keyCode = assignment.binding.keyCode {
                    try registerCarbon(
                        keyCode: keyCode,
                        modifiers: assignment.binding.modifiers,
                        purpose: assignment.purpose,
                        mode: assignment.mode
                    )
                } else {
                    guard assignment.purpose == .dictation else {
                        throw HotkeyError.modifierOnlyUnsupported
                    }
                    try registerModifierOnly(assignment)
                }
                registeredCount += 1
            } catch let error as HotkeyError {
                failures[assignment.purpose] = error
            } catch {
                failures[assignment.purpose] = .registrationFailed(OSStatus(eventInternalErr))
            }
        }

        assignments = wanted
        self.failures = failures
        if registeredCount == 0 {
            self.onPress = { _ in }
            self.onRelease = { _ in }
        }
        return failures
    }

    public func unregister() {
        for registration in carbon.values { UnregisterEventHotKey(registration.ref) }
        carbon.removeAll()

        syncKeyDownMonitors(holding: false)
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        detector = nil
        modifierPurpose = nil

        assignments = []
        failures = [:]
        onPress = { _ in }
        onRelease = { _ in }
    }

    /// Whether the *currently configured* dictation binding can actually fire right
    /// now. A modifier-only shortcut silently stops working if Accessibility is
    /// revoked, so Settings re-checks this rather than trusting the last
    /// registration.
    public var isOperational: Bool {
        guard let dictationBinding, failures[.dictation] == nil else { return false }
        return !dictationBinding.isModifierOnly || AXIsProcessTrusted()
    }

    // MARK: - Formatting conveniences for the Settings UI

    public func displayString(for binding: HotkeyBinding) -> String {
        HotkeyFormatting.displayString(for: binding)
    }

    public func binding(from event: NSEvent) -> HotkeyBinding? {
        HotkeyFormatting.binding(from: event)
    }

    // MARK: - Backend: key + modifiers (Carbon)

    private func registerCarbon(
        keyCode: UInt32,
        modifiers: UInt32,
        purpose: HotkeyPurpose,
        mode: HotkeyMode
    ) throws {
        try installEventHandlerIfNeeded()

        Self.nextIdentifier &+= 1
        let identifier = Self.nextIdentifier
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)

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
        carbon[identifier] = CarbonRegistration(ref: ref, purpose: purpose, mode: mode)
    }

    // MARK: - Backend: modifiers only (NSEvent flagsChanged)

    private func registerModifierOnly(_ assignment: HotkeyAssignment) throws {
        guard assignment.binding.modifierCount >= 2 else { throw HotkeyError.tooFewModifiers }
        guard AXIsProcessTrusted() else { throw HotkeyError.accessibilityRequired }

        modifierPurpose = assignment.purpose
        modifierMode = assignment.mode
        detector = ModifierHotkeyDetector(
            required: assignment.binding.modifiers,
            mode: assignment.mode
        )

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
        guard var detector, let purpose = modifierPurpose else { return }
        let input: ModifierHotkeyDetector.Input =
            event.type == .flagsChanged
            ? .flagsChanged(HotkeyFormatting.carbonModifiers(from: event.modifierFlags))
            : .keyDown

        let output = detector.handle(input)
        self.detector = detector
        syncKeyDownMonitors(holding: detector.isHolding)

        switch output {
        case .press: onPress(purpose)
        case .release: onRelease(purpose)
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
        let wanted = holding && modifierMode == .toggle
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

    /// One handler serves every hot key in the process, so the identifier is what
    /// says which of ours fired — and whether it is one of ours at all.
    fileprivate func handle(eventKind: UInt32, identifier: UInt32) {
        guard let registration = carbon[identifier] else { return }

        switch registration.mode {
        case .toggle:
            // Only key-down toggles; the release is meaningless in this mode.
            if eventKind == UInt32(kEventHotKeyPressed) { onPress(registration.purpose) }
        case .pushToTalk:
            if eventKind == UInt32(kEventHotKeyPressed) {
                onPress(registration.purpose)
            } else if eventKind == UInt32(kEventHotKeyReleased) {
                onRelease(registration.purpose)
            }
        }
    }
}

/// Carbon hands us a bare C function, so the monitor travels through `userData`.
private let hotkeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let identifier = hotKeyID.id

    // The dispatcher target is the main event loop, so this already runs on the main
    // thread; the fallback keeps ordering intact if that ever stops being true.
    if Thread.isMainThread {
        MainActor.assumeIsolated { monitor.handle(eventKind: kind, identifier: identifier) }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { monitor.handle(eventKind: kind, identifier: identifier) }
        }
    }
    return noErr
}

import AppKit
import Foundation
import Observation
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform
import os

/// Which Settings tab is showing.
///
/// Shared through `AppEnvironment` so the HUD and the onboarding window can jump
/// straight to the tab that fixes whatever the user is looking at.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case transcription
    case formatting
    case ask
    case readAloud
    case apiKeys
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .transcription: return "音声認識"
        case .formatting: return "整形"
        case .ask: return "質問"
        case .readAloud: return "読み上げ"
        case .apiKeys: return "API キー"
        case .permissions: return "権限"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .formatting: return "text.badge.checkmark"
        case .ask: return "questionmark.bubble"
        case .readAloud: return "speaker.wave.2"
        case .apiKeys: return "key"
        case .permissions: return "lock.shield"
        }
    }
}

/// Composition root: builds every dependency once and wires the parts that have
/// to react to each other (hotkey ⇄ settings, sound ⇄ settings, login item ⇄
/// settings, HUD ⇄ state).
///
/// Construction is side-effect free so previews can build one; everything that
/// touches the system lives in `start()`.
@MainActor
@Observable
final class AppEnvironment {
    /// The one instance the running app uses. Created lazily on first access,
    /// which always happens on the main actor (`App.body` / the app delegate).
    static let shared = AppEnvironment.live()

    // MARK: Dependencies

    let coordinator: DictationCoordinator
    /// The read-aloud pipeline. Independent of `coordinator`: it starts at a
    /// selection, not at the microphone, and the two never run through each other.
    let narration: NarrationCoordinator
    let permissions: PermissionsService
    let engines: any TranscriptionEngineResolving
    let providers: LLMProviderRegistry
    let secrets: any SecretStore
    let output: any OutputSink

    // MARK: Screen-scoped view models

    let engineAvailability: EngineAvailabilityModel
    let apiKeys: APIKeysModel
    let formattingTrial: FormattingTrialModel

    // MARK: Observable UI state

    /// Non-nil while the configured shortcut could not be claimed.
    var hotkeyError: String?
    /// Per-style shortcut problems (duplicate combination, already taken by
    /// another app), keyed by style id and shown next to that style in Settings.
    var styleHotkeyIssues: [UUID: String] = [:]
    /// Non-nil while the configured question shortcut could not be claimed.
    var askHotkeyIssue: String?
    /// Non-nil while the configured read-aloud shortcut could not be claimed.
    var readAloudHotkeyIssue: String?
    var readAloudClipboardHotkeyIssue: String?
    /// Non-nil when launch-at-login needs the user to do something.
    var loginItemNotice: String?
    /// The app that was frontmost when recording started, e.g. "Slack".
    private(set) var frontmostAppName: String?
    var settingsTab: SettingsTab = .general

    // MARK: Private

    @ObservationIgnored private let sound: SoundFeedback
    /// Held so the voice and language can be re-pointed when Settings changes,
    /// without rebuilding the coordinator that drives it.
    @ObservationIgnored private let speech: SystemSpeechSynthesizer
    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private var hudStorage: HUDWindowController?
    @ObservationIgnored private var welcomeWindow: WelcomeWindowController?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private static let log = Logger(subsystem: "io.github.voiceinput", category: "hotkey")

    init(
        coordinator: DictationCoordinator,
        narration: NarrationCoordinator,
        permissions: PermissionsService,
        engines: any TranscriptionEngineResolving,
        providers: LLMProviderRegistry,
        secrets: any SecretStore,
        output: any OutputSink,
        sound: SoundFeedback,
        speech: SystemSpeechSynthesizer
    ) {
        self.coordinator = coordinator
        self.narration = narration
        self.permissions = permissions
        self.engines = engines
        self.providers = providers
        self.secrets = secrets
        self.output = output
        self.sound = sound
        self.speech = speech
        self.engineAvailability = EngineAvailabilityModel(engines: engines)
        self.apiKeys = APIKeysModel(secrets: secrets, providers: providers)
        self.formattingTrial = FormattingTrialModel(providers: providers, secrets: secrets)

        // Core cannot reach TCC or NSWorkspace, so the app supplies both hooks.
        // Without the preflight a first dictation would fail instead of prompting.
        coordinator.preflight = { [weak permissions] in
            try await permissions?.requireDictationPermissions()
        }
        coordinator.frontmostAppNameProvider = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
        // Always injected; the coordinator only calls it when the user has turned
        // screen context on, so wiring it costs nothing while the feature is off.
        coordinator.screenContextProvider = ScreenCaptureContextProvider(
            locale: coordinator.settings.locale
        )
    }

    /// The production graph: Keychain, `UserDefaults`, real microphone, real
    /// engines, real pasteboard.
    static func live() -> AppEnvironment {
        let secrets = KeychainSecretStore()
        let settingsStore = UserDefaultsSettingsStore()
        let engines = PlatformEngineRegistry(secrets: secrets)
        let providers = LLMProviderRegistry.live()
        let output = PasteboardOutputSink()
        let sound = SoundFeedback(isEnabled: settingsStore.load().playSounds)
        let coordinator = DictationCoordinator(
            audio: MicrophoneCapture(),
            engines: engines,
            providers: providers,
            settingsStore: settingsStore,
            secrets: secrets,
            output: output,
            feedback: sound
        )
        let settings = coordinator.settings
        let speech = SystemSpeechSynthesizer(
            localeIdentifier: settings.localeIdentifier,
            voiceIdentifier: settings.readAloudSettings.voiceIdentifier
        )
        // The settings are read through the coordinator rather than copied, so a
        // rate or voice edited in Settings applies to the next reading and there is
        // still exactly one writer to the store.
        let narration = NarrationCoordinator(
            sources: [
                .selection: SelectedTextReader(),
                .clipboard: ClipboardTextReader(),
            ],
            synthesizer: speech,
            providers: providers,
            secrets: secrets,
            settings: { coordinator.settings }
        )
        return AppEnvironment(
            coordinator: coordinator,
            narration: narration,
            permissions: PermissionsService(),
            engines: engines,
            providers: providers,
            secrets: secrets,
            output: output,
            sound: sound,
            speech: speech
        )
    }

    // MARK: - Settings passthrough

    /// Assigning persists: `DictationCoordinator.settings` writes through to the
    /// settings store.
    var settings: AppSettings {
        get { coordinator.settings }
        set { coordinator.settings = newValue }
    }

    // MARK: - Lifecycle

    /// Everything that touches the system. Called once from the app delegate.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Menu-bar-only. `LSUIElement` already does this for the bundled app; the
        // call keeps an unbundled `swift run` from putting an icon in the Dock.
        NSApp.setActivationPolicy(.accessory)

        applyHotkey(force: true)
        applySoundSetting()
        applyLoginItem()
        observeSettings()
        observeState()
        observeActivation()
        showWelcomeWindowIfNeeded()
    }

    /// Re-registers the hotkey whenever the app comes back to the foreground.
    ///
    /// macOS posts no notification when an Accessibility grant changes, so an app
    /// that failed to register a modifier-only shortcut would stay broken until the
    /// user found the 再試行 button. Returning from System Settings is the moment
    /// worth re-checking.
    private func observeActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hotkeyError != nil else { return }
                self.reapplyHotkey()
            }
        }
    }

    // MARK: - Commands used by the UI

    func toggleDictation() {
        rememberFrontmostApp()
        coordinator.toggle()
    }

    /// Records a question instead of a dictation. Pressed while a dictation is
    /// already running it converts that recording into a question — see
    /// `DictationCoordinator.toggle`.
    func toggleAsk() {
        rememberFrontmostApp()
        coordinator.toggle(action: .ask)
    }

    /// Reads the current selection aloud, or controls the reading in flight: the
    /// same press pauses, resumes, and cancels a reading that has not started
    /// speaking yet. See `NarrationCoordinator.toggle`.
    func toggleReadAloud(source: NarrationSourceID = .selection) {
        narration.toggle(source: source)
    }

    func stopReadAloud() {
        narration.stop()
    }

    /// `nil` when no read-aloud shortcut is configured — the feature is opt-in, and
    /// the menu says so rather than showing an empty key.
    var readAloudHotkeyLabel: String? {
        settings.readAloudHotkey.map(HotkeyFormatting.displayString(for:))
    }

    /// `nil` when no clipboard shortcut is configured. The menu item works either
    /// way; only the key hint disappears.
    var readAloudClipboardHotkeyLabel: String? {
        settings.readAloudClipboardHotkey.map(HotkeyFormatting.displayString(for:))
    }

    /// Switches the style of the dictation in flight (from the HUD). One-off: the
    /// default style in Settings and the menu is untouched.
    func selectStyle(_ id: UUID) {
        coordinator.selectStyle(id)
    }

    func copyToPasteboard(_ text: String) {
        try? output.copy(text)
    }

    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        SettingsWindowOpener.open()
    }

    var hotkeyLabel: String {
        HotkeyFormatting.displayString(for: settings.hotkey)
    }

    /// `nil` when no question shortcut is configured — the feature is opt-in, and
    /// the menu says so rather than showing an empty key.
    var askHotkeyLabel: String? {
        settings.askHotkey.map(HotkeyFormatting.displayString(for:))
    }

    // MARK: - Observation

    /// `withObservationTracking` fires once per change, so every handler re-arms
    /// itself. The work is deferred to a task because `onChange` runs *before* the
    /// new value is in place.
    private func observeSettings() {
        withObservationTracking {
            let settings = coordinator.settings
            _ = settings.hotkey
            _ = settings.hotkeyMode
            _ = settings.askHotkey
            _ = settings.readAloud
            // Styles carry shortcuts of their own, so editing one can change what
            // has to be registered. `applyHotkey` compares the resulting plan, so
            // typing a prompt does not churn the registrations.
            _ = settings.styles
            _ = settings.playSounds
            _ = settings.launchAtLogin
            // The OCR provider is built around a locale, so it is rebuilt when
            // the dictation language changes.
            _ = settings.localeIdentifier
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyHotkey()
                self.applySoundSetting()
                self.applyLoginItem()
                self.applyScreenContextProvider()
                self.applyNarrationVoice()
                self.observeSettings()
            }
        }
    }

    /// Re-points the synthesiser when the language or the chosen voice changes. The
    /// voice is resolved per utterance, so this takes effect from the next chunk.
    private func applyNarrationVoice() {
        speech.localeIdentifier = settings.localeIdentifier
        speech.voiceIdentifier = settings.readAloudSettings.voiceIdentifier
    }

    private func applyScreenContextProvider() {
        coordinator.screenContextProvider = ScreenCaptureContextProvider(
            locale: coordinator.settings.locale
        )
    }

    /// Turning the setting on is the consent moment, so this is the only place
    /// that asks for the screen-recording permission.
    func setScreenContextEnabled(_ isEnabled: Bool) {
        coordinator.settings.screenContextEnabled = isEnabled
        guard isEnabled, permissions.screenRecording != .granted else { return }
        permissions.promptForScreenRecording()
    }

    private func observeState() {
        hud.update(for: coordinator.state)
        withObservationTracking {
            _ = coordinator.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hud.update(for: self.coordinator.state)
                self.observeState()
            }
        }
    }

    // MARK: - Hotkey

    private func applyHotkey(force: Bool = false) {
        let plan = HotkeyPlan.make(for: settings)

        // Re-register only when the set of shortcuts actually changed: editing a
        // style's name or prompt must not tear the registrations down on every
        // keystroke. A lingering failure still retries, because the usual cause is
        // an Accessibility grant that may have arrived since.
        if force || hotkeys.assignments != plan.assignments || hotkeyError != nil {
            hotkeys.register(
                plan.assignments,
                onPress: { [weak self] purpose in
                    // Carbon dispatches on the main thread; see `HotkeyMonitor`.
                    MainActor.assumeIsolated { self?.handleHotkeyPress(purpose) }
                },
                onRelease: { [weak self] purpose in
                    MainActor.assumeIsolated { self?.handleHotkeyRelease(purpose) }
                }
            )
            hotkeyError = hotkeys.failures[.dictation].map {
                message(for: $0, binding: settings.hotkey)
            }

            // Purpose names and error kinds only — never a key code, never content.
            // A shortcut that silently does nothing is undiagnosable otherwise.
            let requested = plan.assignments.map(\.purpose.logName).sorted()
            let failed = hotkeys.failures
                .map { "\($0.key.logName):\($0.value.logKind)" }
                .sorted()
            Self.log.notice(
                """
                registered: requested=[\(requested.joined(separator: " "), privacy: .public)] \
                failed=[\(failed.joined(separator: " "), privacy: .public)] \
                axTrusted=\(AXIsProcessTrusted(), privacy: .public)
                """
            )
        }

        // A style shortcut rejected before registration (a duplicate) and one Carbon
        // refused (already owned by another app) are the same problem to the user:
        // it is configured, and it will not fire. Recomputed even when nothing was
        // re-registered, because adding a duplicate changes only the rejections.
        var issues = plan.rejections.mapValues(\.message)
        for (purpose, error) in hotkeys.failures {
            guard let styleID = purpose.styleID else { continue }
            issues[styleID] =
                error.errorDescription ?? "ショートカットキーを登録できませんでした。"
        }
        styleHotkeyIssues = issues

        askHotkeyIssue =
            plan.askRejection?.message(subject: "質問のショートカット")
            ?? hotkeys.failures[.ask].map {
                $0.errorDescription ?? "ショートカットキーを登録できませんでした。"
            }

        readAloudHotkeyIssue =
            plan.readAloudRejection?.message(subject: "読み上げのショートカット")
            ?? hotkeys.failures[.readAloud].map {
                $0.errorDescription ?? "ショートカットキーを登録できませんでした。"
            }

        readAloudClipboardHotkeyIssue =
            plan.readAloudClipboardRejection?.message(
                subject: "クリップボード読み上げのショートカット"
            )
            ?? hotkeys.failures[.readAloudClipboard].map {
                $0.errorDescription ?? "ショートカットキーを登録できませんでした。"
            }
    }

    private func message(for error: HotkeyError, binding: HotkeyBinding) -> String {
        let label = HotkeyFormatting.displayString(for: binding)
        let reason = error.errorDescription ?? "ショートカットキーを登録できませんでした。"
        return ["ショートカット \(label): \(reason)", error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Re-runs registration for the current binding.
    ///
    /// A modifier-only shortcut fails until Accessibility is granted, and macOS
    /// gives no callback when that happens — Settings calls this after the user
    /// comes back from System Settings.
    func reapplyHotkey() {
        applyHotkey(force: true)
    }

    /// A style shortcut means "dictate with this style, just this once", and the
    /// question shortcut means "this one is a question". Pressed while a recording is
    /// already running, either switches that recording instead of starting or
    /// stopping one — see `DictationCoordinator.toggle`.
    private func handleHotkeyPress(_ purpose: HotkeyPurpose) {
        Self.log.notice(
            """
            pressed: purpose=\(purpose.logName, privacy: .public) \
            action=\(purpose.actionID?.rawValue ?? "-", privacy: .public) \
            mode=\(self.settings.hotkeyMode.rawValue, privacy: .public)
            """
        )
        // A purpose with no dictation action is not a recording at all. Read-aloud
        // is the only one today, and it must not touch the capture path.
        if let source = purpose.narrationSource {
            narration.toggle(source: source)
            return
        }
        guard let actionID = purpose.actionID else { return }
        rememberFrontmostApp()
        switch settings.hotkeyMode {
        case .toggle:
            coordinator.toggle(action: actionID, styleID: purpose.styleID)
        case .pushToTalk:
            if coordinator.isCapturing {
                coordinator.selectAction(actionID)
                if let styleID = purpose.styleID { coordinator.selectStyle(styleID) }
            } else {
                coordinator.start(action: actionID, styleID: purpose.styleID)
            }
        }
    }

    private func handleHotkeyRelease(_ purpose: HotkeyPurpose) {
        // Read-aloud is registered as a toggle, so a release means nothing to it.
        guard purpose.actionID != nil, settings.hotkeyMode == .pushToTalk else { return }
        coordinator.stopAndProcess()
    }

    /// Mirrors what `coordinator.frontmostAppNameProvider` captures, so the HUD can
    /// show "Slack に貼り付け" without reaching into the coordinator's context.
    private func rememberFrontmostApp() {
        frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Sound / login item

    private func applySoundSetting() {
        sound.isEnabled = settings.playSounds
    }

    private func applyLoginItem() {
        let wanted = settings.launchAtLogin
        if case .unsupported(let reason) = LoginItem.status {
            // Keep the user's preference stored — it starts working as soon as the
            // app runs from a proper .app bundle.
            loginItemNotice = wanted ? "ログイン時の起動を設定できません: \(reason)" : nil
            return
        }
        do {
            try LoginItem.setEnabled(wanted)
            if wanted, LoginItem.status == .requiresApproval {
                loginItemNotice = "システム設定 → 一般 → ログイン項目 で VoiceInput を許可してください。"
            } else {
                loginItemNotice = nil
            }
        } catch {
            loginItemNotice = error.localizedDescription
        }
    }

    // MARK: - Windows

    private var hud: HUDWindowController {
        if let hudStorage { return hudStorage }
        let controller = HUDWindowController(environment: self)
        hudStorage = controller
        return controller
    }

    /// First-launch flag. Deliberately *not* part of `AppSettings`: it is a
    /// one-shot UI fact, not a user preference worth exporting or syncing.
    enum Onboarding {
        static let defaultsKey = "io.github.voiceinput.hasCompletedOnboarding"

        static var isCompleted: Bool {
            get { UserDefaults.standard.bool(forKey: defaultsKey) }
            set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
        }
    }

    func showWelcomeWindowIfNeeded() {
        guard !Onboarding.isCompleted else { return }
        showWelcomeWindow()
    }

    func showWelcomeWindow() {
        let controller = welcomeWindow ?? WelcomeWindowController(environment: self)
        welcomeWindow = controller
        controller.show()
    }

    func finishOnboarding() {
        Onboarding.isCompleted = true
        welcomeWindow?.close()
    }
}

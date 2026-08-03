import AppKit
import Foundation
import Observation
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// Which Settings tab is showing.
///
/// Shared through `AppEnvironment` so the HUD and the onboarding window can jump
/// straight to the tab that fixes whatever the user is looking at.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case transcription
    case formatting
    case apiKeys
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .transcription: return "音声認識"
        case .formatting: return "整形"
        case .apiKeys: return "API キー"
        case .permissions: return "権限"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .formatting: return "text.badge.checkmark"
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
    /// Non-nil when launch-at-login needs the user to do something.
    var loginItemNotice: String?
    /// The app that was frontmost when recording started, e.g. "Slack".
    private(set) var frontmostAppName: String?
    var settingsTab: SettingsTab = .general

    // MARK: Private

    @ObservationIgnored private let sound: SoundFeedback
    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private var registeredMode: HotkeyMode?
    @ObservationIgnored private var hudStorage: HUDWindowController?
    @ObservationIgnored private var welcomeWindow: WelcomeWindowController?
    @ObservationIgnored private var isStarted = false

    init(
        coordinator: DictationCoordinator,
        permissions: PermissionsService,
        engines: any TranscriptionEngineResolving,
        providers: LLMProviderRegistry,
        secrets: any SecretStore,
        output: any OutputSink,
        sound: SoundFeedback
    ) {
        self.coordinator = coordinator
        self.permissions = permissions
        self.engines = engines
        self.providers = providers
        self.secrets = secrets
        self.output = output
        self.sound = sound
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
        return AppEnvironment(
            coordinator: coordinator,
            permissions: PermissionsService(),
            engines: engines,
            providers: providers,
            secrets: secrets,
            output: output,
            sound: sound
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
        showWelcomeWindowIfNeeded()
    }

    // MARK: - Commands used by the UI

    func toggleDictation() {
        rememberFrontmostApp()
        coordinator.toggle()
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

    // MARK: - Observation

    /// `withObservationTracking` fires once per change, so every handler re-arms
    /// itself. The work is deferred to a task because `onChange` runs *before* the
    /// new value is in place.
    private func observeSettings() {
        withObservationTracking {
            let settings = coordinator.settings
            _ = settings.hotkey
            _ = settings.hotkeyMode
            _ = settings.playSounds
            _ = settings.launchAtLogin
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyHotkey()
                self.applySoundSetting()
                self.applyLoginItem()
                self.observeSettings()
            }
        }
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
        let binding = settings.hotkey
        let mode = settings.hotkeyMode
        let unchanged = hotkeys.currentBinding == binding && registeredMode == mode
        guard force || !unchanged || hotkeyError != nil else { return }

        do {
            try hotkeys.register(
                binding,
                mode: mode,
                onPress: { [weak self] in
                    // Carbon dispatches on the main thread; see `HotkeyMonitor`.
                    MainActor.assumeIsolated { self?.handleHotkeyPress() }
                },
                onRelease: { [weak self] in
                    MainActor.assumeIsolated { self?.handleHotkeyRelease() }
                }
            )
            registeredMode = mode
            hotkeyError = nil
        } catch {
            registeredMode = nil
            hotkeyError = """
                ショートカット \(HotkeyFormatting.displayString(for: binding)) を登録できませんでした。\
                他のアプリが使用中の可能性があります。別のキーを設定してください。
                """
        }
    }

    private func handleHotkeyPress() {
        rememberFrontmostApp()
        switch settings.hotkeyMode {
        case .toggle: coordinator.toggle()
        case .pushToTalk: coordinator.start()
        }
    }

    private func handleHotkeyRelease() {
        guard settings.hotkeyMode == .pushToTalk else { return }
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

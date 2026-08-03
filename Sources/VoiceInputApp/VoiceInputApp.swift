import AppKit
import SwiftUI
import VoiceInputCore

/// Menu-bar-only dictation app.
///
/// `MenuBarExtra` uses the **`.menu` style** on purpose: everything in the menu is
/// a `Text` / `Button` / `Toggle` / `Picker` / submenu, all of which the AppKit
/// menu backend renders natively. That keeps the menu instant, keyboard
/// navigable, and — crucially for a dictation tool — it does **not** activate the
/// app, so opening the menu never moves focus away from the app the user is about
/// to paste into. Anything richer (level meter, prompt editor) lives in the HUD or
/// in Settings, not here.
@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(AppEnvironment.shared)
        } label: {
            // A dedicated View, so the @Observable read happens inside a view body
            // and the icon actually re-renders as the state machine moves.
            MenuBarIcon(coordinator: AppEnvironment.shared.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRootView()
                .environment(AppEnvironment.shared)
        }
    }
}

/// The menu-bar icon, reflecting the current pipeline state.
struct MenuBarIcon: View {
    let coordinator: DictationCoordinator

    var body: some View {
        let state = coordinator.state
        Image(systemName: state.menuBarSymbol)
            .symbolRenderingMode(.hierarchical)
            // Ignored when the status item renders the label as a flat image, which
            // is why the symbol itself already differs per state.
            .symbolEffect(
                .variableColor.iterative,
                options: .repeating,
                isActive: isProcessing(state)
            )
            .accessibilityLabel(state.accessibilityStatus)
    }

    private func isProcessing(_ state: DictationState) -> Bool {
        switch state {
        case .transcribing, .formatting: return true
        default: return false
        }
    }
}

/// Owns launch-time wiring. `App` has no "did finish launching" hook, and the
/// `MenuBarExtra` content is only built when the user opens the menu, so the
/// hotkey and the HUD have to be started from here.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppEnvironment.shared.start()
    }
}

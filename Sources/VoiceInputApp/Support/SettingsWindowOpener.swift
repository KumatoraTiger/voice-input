import AppKit
import SwiftUI

/// Opens the `Settings` scene from code.
///
/// SwiftUI's `SettingsLink` is the reliable route and is what the menu uses, but a
/// `SettingsLink` is a *View* — the HUD is hosted in AppKit and the onboarding
/// window needs to jump to a specific tab, so those two fall back to the AppKit
/// action. macOS 14 renamed the selector from `showPreferencesWindow:` to
/// `showSettingsWindow:`; both are tried, newest first.
enum SettingsWindowOpener {
    @MainActor
    static func open() {
        // An `LSUIElement` app is not active when the hotkey fires, so without this
        // the Settings window opens behind whatever the user was working in.
        NSApp.activate()
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

/// Brings the window it is attached to to the front when it appears.
///
/// `Settings` windows opened while the app is in the background (menu bar, HUD)
/// otherwise show up behind the frontmost app.
struct WindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ActivatingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ActivatingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Deferred: the window is not yet on screen inside this callback.
            DispatchQueue.main.async {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

extension String {
    /// Middle-free truncation used for menu items and the HUD: keeps the head and
    /// appends an ellipsis, on one line.
    func truncated(to limit: Int) -> String {
        let flattened = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// Keeps the *tail*, which is what matters for a transcript still being spoken.
    func truncatedFromStart(to limit: Int) -> String {
        let flattened = replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return "…" + String(flattened.suffix(limit))
    }
}

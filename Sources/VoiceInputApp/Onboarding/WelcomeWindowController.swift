import AppKit
import SwiftUI

/// Hosts `WelcomeView` in a plain window.
///
/// Built in AppKit rather than as a SwiftUI `Window` scene because a menu-bar-only
/// app has no scene that runs at launch: `MenuBarExtra` content is only built when
/// the user opens the menu, so a scene-based first-run window would never appear.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let root = WelcomeView(onFinish: { [weak self] startDictation in
            guard let self else { return }
            self.environment.finishOnboarding()
            if startDictation {
                self.environment.toggleDictation()
            }
        })
        .environment(environment)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput へようこそ"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        return window
    }

    // Closing the window with the red button counts as "later", not as a
    // never-ending prompt: the flag is set so it does not come back every launch.
    func windowWillClose(_ notification: Notification) {
        AppEnvironment.Onboarding.isCompleted = true
    }
}

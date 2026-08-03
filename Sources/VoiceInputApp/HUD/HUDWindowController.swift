import AppKit
import ApplicationServices
import SwiftUI
import VoiceInputCore
import VoiceInputPlatform

/// Hosts `RecordingHUD` in a floating panel that never takes focus.
///
/// Focus is the whole point: auto-paste synthesises ⌘V into whatever app is
/// frontmost, so a HUD that became key would make the app paste into itself.
@MainActor
final class HUDWindowController {
    private let environment: AppEnvironment
    private var panel: NSPanel?
    private var isShowing = false
    /// The user closed the current failure; do not pop the HUD back up for it.
    /// Reset as soon as the pipeline leaves `.failed`.
    private var failureDismissed = false
    private var escapeMonitors: [Any] = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - State driven show / hide

    func update(for state: DictationState) {
        switch state {
        case .idle:
            failureDismissed = false
            hide()
        case .failed:
            if failureDismissed { hide() } else { show() }
        case .preparing, .recording, .transcribing, .formatting, .finished:
            failureDismissed = false
            show()
        }
    }

    // MARK: - Window

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        layout(panel)
        // SwiftUI re-lays out on the next display cycle, so the size that matches
        // the new phase (a failure box is taller) is only known one tick later.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing || self.panel === panel else { return }
            self.layout(panel)
        }
        installEscapeMonitors()

        guard !isShowing else { return }
        isShowing = true
        panel.alphaValue = 0
        // `orderFrontRegardless` shows the panel without activating the app.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        removeEscapeMonitors()
        guard isShowing, let panel else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A new dictation may have started during the fade.
            guard let self, !self.isShowing else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        let hosting = FirstMouseHostingView(rootView: makeRootView())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func makeRootView() -> HUDHostView {
        HUDHostView(
            environment: environment,
            onCancel: { [weak self] in self?.environment.coordinator.cancel() },
            onDismiss: { [weak self] in
                self?.failureDismissed = true
                self?.hide()
            }
        )
    }

    /// Sizes the panel to its content and parks it at the bottom centre of the
    /// screen the mouse is on: close to where the user is looking, and out of the
    /// way of the field being dictated into.
    private func layout(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let fitting = panel.contentView?.fittingSize ?? panel.frame.size
        let width = max(fitting.width, 360)
        let height = max(fitting.height, 90)
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.minY + 120))
    }

    // MARK: - Esc to cancel

    /// The panel never becomes key, so Esc has to come from an event monitor.
    /// The local monitor covers "our own Settings window is frontmost"; the global
    /// one needs Accessibility trust and is only installed when we already have it.
    private func installEscapeMonitors() {
        guard escapeMonitors.isEmpty else { return }

        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: {
                [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { self?.handleEscape() }
                return nil
            })
        {
            escapeMonitors.append(local)
        }

        guard AXIsProcessTrusted() else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: {
                [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.handleEscape() }
            })
        {
            escapeMonitors.append(global)
        }
    }

    private func removeEscapeMonitors() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors.removeAll()
    }

    private func handleEscape() {
        if environment.coordinator.state.isBusy {
            environment.coordinator.cancel()
        } else {
            failureDismissed = true
            hide()
        }
    }
}

/// `NSPanel` that refuses key and main status under all circumstances.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that lets a click land on the control it hit.
///
/// The panel is deliberately never key, and by default AppKit swallows the first
/// click into an inactive window. Without this, picking a style in the HUD would
/// take two clicks — and the first would look like it did nothing.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The live wrapper around `RecordingHUD`: reads the observable coordinator and
/// hands plain values down.
private struct HUDHostView: View {
    let environment: AppEnvironment
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let coordinator = environment.coordinator
        if let phase = HUDPhase(state: coordinator.state) {
            RecordingHUD(
                phase: phase,
                mode: DictationMode(action: coordinator.currentAction),
                partialText: coordinator.partialText,
                level: coordinator.inputLevel,
                frontmostAppName: environment.frontmostAppName,
                styles: styleOptions,
                selectedStyleID: coordinator.effectiveStyleID,
                onSelectStyle: { environment.selectStyle($0) },
                showsEscapeHint: AXIsProcessTrusted() || NSApp.isActive,
                onCancel: onCancel,
                onDismiss: onDismiss,
                onOpenSettings: { tab in
                    onDismiss()
                    environment.openSettings(tab: tab)
                },
                onOpenPrivacyPane: { pane in
                    environment.permissions.openSettings(for: pane)
                }
            )
            .transition(.opacity)
        }
    }

    /// Nothing to choose between when the LLM is not going to run.
    private var styleOptions: [HUDStyleOption] {
        guard environment.settings.formattingEnabled else { return [] }
        return environment.settings.styles.map(HUDStyleOption.init(style:))
    }
}

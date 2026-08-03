import SwiftUI

/// The `Settings` scene: one tab per concern.
struct SettingsRootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        TabView(selection: $environment.settingsTab) {
            GeneralSettingsView()
                .settingsTabItem(.general)
            TranscriptionSettingsView()
                .settingsTabItem(.transcription)
            FormattingSettingsView()
                .settingsTabItem(.formatting)
            AskSettingsView()
                .settingsTabItem(.ask)
            APIKeysSettingsView()
                .settingsTabItem(.apiKeys)
            PermissionsSettingsView()
                .settingsTabItem(.permissions)
        }
        .frame(width: 560, height: 460)
        // An accessory app is not frontmost when the menu opens Settings, so the
        // window has to pull itself forward.
        .background(WindowActivator().frame(width: 0, height: 0))
    }
}

extension View {
    fileprivate func settingsTabItem(_ tab: SettingsTab) -> some View {
        tabItem { Label(tab.title, systemImage: tab.symbol) }
            .tag(tab)
    }
}

/// Shared layout for a settings pane: a scrollable grouped form.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#if DEBUG
struct SettingsRootView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsRootView()
            .environment(AppEnvironment.previewEnvironment())
    }
}
#endif

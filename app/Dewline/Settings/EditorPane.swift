import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore
    @Bindable var preferences: Preferences = .shared

    var body: some View {
        SettingsForm(restore: { Self.restore(store, preferences) }) {
            Section {
                Toggle(isOn: $preferences.linkPreviews) {
                    Text("Link previews")
                    Text("Fetches a page's title and picture when a link is shown.")
                }
                Toggle("Vim mode", isOn: $store.vimMode)
            }
            Section("Typing") {
                Picker("Tab key inserts", selection: $store.tabWidth) {
                    Text("A tab").tag(0)
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                }
                Toggle("Check spelling as you type", isOn: $store.spellCheck)
            }
        }
    }

    /// Puts this pane's settings, and no others, back as a fresh install has them.
    static func restore(_ store: ThemeStore, _ preferences: Preferences) {
        let factory = ThemeStore.factory
        store.vimMode = factory.vimMode
        store.tabWidth = factory.tabWidth
        store.spellCheck = factory.spellCheck
        preferences.linkPreviews = Preferences.factory.linkPreviews
    }
}

import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore
    @Bindable var preferences: Preferences = .shared

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow(label: "Link previews", detail: "Fetches a page's title and picture when a link is shown.") {
                    OnOff(label: "Link previews", isOn: $preferences.linkPreviews)
                }
                SettingsRow(label: "Vim mode") {
                    OnOff(label: "Vim mode", isOn: $store.vimMode)
                }
                SettingsRow(label: "Open code files", detail: "Source and config files open as highlighted code, with line numbers.") {
                    OnOff(label: "Open code files", isOn: $preferences.opensCodeFiles)
                }
            }
            SettingsSection(title: "Typing") {
                SettingsRow(label: "Tab key inserts") {
                    TextChoice(label: "Tab key inserts", selection: $store.tabWidth, options: [("A tab", 0), ("2 spaces", 2), ("4 spaces", 4)])
                }
                SettingsRow(label: "Check spelling as you type") {
                    OnOff(label: "Check spelling as you type", isOn: $store.spellCheck)
                }
            }
            RestoreDefaults {
                let factory = ThemeStore.factory
                store.vimMode = factory.vimMode
                store.tabWidth = factory.tabWidth
                store.spellCheck = factory.spellCheck
                preferences.linkPreviews = Preferences.factory.linkPreviews
                preferences.opensCodeFiles = Preferences.factory.opensCodeFiles
            }
        }
    }
}

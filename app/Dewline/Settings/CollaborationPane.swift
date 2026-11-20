import SwiftUI

#if COLLAB
struct CollaborationPane: View {
    @Bindable var preferences: Preferences
    let store: ThemeStore

    var body: some View {
        SettingsForm(restore: {
            let factory = Preferences.factory
            preferences.collaborationName = factory.collaborationName
            preferences.sharedFolder = factory.sharedFolder
        }) {
            Section {
                TextField(text: $preferences.collaborationName) {
                    Text("Your name")
                    Text("People you share with see it on your caret.")
                }
                LabeledContent {
                    FolderField(url: preferences.sharedFolder) { preferences.sharedFolder = $0 }
                } label: {
                    Text("Shared notes go in")
                    Text("Your copy stays here after sharing ends.")
                }
            }
        }
    }
}
#endif

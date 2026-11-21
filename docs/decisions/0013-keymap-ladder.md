# 0013: Keymap ladder and Quick Open on ⌘P

Date: 2026-11-21. The owner delegated these to engineering on 21 Nov 2026.

**The rule.** The base key acts on one change. Adding Shift acts on the whole note, adding Control on the whole session. Revert always carries Option.

| Decision | Choice | Reopens if |
|---|---|---|
| Keep | ⌘↩ change, ⇧⌘↩ note, ⌃⌘↩ session (was ⌥⇧⌘↩) | |
| Revert | ⌥⌘⌫ change, ⌥⇧⌘⌫ note, ⌃⌥⌘⌫ session (was ⌃⌘⌫) | VoiceOver users report the session revert as unreachable |
| Quick Open | ⌘P, as in VS Code, Zed, Cursor and Sublime Text; ⇧⌘O is dropped, since nothing else used it | |
| Print | ⌥⌘P | people miss ⌘P for Print |

**Conflicts checked.** None of the new keys is on another menu item or in Apple's "Mac keyboard shortcuts" list. ⌥⌘P shows the path bar in Finder only. Print leaves the Mac's usual ⌘P, the price of putting Quick Open where code editors keep it. ⌃⌥⌘⌫ holds VoiceOver's VO keys (⌃⌥), so VoiceOver takes it while it runs; VoiceOver has no VO-Command-Delete command, and VO-Tab passes the next key to the app. It is the one ⌃⌥ shortcut `MainMenuTests` allows. Edit > Revert Session and the Changes list's Revert Session button stay reachable under VoiceOver.

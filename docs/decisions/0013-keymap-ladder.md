# 0013: Keymap ladder and Quick Open on ⌘P

Date: 2026-11-21. The owner delegated these to engineering on 21 Nov 2026.

**The rule.** Return keeps, Delete reverts. Plain ⌘ acts on one change, adding ⇧ on the whole note, ⌃ in place of it on the whole session. Change- and note-level Revert carry ⌥, because ⌘⌫ deletes to the line start in text. The session level needs no ⌥, since ⌃⌘⌫ is free, and ⌃⌥ is avoided because it is VoiceOver's VO key.

| Decision | Choice | Reopens if |
|---|---|---|
| Keep | ⌘↩ change, ⇧⌘↩ note, ⌃⌘↩ session (was ⌥⇧⌘↩) | |
| Revert | ⌥⌘⌫ change, ⌥⇧⌘⌫ note, ⌃⌘⌫ session (unchanged) | |
| Quick Open | ⌘P, as in VS Code, Zed, Cursor and Sublime Text; ⇧⌘O is dropped, since nothing else used it | |
| Print | ⌥⌘P | people miss ⌘P for Print |

**Conflicts checked.** None of the new keys is on another menu item, in Apple's "Mac keyboard shortcuts" list or on VoiceOver's ⌃⌥. ⌥⌘P shows the path bar in Finder only. Print gives up the Mac's usual ⌘P so Quick Open can sit where code editors keep it.

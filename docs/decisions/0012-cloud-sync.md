# 0012: Dewline Sync

Date: 2026-11-19. The owner approved the sync plan on 19 Nov 2026. The pairing and key protocol is final only after the outside review below; private beta waits on it.

| Decision | Choice | Reopens if |
|---|---|---|
| Model | File-level store-and-forward. Whole files go up as encrypted blobs; the server keeps each file's version chain and its head. No CRDT: agents write whole files, and a diff of a whole-file rewrite into ops merges badly with concurrent edits. Loro stays for live co-editing ([0009](0009-collaboration.md)). | beta shows most conflicts are concurrent typing in one note |
| Merge base | The sync record: the client's own fsynced SQLite table of the last version of each file this Mac synced. Not the engine's seen/ versions, which Dewline's own saves move, which exist only for Markdown, and which are written without fsync. No base means a two-way conflict, never an automatic merge. | |
| Service | Cloudflare: a Worker, one Durable Object per account holding heads, the version log and the device log, and R2 for encrypted blobs. Server code lives in a private repository. | Cloudflare pricing or limits move out of the cost table |
| Encryption | End to end. XChaCha20-Poly1305 everywhere; blobs in a chunked stream, records sealed and signed by the writing Mac. Whole-file blobs, no content-defined chunking. | |
| Keys | A master key per key epoch wraps a key per folder. Each Mac holds a signing key and a key-agreement key in the data-protection Keychain. Removing a Mac or replacing the recovery key starts a new epoch. | |
| Pairing | A new Mac gets the master key only from a paired Mac, after both show four words computed over both Macs' public keys and fresh nonces and the person confirms they match on both. | the outside review asks for a different protocol |
| Recovery | A 24-word recovery key, shown once and confirmed by re-entry, is the only way in without a paired Mac. No password-derived key. Email sign-in decrypts nothing. | passkeys replace magic links |
| History | The server thins each file's history: every version for 48 hours, hourly to 30 days, daily to 12 months; heads and pinned versions kept. Blobs are reference-counted; no R2 lifecycle rules. | p90 storage cost per payer passes the cost table |
| Agent writes | A file an agent session touched uploads at that session's turn end (120 s cap). Remote versions for such a file wait for the turn end. A version carries a writer name only on content proof ([0007](0007-agent-attribution.md)). | the beta measures more than one version per agent turn as common |
| Refused folders | git work trees and folders inside one, iCloud Drive, ~/Library/CloudStorage and folders other sync engines mark. Inside a synced folder: .git subtrees, every dot-file and dot-folder, the engine's private() list and symlinks are skipped. | beta users ask for git folders and a design that pauses sync while HEAD differs between Macs is written |
| v1 limits | Mac to Mac, while Dewline runs. 25 MB per file, 10,000 files per folder (refused above, never truncated), 10 GB of current files (1 GB on a trial), 50 GB with history. No login item, no sharing, no iPhone, no web viewer. | beta users ask for sync with Dewline quit (login item) |

## Names

- **Ids.** Account id: 16 bytes, assigned by the server. Device id: the Mac's ed25519 public key, 32 bytes. Folder, file and version ids: 16 random bytes from the client (getrandom), so a retried commit is the same commit. Pairing id: 16 bytes, assigned by the server.
- **Hashes.** `H(x)` is BLAKE3. `KH(k, x)` is BLAKE3 keyed with `k`. `KDF(purpose, k)` is BLAKE3 `derive_key` with the context `"dewline sync 2026-11-19 <purpose>"`.
- **Seal.** `seal(k, ad, m)` is XChaCha20-Poly1305 with a random 24-byte nonce, written as nonce then ciphertext; `ad` is the associated data. It is the construction of `wire::seal` in `core/crates/sync` with an associated-data argument; the cloud client keeps its own copy, because the collab crate links iroh and Loro and is off in release builds.
- **Sign.** `sign(d, purpose, m)` is ed25519 over `"dewline sync 2026-11-19 <purpose>" || m`.
- **Wrap.** `wrap(pk, ad, m)`: a fresh X25519 key pair `e`; `s = X25519(e, pk)`; `k = KDF("wrap", s || e.public || pk)`; output `e.public || seal(k, ad, m)`. Every wrap is signed by the Mac (or recovery key) that made it, and a receiver drops a wrap whose signer is not current in the device log.
- **Keys.** `MK_e`: the master key of epoch `e`, 32 random bytes. `FK_{f,e}`: the key of folder `f` in epoch `e`, 32 random bytes. `PK_f = KDF("path tag", FK_{f,c})`, where `c` is the epoch the folder was created in, kept in the folder's entry; fixed for the folder's life. `DK_{f,e} = KDF("blob id", FK_{f,e})`. `CK_{f,e} = KDF("convergence", FK_{f,e})`.
- **Normalized path.** The path relative to the folder root, NFC, then Unicode full case folding. APFS by default treats such paths as one file.

## The client

A new module in `core/crates/core` runs inside the app while Dewline runs. It is written against four seams (disk, clock, network, Keychain) so the simulation below runs the shipping code.

### The sync record

One SQLite file, `~/Library/Application Support/dev.arkwerx.dewline/sync/record.sqlite`, mode 0600, opened with `journal_mode=WAL`, `synchronous=FULL`, `fullfsync=ON` and `checkpoint_fullfsync=ON` (on macOS `fsync` does not flush the drive's cache).

| Table | Columns |
|---|---|
| `meta` | account id, device id, protocol version, feed cursor (the last server sequence number received), device-log head (sequence and hash) |
| `folders` | folder id, root realpath, root device and inode, generation, state (`joining`, `active`, `paused-missing`, `paused-deletes`) |
| `files` | folder id, file id, relative path as on disk, normalized path, synced version id (null: no base), synced hash, synced size, device, inode, size and mtime at the last read, known head id, conflict version id (null: none), side-branch tip (null: none) |
| `intents` | kind (`commit`, `apply`, `trash`), folder id, file id, version id, parent id, disk hash expected, result hash |

The record is the merge base and the identity map. `store.rs` keeps its absolute-path key: the record maps file ids to absolute paths and asks the store by those, so nobody's local snapshot history is migrated for sync.

### Identity

- A path the record knows keeps its file id, whatever its inode does. An atomic save (write a temp file, rename over) changes the inode and keeps the id, because the client resolves a path only after it has been quiet for 2 s.
- A path the record does not know is matched to a record whose path has gone missing in the same pass: same device and inode first, else the same content hash. Exactly one candidate makes a rename; none or several make a create and a delete.
- A directory rename is resolved by walking the new directory and matching each file by inode against the records under the old one. Renames never count as deletes.
- On a case-sensitive volume, a file whose normalized path equals another live file's does not sync, and Settings lists it.

### Watching

An FSEvents stream per synced folder (file events, 1 s latency), and a full walk of every synced folder at launch. A dropped-events or must-scan flag walks that subtree. A walk hashes only files whose size, mtime or inode differ from the record. The client walks the whole tree itself and never uses the editor's scan cap (`MAX_SCAN`, `engine/baseline.rs`).

What syncs: regular files up to 25,000,000 bytes, outside every skip rule below. Empty directories, permissions, extended attributes and symlinks do not.

### Reading and writing the disk

Every read and write of a synced file goes through `NSFileCoordinator` with no file presenter, so an open note's document hears the write and a LiveFile save in progress finishes first. The app supplies the coordinated read and write as callbacks to the core. A write is `file::save` (`core/crates/core/src/file.rs`), compare-and-swap against the disk hash the client last read. A file that does not exist yet is created with a new exclusive create (temp file, then a rename that fails if the path exists). A failed compare-and-swap reruns the step from a fresh read: the new bytes are a local edit.

Before the client overwrites or trashes a file, it puts the bytes on disk into the local snapshot store. History writes there are fsynced (`Store::put` through `place(…, true)`). The engine snapshots only Markdown; for other files the client calls `Store::put` itself.

### Upload

A file uploads when its disk hash differs from its synced hash, at the first of: 60 s since its last change, its note's window closing, or the release of an agent hold (below). Local snapshots keep the autosave cadence (2 s idle, 10 s at most, `LiveFile.swift`).

1. Read the bytes (coordinated); hash them. Equal to the synced hash: stop.
2. Compress with zstd, encrypt as a blob (below), compute the blob id, ask the Worker for a presigned PUT URL, and PUT straight to R2 with `If-None-Match: *` (multipart above 5 MB). A 412 means the blob is already there.
3. Write a `commit` intent with a new version id and the parent: the synced version, or the side-branch tip when the file is in conflict.
4. Commit the record to the Durable Object.
5. Accepted: in one transaction set the synced version and hash and delete the intent.

A commit whose version id already exists returns accepted, so a retried commit is safe. A `stale` answer goes to Apply below, except while that head is queued behind an agent turn: then the version uploads as a side-branch version, so the agent's work leaves the Mac. `path taken` goes to the two-way rule; `blob missing` and `epoch` re-run from step 2.

### Apply

For a file with synced version `S`, disk hash `D` and a new head `R` from the feed, the first matching rule decides. Path comes before content: when only one side changed the path, that path stands; when both did, the head's path wins and this Mac moves its file there.

1. `R` is `S`: nothing.
2. `R` does not descend from `S` and no signed reset explains it: refuse, keep everything, report (rollback check, under Threat model).
3. `R` is a tombstone and the local file is gone: both deleted; drop the record.
4. `R` is a tombstone and `D` equals `S`'s hash: move the file to the Trash (`FileManager.trashItem`, coordinated), after the snapshot. Never unlink.
5. `R` is a tombstone and `D` differs: an edit beats a delete. Commit the local bytes with the tombstone as parent. If the path tag was taken meanwhile, the `path taken` answer follows the two-way rule into the holder's file id.
6. The local file is gone (a delete not yet committed) and `R` is an edit: an edit beats a delete. Write `R` back at its path with the exclusive create.
7. `D` equals `S`'s hash: fast-forward. Write `R`.
8. `R` holds `S`'s bytes (a rename only): move the file; the local edit uploads with parent `R`.
9. Markdown, with `S`'s bytes: `merge3(S, disk, R)` (`merge.rs`). Clean: write the result `M`; `M` uploads with parent `R`. Conflicting hunks: conflict (below).
10. Otherwise (not Markdown, or no base): conflict, two-way.

`S`'s bytes are the client's own copy: on every change of the synced version, the client writes the new version's bytes, zstd, to `sync/base/<hash>` (fsynced) before the transaction that records it, and deletes a copy no record names. Server thinning and local snapshot pruning cannot take a base away. Only the Mac whose commit lost the compare-and-swap merges. A Mac whose file still holds its synced version fast-forwards, so two Macs never commit competing merges of the same pair.

Each write is: snapshot the disk bytes; write an `apply` intent (expected disk hash, result hash); for a closed note, declare the write with `closed_write` (`engine/baseline.rs`), before and after hashes and the remote origin label, as a hook does; write through the coordinated compare-and-swap; then in one transaction set the synced version to `R` and delete the intent. An open note's document hears the write and lands it through `Engine::observe` with marks, against the engine's seen base, as iCloud writes land today. A closed note lists it among changes made while closed.

### Crash recovery

At launch, before the walk, the client replays its intents. A `commit` intent is sent again unchanged. An `apply` intent finishes if the disk holds the result hash, is redone if it holds the expected hash, and is dropped otherwise (the disk holds a newer local edit, which uploads against the unchanged synced version). A `trash` intent finishes if the file is gone, is redone if the file holds the expected hash, and is dropped otherwise. Then the walk runs, then the feed resumes from the cursor.

The feed cursor is the last sequence number received, written in the same transaction as each file's known head id. A head that has to wait (agent queue, conflict, a paused folder, a join awaiting confirmation) waits in `known head id`, not in the cursor.

### Rename and path rules

A rename is a version with the same blob and a new path. Renames found in one pass (a swap, a directory rename onto live paths) commit as one batch, applied all or nothing, with tombstones and old tags released before new tags are checked. A remote create or rename onto a path that holds a local file the record does not know follows the join rules: same bytes adopt the remote id, different bytes become a two-way conflict in the remote id. A decrypted path is checked before use: relative; no empty, `.`, `..` or dot-leading component; and inside the folder root after resolving, with no symlink on the way. This is new code: `jail.rs` is rooted at the home folder and accepts `..` that stays inside. A record that fails is refused and reported.

### Writer labels

The remote origin is a stored label, `device:<device id hex>:<origin label>`, read by `Origin::from_label` (`engine.rs`). Builds older than sync read it as External. The app shows "Claude Code on Mac mini", "You on MacBook Air" or "Another app on Mac mini", taking the Mac's name from the device log. A label nested twice reads as External.

A version's label is origin `O` when every landing and save the engine recorded for the file since its synced version came from `O`, and `O`'s last write produced exactly the uploaded bytes. Otherwise it is External. Every hunk of a version lands with that version's label.

## Agent writes

- **Hold.** A file a hooked agent session claims (its PreToolUse names the path, `claims.rs`) is held from upload from that claim until the session's turn end (Stop, StopFailure or the next UserPromptSubmit, the `turnEnd` event in `ControlSocket.swift`) or 120 s, whichever comes first. A claim after a released hold starts a new one. Bash writes are never claimed and follow the normal clock. The per-call wait of [0007](0007-agent-attribution.md) (`OPEN_CALL_WAIT`, 10 s) still governs landings.
- **Remote queue.** A remote head for a file a session claimed waits while that session has made any call in the last 120 s, and lands at the session's turn end or when 120 s pass with no call. Local versions of that file made meanwhile upload as side-branch versions (Upload, `stale`). This stops the stale whole-file write: an agent reads, a remote version lands, the agent writes its old view back over it.
- **Closed-note conflicts.** A conflict keeps the local bytes on disk and puts `R` in the store. The note is listed as "Sync conflict"; opening it shows the existing conflict card (Keep Yours, Use the other Mac's, Keep Both) with base `S`. Until it is resolved, local versions upload as side-branch versions of the same file id (parent: the previous side version, or `S`), so overnight agent work never lives on one disk only. The head does not move. Resolving commits the result with the current head as parent and clears the side branch. A newer head while in conflict replaces `R`; the base stays `S`. The unresolved count shows in the menu bar and the Changes list. No sibling conflict-copy files: an agent would read them as notes.
- **Open-note conflicts** take the same path: the disk keeps the local bytes and the card shows in the open note. The landing takes `S` as its base, a new base argument; today it always reads the seen version.
- **Merges.** Hunks identical on both sides at the same base position merge to one copy. Identical text inserted at different positions stays twice; there is no fuzzy dedupe and no fuzzy patching. Clean merges that touch agent-written hunks land marked, so Revert works.

## Joining, deleting and folder limits

- **Join.** Turning sync on for a folder with files, on a Mac whose account already has that folder, matches by normalized path against the server's live heads: same hash adopts the server version id; different hash keeps the local bytes, stores the server version and lists a two-way "Sync conflict"; local-only files upload; server-only files download with the exclusive create. The counts show before anything is written ("212 identical, 9 differ, 30 new here, 4 new on the server"), and nothing is written until the person confirms. The first Mac to sync a folder joins against an empty server.
- **Reset Sync** (per folder) needs a device-signed reset entry. It starts a new folder generation whose heads are this Mac's files; earlier versions stay in history. Every other Mac sees the entry and rejoins through the join step.
- **Missing folder.** A root that is missing, unmounted or replaced (new device or inode) pauses that folder. A paused folder emits no tombstones.
- **Mass delete.** More than 20 deletes, or deletes of more than 10% of the folder's files and at least 5, within 60 s pause that folder's uploads and ask "Delete 340 files on all your Macs?" Delete commits the tombstones; Keep writes the files back from the store or the server.
- **Restore Folder** to a time `T`: for each file id, the newest kept version at or before `T`, committed as a new version on the current head. Files created after `T` go to the Trash as tombstones. Counts show first.
- **Size.** Over 10,000 files that would sync, the client refuses to turn sync on and names the count. A synced folder that grows past it stops uploading new files and shows the count; edits to synced files continue. Over 10 GB of current files (1 GB on a trial), the Durable Object refuses commits that grow the total, and the Mac says Sync is full. Files on every Mac stay as they are.

## Folders v1 refuses or skips

- **Refused.** A git work tree or any folder inside one (an ancestor holds `.git`, a directory or a worktree's file): "This folder is a git repo. Use git to move it between Macs." Anything under `~/Library/Mobile Documents` or `~/Library/CloudStorage`, or whose `isUbiquitousItem` is true (Desktop and Documents with "Desktop & Documents in iCloud" on): "This folder already syncs through iCloud. Move it out or keep using iCloud." A folder with `.dropbox` or `.stfolder` in it or an ancestor, for the same reason. Two engines on one folder ping-pong writes, and evicted files read as empty.
- **Skipped inside a synced folder.** Any subtree holding `.git` (Settings lists them); every dot-file and dot-folder, so `.env` never leaves the Mac; the engine's `private()` list (`engine.rs`: `.jsonl`, `.claude.json`, `file-history/`, `.json` and `.toml` under `.claude` and `.codex`); symlinks, never followed; files over 25 MB, listed.
- The root is stored as its realpath at setup.

## The server

The Worker authenticates and routes; the account's Durable Object is single-threaded and holds all state in its SQLite storage. Blobs never pass through the Worker.

### Records

A version record is a header, a sealed metadata block, and a signature.

Header, big-endian, fixed order: format (u16, 1); account id; folder id; folder generation (u32); file id; version id; parent version id (zeros for a create); kind (u8: 1 content, 2 tombstone); branch (u8: 0 head, 1 side); blob id (32 bytes, zeros for a tombstone); blob size in ciphertext bytes (u64); key epoch (u32); path tag (32 bytes, `KH(PK_f, normalized path)`); signer device id.

Metadata: `seal(FK_{f,e}, header, TLV)`. TLV entries are tag (u16), length (u32), bytes: 1 relative path (UTF-8, as on disk); 2 plaintext BLAKE3 hash; 3 plaintext size (u64); 4 writer label; 5 client time (u64 ms). A rewrite keeps unknown tags verbatim and in order.

Signature: `sign(device, "record", header || H(sealed metadata))`. A pruned version keeps its header, that hash and the signature, so its stub still verifies.

A Mac accepts a record only when the signature verifies, the signer is current in the device log at the record's sequence number, the metadata opens under the folder key of the record's epoch, and, after download, the plaintext hashes to tag 2. The header as associated data binds account, folder, file, version, parent and blob, so the server can neither splice a record onto another file nor pass an old record off as new.

### Blobs

- Blob id: `KH(DK_{f,e}, H(plaintext))`. The server cannot test a guess about content; dedup works within a folder and an epoch.
- Blob key: `KDF("blob key", FK_{f,e} || blob id)`, where `e` is the record's key epoch. A record may name a blob only from its own epoch: a rename, restore or Keep that reuses an older epoch's blob re-encrypts and uploads it under the current epoch first.
- Body: zstd, then the STREAM construction (Hoang, Reyhanitabar, Rogaway and Vizár, 2015) over XChaCha20-Poly1305: 64 KiB plaintext chunks; nonce = a random 19-byte prefix, the chunk counter (u32), and a last-chunk flag (u8); associated data = account id, folder id and blob id. It gives libsodium secretstream's guarantees (per-chunk authentication, no reordering, truncation detected) without a C library in the core. The plan named secretstream; this swap is the reviewer's item 5 and reverts to secretstream if the reviewer prefers it.
- R2 key: `<account>/<folder>/<blob id>`, immutable. Writes use `If-None-Match: *`, so a retry cannot overwrite.

### Commit

`commit(protocol, records)` in the Durable Object takes a batch of records and applies all or none. For each record, in order:

1. Protocol below the minimum: refuse, and the app shows "Update Dewline to keep syncing".
2. Signer not a current device, or signature bad: refuse.
3. Version id already stored: accepted (idempotent).
4. Folder generation not the current one: refuse `reset`; the Mac rejoins.
5. Key epoch not the current one: refuse `epoch`; the Mac fetches the new keys and re-encrypts.
6. Blob not in R2, or marked for deletion: refuse `blob missing`.
7. Side branch: accepted if the parent is any version of the file id; the head does not move. The Durable Object keeps each signer's newest side version until that signer commits on the head. Whether a conflict is open is the client's state, not the server's.
8. Create: accepted if no live file holds the path tag; else `path taken` with the holder's file id.
9. Update or tombstone: accepted only if the head is the parent; else `stale` with the head. A tag change needs the new tag free. A tombstone releases the tag.
10. Quota: refuse if current bytes would pass the plan's quota or the 50 GB ceiling.

Accepting assigns the next account sequence number, takes a reference on the blob, and pushes "head changed" to every connected Mac.

### Feed and connection

Online Macs hold a hibernating WebSocket to the Durable Object. A Mac coming online pulls records since its feed cursor. The feed carries head and side versions, device-log entries and key wraps, in sequence order.

### Device log

An append-only chain in the Durable Object. Each entry: sequence, `H` of the previous entry, type, fields, signer, signature. A new entry must name the current tail (compare-and-swap), so two Macs rotating at once serialize. Types: `genesis` (first Mac, epoch 0), `recovery` (recovery public keys and a new epoch), `add` (a Mac, its key-agreement key, its name sealed under `KDF("device names", MK_e)`, the pairing transcript hash, and the epoch it was made in), `remove` (a Mac and a new epoch), `folder` (a folder id, its creation epoch, its name sealed under the folder key), `reset` (folder, generation), `delete-account`, `cancel-delete`. An entry that starts an epoch is appended in one Durable Object transaction with all of that epoch's wraps and folder keys, so no crash leaves a removed Mac's keys current. An `add` whose epoch is no longer current is refused, and the approving Mac wraps again. An entry is valid when a device current at that point, or the recovery key, signed it. Each Mac replays the chain from genesis and keeps its head in `meta`; the Durable Object checks the same rule before appending.

### Keys on the server

For each epoch `e`: `MK_e` wrapped to each current Mac's key-agreement key and to the recovery key-agreement key; `MK_{e-1}` sealed under `KDF("epoch chain", MK_e)`, so Macs read old history; each `FK_{f,e}` sealed under `KDF("folder key", MK_e)` with the folder id and epoch as associated data. Each is signed by its writer.

### Sign-in and scopes

Email magic link: single use, 15 minutes. A session from the link alone may run pairing, fetch the recovery wrap, and manage billing. Reading the feed, committing, and every account action need a device token, issued to a device id only after a valid `add`, `genesis` or recovery entry, and revoked by `remove`.

## Keys and pairing

- **Device keys.** Each Mac makes an ed25519 signing key and an X25519 key-agreement key. They and the cached master and folder keys live in the data-protection Keychain (`kSecUseDataProtectionKeychain`, the keychain-access-groups entitlement and a provisioning profile, as [0009](0009-collaboration.md) names), service `dev.arkwerx.dewline.sync`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. After-first-unlock, not when-unlocked: a Mac mini running an agent overnight with its screen locked has to sync. This-device-only: no key goes to iCloud Keychain. This lands before beta.
- **Pairing.** The new Mac `N` has signed in; an approving Mac `A` is paired.
  1. `N` makes its keys and a 32-byte nonce `n_N`, and sends `PairRequest {pairing id, N's two public keys, c = H("commit" || pairing id || N's keys || n_N)}`. The request expires in 10 minutes.
  2. On `A`, the person picks the request. `A` sends `PairChallenge {A's two public keys, n_A}` after it holds `c`. `N` takes one challenge per pairing id.
  3. `N` sends `n_N`. `A` checks it against `c`.
  4. Both compute `H("sas" || pairing id || N's keys || A's keys || n_N || n_A)` and show its first 44 bits as four words from the BIP-39 English list. The person confirms "The words match" on both Macs. `N`, on confirmation, signs the transcript hash and sends it.
  5. `A`, with its own confirmation and `N`'s signed transcript, appends `add` and writes the wraps of the current `MK_e` to `N`.
  6. `N` replays the device log, checks that `A` is current and that the `add` names its keys and the transcript hash, then unwraps.

  A mismatch on either Mac, a second challenge, or an expired request ends the pairing id; `A` says someone may be trying to add a Mac. The server relays only public values. Because `N` commits to `n_N` before it sees `n_A`, a relay that substitutes keys must match a fresh 44-bit value per attempt, in view of the person. `N` confirms too: without that, a server could pair `N` to keys it holds, and `N` would encrypt its folder to them.
- **Recovery key.** 32 random bytes, shown once as 24 words (BIP-39's entropy-to-words encoding with its checksum; no BIP-39 seed derivation). They derive a recovery signing key and key-agreement key; the public halves go in a `recovery` entry. Setup asks the person to type the words back. Dewline asks again 7 days after setup and once a year, checking the derived public keys against the log. Any paired Mac can make a new recovery key; that starts a new epoch, so the old words open nothing new.
- **Recovery.** A Mac with no paired Mac signs in, takes the 24 words, fetches the recovery wrap, unwraps `MK_e`, and appends its own `add` signed by the recovery key.
- **Removing a Mac** from Settings on any paired Mac appends `remove`, which revokes its token and starts epoch `e+1` in the same transaction: a new `MK`, new folder keys, wraps to the remaining Macs and the recovery key. New versions use the new epoch; old versions keep theirs. The removed Mac keeps what it already holds.
- **Destructive actions.** Reset Sync needs a `reset` entry from a paired Mac. Deleting the account needs a `delete-account` entry, emails the account, and runs 7 days later unless any paired Mac or the recovery key signs `cancel-delete`. An inbox alone cannot wipe history. A person with no Mac and no recovery key reaches deletion through the lapse rule of record 0011 (pricing) or a support request with the same 7-day delay and email.
- Setup says: "Without a Mac and without your recovery key, nobody can read your synced notes, including us." Sync is never called a backup.

## Version history and pruning

- A Durable Object alarm runs daily. Per file, by server receive time: every version from the last 48 hours; the newest version in each UTC hour to 30 days; the newest in each UTC day to 12 months; older versions go. The head, pinned versions and each signer's side tip are always kept. A deleted file's chain follows the same schedule from its tombstone, then the file id is forgotten. Trials keep 30 days.
- A pruned version keeps its header, metadata hash and signature as a stub, so the parent chain stays checkable; its sealed metadata and blob reference go.
- Each blob has a reference count in the Durable Object. Pruning decrements it; at zero the blob is marked for deletion inside the same transaction, then deleted from R2. A presigned PUT records a pending blob; a pending blob no commit references after 24 hours is deleted. No R2 lifecycle rules on the bucket.
- Earlier Versions lists local snapshots and server versions together, each with writer and Mac. Local retention stays 30 days and 50 versions (`store.rs`); the server is the long history.
- History does not count toward the quota; the 50 GB ceiling covers it.

## Convergence check

After quiescence (10 minutes with no local change, remote head or pending work), and at most every 6 hours, each Mac sends the Durable Object, per file id, its synced version id, whether the disk holds it, and `KH(CK_{f,e}, disk bytes)`. The Durable Object flags a file when every reporting Mac says it holds the head and the keyed hashes differ, or a Mac says it holds a version that is not the head after quiescence. The app shows "Sync found a difference on 2 files" and offers a report, which the person chooses to send; it attaches the client's local invariant log. The beta terms say this exists.

## Threat model

| Adversary | Can | Cannot |
|---|---|---|
| ArkWerx, Cloudflare, a subpoena | see account email, device ids, file ids, the version graph, sizes, times, IP addresses, which versions share content within a folder and epoch, and which live files share a normalized path tag (so renames and path reuse, not names) | read content, file names, paths, writer names, device names or folder names |
| A malicious server | withhold, delay or reorder the feed; truncate the device log's tail; show two Macs different heads; refuse service | forge or alter a record, a log entry or a wrap; splice a record onto another file; roll a Mac back past its synced version (the descendant check and stubs); pair its own key to an account (the four words, confirmed on both Macs) |
| Someone holding the email inbox | sign in; start pairing; fetch the recovery wrap (sealed to a 256-bit key); cancel billing, which stops sync | read anything, add a Mac without a paired Mac's confirmation, delete history without the 7-day window |
| A stolen Mac | everything its Keychain opens, until removed; FileVault is the control at rest | read versions from epochs after its removal |
| A compromised paired Mac | everything | (trusted by design) |
| A hostile agent on one Mac | write content that arrives on other Macs as a marked, named or unnamed change | write outside the folder on another Mac (path checks), reach skipped files |
| A network observer | timing and sizes, which show when someone writes | anything inside TLS and the sealed layer |

Residual risks, stated in the security page: a malicious server can keep Macs apart and hide a recent removal from a Mac that has not seen it; the convergence check runs through the same server; metadata shows activity patterns, such as an agent writing at 02:14.

## What the outside reviewer must check

The review is done by someone outside the project, in writing, before private beta. Each finding is fixed or accepted in this record.

1. Pairing: commitment order, the 44-bit comparison length, binding of both key pairs into the words and the transcript, confirmation on both Macs, replay and expiry, and whether a person clicking "match" without reading needs a typed check instead.
2. Device log: signature rules from genesis, the recovery key's power to add a Mac, tail truncation by the server, concurrent rotations, and the epoch-starting transaction.
3. Epochs: rotation on removal and on a new recovery key, the epoch chain, what a removed Mac keeps, and that a stale-epoch commit is refused.
4. Record format: canonical header encoding, the header as associated data, signing the hash of the sealed bytes (so stubs verify), purpose separation of every KDF and signature context, random 192-bit nonces.
5. Blobs: STREAM in place of secretstream, its nonce layout, last-chunk flag and truncation, the per-blob key, re-encryption across epochs, and compressing before encrypting.
6. The blob id and path tag: what keyed hashes reveal within a folder, and the path-tag key that does not rotate.
7. Recovery key: entropy, encoding, the derivations from it, and no password path.
8. Wraps: the X25519 construction, signatures on every wrap, and their associated data.
9. Rollback: the descendant check, header stubs after pruning, and the reset path.
10. Keychain: access group, after-first-unlock, this-device-only.
11. Scopes: what a magic-link session alone can do.
12. That the server-sees list matches a captured session's traffic.
13. Dependencies: ed25519-dalek, x25519-dalek, chacha20poly1305, blake3, the stream code, rusqlite; exact pins at least 14 days old on crates.io, as [0009](0009-collaboration.md) set.

## Simulation and gates

**Simulation.** Deterministic from a seed, in the nightly next to the engine's property model. It runs the client code against a simulated disk (inodes, atomic renames, fsync points, crash losing what was not fsynced), clock (per-Mac skew up to an hour), Keychain and network (delay to 30 s, loss, duplication, reconnects), with 2 to 4 Macs and one server model. The server model implements the Commit, feed, device-log and pruning rules above; a conformance suite of recorded requests and answers runs against it and the real Worker, so the two cannot drift. Paths come from a small alphabet with case and NFC/NFD variants; contents from a small line alphabet, so merges conflict often. A step is one operation, one delivered message or one timer.

Operations: edit; agent write with hooks and without; agent turn end; atomic save; rename; directory rename; delete; mass delete; Mac offline and online; crash between any two steps of upload or apply; unmount and remount; same-path create on two Macs; Reset Sync; device removal; recovery; pruning alarm; server restart.

Quiescence: every Mac online, no new operations, every conflict resolved by a random choice, every agent turn ended, every prompt answered at random, every folder remounted, then the clock advances until no work is pending.

Invariants:

1. Every version the client uploaded, overwrote or trashed, and every version the engine snapshotted, is in a local snapshot or the server history, unless the retention schedule has since dropped it.
2. After quiescence, every Mac holds the same bytes per file id.
3. No Mac's client removes a file without a device-signed tombstone.
4. Every clean merge contains every hunk of both sides (identical hunks once); otherwise a conflict is recorded.

**Gates.**

- Private beta: 10 million simulated steps with no violation; then a two-Mac soak with an agent writing and fault injection (kill mid-upload, 3 days offline, a rename storm, unmount, clock skew); the outside review done; the data-protection Keychain in place.
- Price notice: 8 weeks of beta with no detected divergence left unexplained and unfixed.
- Any time: one confirmed data-loss bug stops invites until it is fixed, a simulation case reproduces it, and the soak passes again. A second one in public beta moves paid day back at least four weeks.

Pricing, trials and the commercial gates (sign-ups, founding cards, conversion) belong to record 0011.

## Code this needs

- `core/crates/core`: the client module, the sync record and walker, the exclusive create in `file.rs`, a base argument on the engine's landing for conflicts, the `device:` origin label, two queries on the claims ledger (which sessions claimed a path; when a session last called). New dependencies: rusqlite on the system SQLite, ed25519-dalek, x25519-dalek, chacha20poly1305 (all but rusqlite and x25519-dalek are already in `core/Cargo.lock`).
- `app/`: the coordinated read and write callbacks, an FSEvents stream per folder, Settings > Sync (folders on and off, account, devices, recovery key, delete account), the join and mass-delete sheets, the menu bar count, Keychain entitlements.
- `store.rs` is not re-keyed. The collab crate is not touched.
- The service: a private repository.

## Rejected

- **CRDT sync (Loro or Automerge per file).** Agents rewrite whole files; it would also need the per-file persistence [0009](0009-collaboration.md) avoided.
- **CloudKit `encryptedValues`.** A Keychain reset loses the data for good, it ties sync to one Apple ID, and it leaves no place for attribution, history or billing.
- **A password-derived key.** Something for the server to brute-force and for the person to forget.
- **Content-defined chunking.** Keyed CDC was broken in five backup tools (IACR ePrint 2025/558).
- **Seen versions as the merge base, and re-keying `store.rs`.** See the table.
- **Sibling conflict-copy files.** Agents read them as notes.
- **A login item in v1.** A background process on a schedule that is already the risk.
- **R2 lifecycle rules.** Age-based deletion removes blobs live versions still reference.
- **An entitlement token on the Mac.** Shut-off follows the server's billing state.

This record replaces the "Peer to peer" row of [0001](0001-foundations.md) and the "Collaboration" and "Release order" rows of [0002](0002-1.0-scope.md), which had already replaced 0001's release order. The free app ships first; Dewline Sync follows as a private beta, then a public one. Own-Mac sync is this hosted service, not peer to peer; live collaboration stays peer to peer by invite link with no account ([0009](0009-collaboration.md)); Dewline Sync is the only feature with an account; nothing in the editor needs one.

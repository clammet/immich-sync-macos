# OpenCloud Sync for macOS

A menu bar app and native macOS File Provider for OpenCloud files and spaces. Swift, SQLite, and Apple's File Provider supply Finder placeholders, on-demand downloads, and offline availability. Immich is an optional media integration.

## Connect

Build with Xcode for macOS 14 or later. Install the app in Applications, enter the OpenCloud server's base URL, username, and a dedicated **app token**, then enable the File Provider in System Settings. HTTPS is the default; HTTP requires an explicit per-server opt-in.

OpenCloud is the sole synchronization backend. The client discovers your spaces through Libre Graph and accesses their server-provided WebDAV URLs. There is no Immich connection or media-type requirement for synchronization.

| Operation | Behavior |
| --- | --- |
| Browse | Spaces contain the actual server directory tree and ordinary files |
| Open | macOS hydrates content on demand |
| Offline | Finder's **Always keep available**, **Make available on demand**, and parent-policy actions |
| Create/edit | Chunked TUS uploads with revision conditions; revisions remain under OpenCloud's control |
| Rename/move | Server-side moves within a space, retaining file IDs |
| Delete | Conditional server deletion; OpenCloud controls its trash/retention policies |
| Share | Create read-only OpenCloud links for files/folders; open the server page to manage sharing |
| Conflict/failure | Retain pending Finder changes and durable recovery copies; never overwrite a changed revision |

Representable filenames are retained, including dotfiles, whitespace and Unicode. Suffixes are used only for actual case/Unicode collisions on the local filesystem or names exceeding its limit. Server paths remain exact even when Finder needs a different display name. Immich asset IDs are never appended to synchronized names.

Sharing actions are available in Settings and Finder's File Provider context menu. Finder-created links and album URLs appear in the menu bar app with **Copy links** and **Open result**. The app must be running to display those results; the extension saves them if it is closed.

## Optional Immich actions

Connect Immich separately in Settings using a session (password/browser sign-in) or an API key. For browser sign-in register `opencloud-sync://oauth` with the identity provider's Immich OAuth client.

Use **Discover libraries and paths** to query library import roots, exclusions and sample indexed original paths. Library configuration can require administrator permissions; ordinary users can still inspect paths exposed by their accessible assets. These APIs do not establish which OpenCloud space backs an Immich container mount.

Configure each media mapping explicitly:

1. Select the corresponding folder or space **inside OpenCloud**.
2. Enter the exact server/container directory that Immich sees for that folder.
3. Optionally specify the Immich library ID, especially if multiple libraries index the same path.
4. Add separate mappings for other spaces, subtrees or mounts.

No suffix-based path guessing is performed. Mappings are scoped to the connected Immich server/user and use case-sensitive component boundaries. The most specific confirmed mapping applies. Ambiguous mappings or assets fail safely.

Select a folder or files in Settings, or use Finder actions, to create an Immich album or sharing link. These actions resolve exact indexed original paths and pass **existing asset IDs** to Immich. They never upload a duplicate native copy. Folder actions include indexed descendants and report skipped files; explicitly selected files must resolve. Newly added or edited media may need time for Immich's external-library scan. Files outside mapped/indexed media continue to support all OpenCloud operations.

## Recovery

Before creating or modifying remote content, the extension copies pending bytes into a per-account **Recovery** directory with a manifest. Failed preconditions, offline changes, and ambiguous network outcomes keep those copies. TUS session checkpoints allow interrupted transfers to resume at the server's accepted offset after restarting. Successful, committed operations clear their recovery entry. A recorded upload can resume a later failed rename without re-uploading. Expired sessions and lost upload-creation responses remain recoverable instead of being blindly replayed.

Sync status and individual Recovery entries distinguish changes not sent, rejected requests, interrupted uploads, unavailable upload sessions, uncertain server results, and confirmed uploads with remaining changes pending. An uncertain result does not imply the previous server copy was preserved. Recovery-copy messages appear only when pending content is actually retained.

Use **Open Recovery** in Settings. Copy a retained edit back into Finder with a new name to resolve a conflict. **Mark resolved; keep recovery files** clears a pending operation's deletion guard while retaining its files. Recovery is also accessible from the disconnected menu. Do not manually delete recovery content until you have recovered what you need.

Disconnect uses preserve-downloaded-user-data mode. Recovery remains on disk. Revoke OpenCloud app tokens in the server's Settings.

## Build and validation

The Swift package and app scheme are `OpenCloudSync`, with `OpenCloudCore` and `OpenCloudFileProvider` library targets. The app bundle is `OpenCloud Sync.app`.

1. Select full Xcode as the active developer toolchain.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your development team and unique bundle identifier.
3. Build the **OpenCloudSync** scheme in `OpenCloudSync.xcodeproj`.
4. Install the resulting app in Applications.

```sh
sh scripts/check.sh
python3 scripts/container-e2e.py
python3 scripts/build-dmg.py
```

See [architecture](docs/architecture.md), [integration testing](docs/integration-testing.md), and [distribution](docs/distribution.md).

Current limits: one OpenCloud account, all member spaces, full metadata polling every minute, within-space moves, regular files/directories. Symlinks and packages are excluded. Finder tags/resource forks and revision browsing/restoration are not implemented; use OpenCloud's web interface for history. The disposable container suite covers OpenCloud/Immich without OS interactions; signed Finder workflows remain manual. OpenCloud 9.0.0 has conditional-request and concurrent TUS upload failures; the container runner deliberately exits unsuccessfully when its upstream contract probes reproduce them. See [integration testing](docs/integration-testing.md) for coverage and limitations, and the [TUS test report](docs/tus-testing.md) for observed results.

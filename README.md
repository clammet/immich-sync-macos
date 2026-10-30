# Immich Sync for macOS

A native menu bar client connecting Immich to Finder through Apple's replicated File Provider framework. Sign in with your Immich account, browse online-only photos and videos, and use **Always keep available** to keep selected files or folders downloaded.

This build targets **Immich 3.3.5 exactly**, using its native incremental synchronization protocol. It requires macOS 14 or later. Server upgrades require updating and validating the protocol contract. A provisioned, signed application is needed to activate the Finder extension; signed Finder and live-server validation remain release requirements.

## Sign in

Enter your server address and either sign in with email/password or choose **Sign in with browser** for your server's OAuth provider. Each sign-in creates a dedicated Immich session for this Mac. The session token is stored in shared Keychain; passwords are never saved. Expired or revoked sessions require signing in again.

Browser sign-in uses PKCE and a random state value. Register this exact additional redirect URI in your identity provider's Immich OAuth client:

```text
immich-sync://oauth
```

The existing Immich OAuth server configuration is used. Browser sign-in requires OAuth to be enabled on the server. Password sign-in requires password login to be enabled. No server plugin is required.

HTTPS is the default. HTTP requires explicit opt-in for a trusted local server and remains subject to macOS transport security. Server addresses may include reverse-proxy subpaths and a trailing `api` component.

## Synchronization

The extension streams assets, EXIF sizes, albums, album users, and album membership changes through Immich's `sync/stream` endpoint. An initial bootstrap populates the local catalog. Subsequent requests receive changes since acknowledged checkpoints.

Each bounded batch commits its data and acknowledgement outbox in one SQLite transaction. Acknowledgements are sent only after that commit. Interrupted transfers resume from committed checkpoints, and lost acknowledgement responses are retried before the next stream. A server-requested reset builds a replacement generation while keeping the visible library available, then publishes the replacement after a valid completion record.

The menu bar app requests a change check every minute. **Sync now** checks immediately. An idle check does not enumerate the library or album contents. Local uploads, edits, and album changes update affected catalog records directly; they do not request a full-library refresh. Finder requests can also trigger an incremental check. Keep the menu bar app running for periodic checks.

## Finder behavior

| Action | Behavior |
| --- | --- |
| Open a photo or video | Download and verify the original; macOS manages its cached content |
| Browse thumbnails | Fetch server derivatives without downloading originals |
| Always keep available | Persist an eager download policy; children inherit folder availability |
| Make available on demand | Allow eviction; use Finder's Remove Download to reclaim space |
| Add media to All Photos | Upload to your Immich library |
| Create or rename a folder directly inside Albums | Create or rename an Immich album |
| Add media to an album | Upload/deduplicate the media and add its membership |
| Move media between albums | Add the destination membership before removing the source |
| Delete media from an album | Remove membership and keep the original |
| Delete an album | Remove the album and keep its original media |
| Delete media from All Photos | Move the original to Immich trash, affecting all album appearances |
| Edit an original | Upload and verify a new asset, copy associations, then trash the old original |
| Add an unsupported file or nested folder | Retain it locally with a grey ignored overlay; do not upload it |

**Ignored items are stored only on this Mac and are not backed up to Immich.** Their content has a durable backing copy, is marked as not uploaded, and cannot be evicted. If a remote album disappears, its local-only children remain reachable under All Photos. Packages and symlinks use the system's exclusion mechanism instead of being traversed.

All Photos and Albums are views of the same originals. An asset in multiple albums has a separate Finder appearance in each. Stable identity suffixes prevent filename collisions on case-insensitive filesystems. Immich's current API does not support renaming original media filenames. External-library originals are read-only; other users' and locked assets are excluded.

Edits and library deletions require Immich trash with a positive retention period. The client never requests force deletion. Recovery follows server retention settings. An edit journal handles interrupted upload/copy/trash sequences, and source hashes are checked before retiring originals. Immich does not provide atomic conditional deletion, so a final cross-client race remains possible.

## Build and run

1. Install full Xcode with macOS support and select it as the active developer toolchain.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Configure your development team and unique bundle, shared App Group, and shared Keychain identifiers.
3. Enable the same App Group and Keychain access group for the app and extension in their provisioning. Keep the sandbox and outgoing network entitlements enabled.
4. Build the ImmichSync scheme in `ImmichSync.xcodeproj`. Local development uses Apple Development signing; distribution requires appropriate Developer ID signing and notarization.
5. Install the built app in Applications, launch it, and enable the extension in System Settings if macOS requests it. Use the photo-stack menu bar item to sign in and open Finder.

Command-line checks:

```sh
swift build
swift test
python3 scripts/generate-project.py
```

Complete Xcode provides XCTest and the application bundle build. These checks run entirely from the command line once Xcode's first-launch setup is complete.

`sh scripts/check.sh` validates the package and project metadata. The Xcode project is generated deterministically without third-party tooling; regenerate it after adding or renaming app/extension sources. GitHub Actions builds the unsigned application bundle and runs the standard XCTest suite.

See [architecture and pinned protocol sources](docs/architecture.md) and the [signed integration checklist](docs/integration-testing.md).

## Scope

- One account and a default File Provider location on the Mac's home volume.
- Flat Immich albums; arbitrary nested folders remain local-only.
- Original content and the selected native metadata streams. Finder tags, resource forks, new Live Photo pairing, and rendered non-destructive Immich edits are not synchronized.
- Content edits create a new Immich asset ID. Album associations and supported copy fields are preserved; faces, share links, and stacks are not transferred.
- Offline availability is per Finder appearance; keeping several appearances downloaded can consume additional disk space.
- Disconnect preserves downloaded and unsynced data, forgets the local token, and attempts to revoke this Mac's session. Remote session management remains available in Immich.
- This is a development build. Signed extension lifecycle, Finder decorations, OAuth against a configured provider, and live-server behavior still need integration validation.

Development installs require a fresh sign-in. The session account, token service, and native catalog are separate storage formats, with no migration of earlier development data. Disconnect the earlier development build before installing this one so macOS can preserve any downloaded or unsynced files.

This project is an independent Immich client.

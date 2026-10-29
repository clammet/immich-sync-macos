# Immich Sync for macOS

A native menu bar client that connects Immich to Finder using Apple's replicated File Provider framework. macOS manages placeholders, on-demand downloads, transfer status, and disk eviction. The app manages the Immich account and polls for remote changes.

This is an initial implementation for macOS 14+ and Immich 2.5+. The Swift app and extension compile independently of Xcode. A signed, provisioned app bundle is required to activate the Finder extension. Live-server and signed Finder integration testing are still required before release.

## Behavior

| Finder action | Immich behavior |
| --- | --- |
| Open a photo or video | Download and verify the original; macOS caches it |
| Always keep available | Persist an eager download policy; folders pass it to their children |
| Make available on demand | Allow macOS to evict downloaded media; use Finder's Remove Download to reclaim space |
| Add media to All Photos | Upload to the authenticated user's library |
| Create or rename a folder directly inside Albums | Create or rename an Immich album |
| Add media to an album folder | Upload or deduplicate the media and add album membership |
| Move media between albums | Add the destination membership, then remove the source membership |
| Delete media from an album | Remove that album membership; keep the original |
| Delete an album | Delete the album; keep its original media |
| Delete media from All Photos | Move the original to Immich trash, affecting all album appearances |
| Edit an original | Upload and verify a new asset, copy album associations and favorite/sidecar data, then trash the old original |
| Add an unsupported file | Keep it on this Mac with a grey ignored overlay and an accessible explanation; never upload it |
| Create nested folders | Keep them and their contents locally with the ignored overlay; Immich does not support nested albums |

**Unsupported files are not backed up to Immich.** They have a durable local copy in the shared application container, remain marked as not uploaded, and cannot be evicted. A local-only file moved or renamed into a supported media type/location is reevaluated for upload. Packages and symbolic links use the system's native exclusion mechanism instead of being traversed.

All Photos and Albums are two views of the same assets. A file appearing in several albums represents the same original. Stable remote identity suffixes prevent filename collisions on case-insensitive filesystems. Original media filename renaming is unavailable because the current public Immich API does not support it. External-library assets are read-only; shared accounts' assets and locked assets are excluded.

Immich trash must be enabled with a positive retention period for edits and library deletions. The client never sends force-delete requests. Recoverability still follows the server's retention settings. Immich has no conditional-write/delete transaction: the client checks versions before writing, preserves a conflicting local edit, and uses a persistent journal to recover interrupted edit sequences. Cross-client changes during the final server request remain a server-side race.

## Build and run

1. Install full Xcode with the macOS SDK. Open `ImmichSync.xcodeproj`.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Set your development team and unique bundle, App Group, and shared Keychain identifiers.
3. Register the application and extension identifiers with the same team. Enable the shared App Group for **both** targets and include the shared Keychain access group in their provisioning. Keep the sandbox and outgoing network entitlements enabled.
4. Select the ImmichSync scheme and build. For local development, use an Apple Development identity with matching provisioning. Distribution needs Developer ID signing, provisioning where required, hardened runtime, and notarization.
5. Install the built app in Applications and launch it. Enable the File Provider extension in System Settings if macOS requests it. Open the photo-stack menu bar item and choose Connect to Immich.
6. Enter the server address and a dedicated API key. A trailing `api` path is accepted, and reverse-proxy subpaths are preserved. HTTPS is the default. HTTP requires explicit opt-in for a trusted local server and remains subject to macOS transport security.

Grant the key these permissions:

```text
user.read
asset.read
asset.view
asset.download
asset.upload
asset.copy
asset.delete
album.read
album.create
album.update
album.delete
albumAsset.create
albumAsset.delete
```

No admin, permanent-deletion, or `all` permission is required. Keys are shared between the app and extension through Keychain; the account file contains no credential. Account switching requires disconnecting the previous account first. Disconnect uses Apple's mode that preserves downloaded and unsynced data, and reveals the retained location in Finder.

Keep the menu bar app running for periodic remote updates. It signals the working set every five minutes; Sync now requests an immediate refresh. Finder requests also refresh stale metadata. On-demand operations run in the extension even when the menu bar app has quit. Pause prevents new sync work; an operation already in flight may finish.

## Development

```sh
swift build --build-system native
swift test --build-system native
python3 scripts/generate-project.py
```

The native SwiftPM build mode also supports command-line-tool installations. On newer SwiftPM releases it may be deprecated; the default build mode can be used with a complete Xcode installation. XCTest requires Xcode's test libraries.

`sh scripts/check.sh` runs the package checks and validates project metadata. The Xcode project is committed and generated deterministically without a third-party project generator. After changing app or extension source filenames, regenerate it. `scripts/generate-badge.swift` draws the checked-in Finder badge using native vector drawing. GitHub Actions builds the unsigned app bundle and runs the test suite.

The tests cover API pagination and parsing, binary multipart uploads, filename safety, durable sync anchors, snapshot consistency, local-only file retention, availability policies, deletion semantics, edit ordering, conflict protection, and retry recovery. See [the architecture notes](docs/architecture.md) for the design decisions and primary research sources, and [the integration checklist](docs/integration-testing.md) for validation that needs a signed app and a test server.

## Current limits

- One account and internal-volume domains. Empty local-only folders are not represented on the server.
- Public API-key endpoints are used instead of the session-only mobile sync stream. Refreshes currently enumerate the full library and album memberships, with bounded paging and connection concurrency. Very large libraries need an incremental server adapter before this should be deployed widely.
- The catalog's change journal is persistent. Each album appearance has a distinct provider identity, so keeping multiple appearances offline can consume additional disk space.
- Filename changes, arbitrary directory trees, Finder tags, resource forks, Live Photo pairing during new imports, and propagation of Immich's non-destructive edit recipes are not supported. Original downloads remain byte-for-byte originals. Export edited media from Immich when you want its rendered edits.
- A content edit creates a new Immich asset ID. Faces, share links, stacks, and other relationships beyond those explicitly copied are not transferred. The old asset remains subject to Immich's trash retention.
- The native ignored overlay, signed extension lifecycle, and Finder behavior have not yet been verified on a provisioned build. This repository does not contain a signed/notarized installer.

This project is an independent Immich client.

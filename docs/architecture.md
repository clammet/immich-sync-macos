# Architecture and research

Research checked on 29 October 2026 against Apple's File Provider documentation, the installed macOS SDK headers, Immich's public OpenAPI specification, and its versioned 2.5 schema.

## Native filesystem integration

The containing app is a SwiftUI `MenuBarExtra` with an account/settings window and optional login startup through `SMAppService`. `LSUIElement` keeps the main interface in the menu bar. A sandboxed embedded extension implements `NSFileProviderReplicatedExtension` and `NSFileProviderCustomAction`.

The system owns the visible files and their hydration lifecycle. The client does not write into the visible cloud-storage tree, create fake placeholders, monitor it using FSEvents, or add a competing Finder Sync extension. It returns downloads through `NSFileProviderManager.temporaryDirectoryURL`, allowing macOS to take ownership on the correct volume.

Availability is expressed using `NSFileProviderContentPolicy`: root items default to lazy downloads, ordinary items inherit their parent's policy, and pinned items use eager downloads with retention. Overrides are stored per device. Newly added children inherit folder availability automatically. Changing a policy creates a catalog event and signals the working set. The app reads the system's global transfer progress for its menu bar.

The working set includes every exposed file and folder, including all materialized items. Metadata enumeration is local and paginated. Remote refreshes happen asynchronously so listing a cached directory does not wait for a full network scan. Opaque page tokens bind a container and keyset offset to an exact catalog anchor. Changed snapshots expire page tokens; durable change anchors continue until a database epoch changes or becomes invalid. Finder thumbnails come from the server's derivative endpoint without hydrating originals.

Primary sources: [Apple's replicated File Provider overview](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension), [synchronizing the extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension), [content policies](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy), and [custom context-menu actions](https://developer.apple.com/documentation/fileproviderui/adding-actions-to-the-context-menu).

## Unsupported files

Immich's reported image/video formats are the authority. Extension allowlists, MIME-to-extension fallback, and case normalization handle the server response without accepting every macOS image type. Sidecars are not uploaded as standalone assets.

Ordinary unsupported files and nested directories are represented by local-only catalog records with a native `NSFileProviderItemDecorating` overlay. Content is copied into durable application-group storage before completing the import. These records report `isUploaded = false` and use a keep-downloaded policy. They survive remote snapshots and are reparented into All Photos if their remote album disappears. Deleting one never issues an Immich request.

Packages and symlinks are refused using `excludedFromSync`, which keeps the system-owned local item. This error is deliberately not returned for an existing cloud asset: macOS can follow exclusion by requesting deletion of the remote counterpart. Rejected edits of existing originals report a synchronization error while preserving the original.

The badge uses an exported UTI conforming to `com.apple.icon-decoration.badge`, with an icon and a spoken/hover label. Apple's documented decoration and upload flags provide the integration; signed visual validation is still part of the release checklist.

Primary sources: [item decoration](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemdecorating), [item upload state](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/isuploaded), [excluded-from-sync behavior](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/code/excludedfromsync), and [Immich's supported formats](https://docs.immich.app/features/supported-formats/).

## API and data model

Immich is an asset library with many-to-many album membership. All Photos exposes each owned, unlocked, nontrashed asset once. Albums contains owned album folders, each with independent provider identities for its member appearances. The same asset ID is used for all remote mutations. Original content hashes define content versions; metadata versions are derived separately.

Uploads use disk-backed multipart bodies and a streaming SHA-1 checksum. Downloads use disk-backed URLSession transfers and verify the original hash before handing content to macOS. SHA-1 here matches Immich's content-deduplication protocol; it is not used as an authentication mechanism. Normal TLS validation is retained. Cross-origin and downgrade redirects cannot receive the API key; mutations are not replayed through redirects. Transient metadata reads retry with capped backoff. Mutations rely on system retry and server deduplication instead of blind automatic replay.

The client uses public API-key endpoints. It adapts legacy page-based search to the newer cursor/filter search. Search includes stack members and filters ownership. Only a completed remote pass is committed to SQLite. Missing previously known originals are checked individually before being removed, reducing offset-pagination races. A failed fetch leaves the previous catalog intact.

Content updates follow the supported upload-and-copy approach rather than the deprecated replacement endpoint. An edit journal records the target asset before copying associations or trashing the source. The source version is checked again before trashing it. No force deletion is performed. Trash availability and retention are checked immediately before requesting a trash operation. There is no atomic compare-and-delete API in Immich, so a final cross-client race remains possible.

Primary sources: [Immich API documentation](https://api.immich.app/), [current OpenAPI schema](https://github.com/immich-app/immich/blob/main/open-api/immich-openapi-specs.json), [versioned 2.5 schema](https://github.com/immich-app/immich/blob/v2.5.0/open-api/immich-openapi-specs.json), and [server deletion behavior](https://github.com/immich-app/immich/blob/main/server/src/services/asset.service.ts).

## Persistence and concurrency

SQLite runs in WAL mode with full synchronization and a busy timeout. Catalog changes and deletion tombstones commit atomically. Anchors include a database epoch plus a monotonic event sequence. A snapshot commit checks its starting anchor inside the transaction, rejecting a stale writer if another extension instance has published newer changes. The host app reads status and never rewrites the remote catalog.

An explicit asynchronous gate serializes complete snapshot and mutation operations across suspension points. An actor alone would permit reentrant network work and allow an older snapshot to overwrite a newer mutation. Pending operations can be canceled while waiting. Downloads remain concurrent, bounded by the File Provider pipeline and URLSession connection pool.

Only nonsecret configuration and local catalog data live in the application group. Credentials are stored in the shared, device-local Keychain access group and are reread when constructing requests, allowing key rotation without reusing stale authentication. Disconnect preserves downloaded and unsynced system-managed data. Durable local-only backing files are not automatically erased on disconnect.

The current full-library polling strategy favors correctness and compatibility. Efficient large-library synchronization, journal compaction, remote snapshot fencing, richer conflict UI, and process-kill integration tests remain follow-up work for production hardening.

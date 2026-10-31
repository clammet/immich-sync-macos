# Architecture

The client targets macOS 14 or later and the Immich 3.3.5 API contract.

## Components

| Component | Responsibilities |
| --- | --- |
| Menu bar app | Sign-in, account settings, status, periodic sync requests, and login startup |
| File Provider extension | Finder enumeration, thumbnails, downloads, uploads, mutations, and availability policies |
| ImmichCore | REST client, sync decoding, credential storage, SQLite catalog, and sync engine |

The app and extension share a Team-ID-prefixed App Group. Both use App Sandbox, outgoing network access, and Apple Development signing for local builds. Group registration and provisioning profiles are not required by the configured entitlements.

## Authentication and storage

Password sign-in uses `POST auth/login`. Browser sign-in uses the server's OAuth authorize/callback endpoints with PKCE, random state, and the `immich-sync://oauth` redirect. Authenticated requests carry the session token in the Authorization Bearer header.

The App Group contains:

- `session-account.json`: account identity, server URL, session ID, and settings.
- `Credentials`: session tokens bound to the account, server, user, and session.
- Per-account SQLite catalogs and local-only content.

The credentials directory uses mode `0700`; files use mode `0600`, current-user ownership, and no extended ACL. Reads are bounded and validate file type, links, and account binding. Writes create an exclusive temporary file, sync its contents, and atomically replace the destination. The directory is marked excluded from backup. FileVault supplies disk encryption; the client adds no encryption layer. Passwords, OAuth codes, and verifiers are not persisted.

Reauthentication replaces the active account/session, cancels the previous sync reader, and bootstraps the new session's checkpoints. Disconnect preserves downloaded user data, removes the credential, and attempts server-side session revocation.

## Server communication

| Endpoint | Use |
| --- | --- |
| `POST sync/stream` | Stream incremental metadata changes as newline-delimited JSON |
| `POST sync/ack` | Acknowledge committed checkpoints |
| `POST search/metadata` | Resolve original paths for batches of up to 100 asset IDs |
| Asset REST endpoints | Upload, download, thumbnails, metadata, association copying, and trash |
| Album REST endpoints | Album changes and membership updates |

The selected streams are `AssetsV2`, `AlbumsV2`, `AlbumUsersV1`, `AlbumToAssetsV1`, and `AssetExifsV1`. The decoder validates message types, checkpoints, and stream completion. HTTP requests use standard TLS validation and refuse redirects. Transient reads have bounded retries; mutations are not automatically replayed.

## Synchronization

1. A new replica bootstraps metadata into SQLite. Subsequent streams resume from saved checkpoints.
2. Batches of up to 256 events commit remote entities, path work, and acknowledgement outbox entries in one transaction.
3. The client sends committed acknowledgements and retries pending outbox entries on subsequent syncs.
4. A completed stream publishes metadata and drains queued path lookups. Failed lookups retain durable retry state with backoff.
5. A server reset builds a replacement generation and publishes it after stream completion. The visible catalog and local-only content remain available during the reset.

Session, generation, and revision checks reject stale work. Repeated updates coalesce by asset ID. Finder enumeration reads the local catalog. The menu bar app requests sync every minute; manual and Finder requests can trigger additional checks.

## Finder data

Original paths form the Folder View hierarchy under Server, Relative paths, or External Libraries. Missing or invalid paths appear under Unresolved paths. External-library media is read-only. The catalog includes eligible originals and albums owned by the connected user.

Asset appearances have stable IDs across path changes. Album appearances use separate IDs for the same original. Directory IDs include their path namespace and library identity. A local name index handles case, Unicode, and filename collisions. Availability settings are stored per appearance and inherited from parent folders.

The extension supplies working-set enumeration, paged changes, thumbnails, content, availability actions, and item decorations. macOS manages placeholders, hydration, and eviction. Change anchors contain a catalog epoch and sequence; expired anchors restart enumeration.

## Local operations

Uploads use disk-backed multipart bodies. Uploads and downloads verify SHA-1 checksums against Immich. Successful mutations update the affected catalog records; later server deltas reconcile them.

Edits upload and verify a replacement, copy supported associations, and trash the source. An edit journal records progress for interrupted operations. Album removal keeps originals. Library deletion uses Immich trash; force deletion is not implemented.

Unsupported ordinary files and custom folders have durable local content, a grey ignored badge, and a keep-downloaded policy. Packages and symlinks use File Provider exclusion. Removing remote content preserves local-only descendants.

SQLite uses WAL, full synchronization, and a busy timeout. It stores remote entities, Finder items and names, change events, checkpoints, path work, pins, and operation state.

## References

- [Immich 3.3.5 OpenAPI contract](https://github.com/immich-app/immich/blob/v3.3.5/open-api/immich-openapi-specs.json)
- [Immich sync service](https://github.com/immich-app/immich/blob/v3.3.5/server/src/services/sync.service.ts)
- [Immich authentication service](https://github.com/immich-app/immich/blob/v3.3.5/server/src/services/auth.service.ts)
- [Apple replicated File Provider](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)

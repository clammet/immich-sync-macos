# Native session and incremental sync architecture

The protocol contract is pinned to **Immich 3.3.5**, released 21 October 2026. The implementation uses one set of request/response formats and rejects other server versions. The source references below are pinned to that tag.

## Authentication

The containing app signs in through `auth/login` or the server's OAuth authorize/callback endpoints. A browser authentication session uses the `immich-sync://oauth` redirect, a cryptographically random state, and an S256 PKCE challenge. Redirect origin/path, state uniqueness, and authorization-code presence are checked before exchange.

The returned token authenticates requests using the Authorization Bearer header. The app retrieves the newly created current session ID and stores the token in a Keychain entry keyed by that session ID. The shared account file contains the session ID and nonsecret configuration. Passwords, OAuth codes, and verifiers are not persisted.

Reauthentication switches the shared account file atomically. Provider contexts validate both account and session identity before requests and catalog commits; a new token cannot be used to acknowledge the previous session's checkpoints. The registry cancels an obsolete sync reader and creates a context for the new session. Enumerators resolve the current context for each call. The new session bootstraps its own checkpoints while retaining the visible catalog until completion.

Disconnect removes the domain using Apple's preserve-downloaded-user-data mode, attempts to revoke the dedicated Immich session, and removes the local credential. A network failure during revocation does not prevent retaining local user data or forgetting the credential.

Sources: [authentication service](https://github.com/immich-app/immich/blob/v3.3.5/server/src/services/auth.service.ts), [authentication endpoints](https://github.com/immich-app/immich/blob/v3.3.5/server/src/controllers/auth.controller.ts), and [OAuth DTOs in the OpenAPI contract](https://github.com/immich-app/immich/blob/v3.3.5/open-api/immich-openapi-specs.json).

## Incremental replication

The requested streams are AssetsV2, AlbumsV2, AlbumUsersV1, AlbumToAssetsV1, and AssetExifsV1. Some current upstream formats retain a V1 name; the client implements only the selected current contract for each stream. It excludes unrelated partner, face, memory, and other streams.

`POST sync/stream` returns newline-delimited JSON. The framer accepts arbitrary packet/UTF-8 boundaries with a bounded maximum record size. The decoder validates entity names and acknowledgement types and handles current backfill/checkpoint markers. An unsupported record, incomplete line, missing terminal record, or data following completion fails the request.

A batch of at most 256 records updates normalized entities, affected Finder appearances, deletion tombstones, and a checkpoint outbox in one transaction. Only committed checkpoints are sent to `sync/ack`. Successful acknowledgement clears the matching outbox entries. A lost response leaves them pending, so they are resent before the next change window. Upserts and deletes are idempotent under replay.

Completion is committed only after a valid final marker and clean stream termination. Empty change checks update the completion checkpoint/status without changing Finder anchors or invalidating pages. The native stream is a finite response; the menu bar app schedules checks every minute, and manual or Finder activity can trigger a check sooner.

Sources: [sync endpoints](https://github.com/immich-app/immich/blob/v3.3.5/server/src/controllers/sync.controller.ts), [stream and reset semantics](https://github.com/immich-app/immich/blob/v3.3.5/server/src/services/sync.service.ts), [wire DTOs](https://github.com/immich-app/immich/blob/v3.3.5/server/src/dtos/sync.dto.ts), and [acknowledgement serialization](https://github.com/immich-app/immich/blob/v3.3.5/server/src/utils/sync.ts).

## Bootstrap and reset

A new local replica requests a native reset before consuming data, including when the local database is lost but a server session still exists. The accepted-reset flag is persisted when response headers are validated. An interrupted bootstrap can resume from its committed checkpoints without repeatedly clearing server progress.

A reset stages entities in a replacement generation. The existing Finder projection and local-only data remain available. Bootstrap records and checkpoints persist in bounded batches, but the replacement projection becomes visible only when SyncCompleteV1 is committed. Publication compares stable item identities, emits actual changes/deletions, preserves pin overrides, and reparents local-only children if their remote album disappeared. Old normalized generations are then removed.

A server SyncResetV1 restarts this same bootstrap path. Repeated resets in one attempt fail instead of looping indefinitely. Account/session guards inside catalog transactions reject a stale reader after reauthentication.

Source: [session progress reset transaction](https://github.com/immich-app/immich/blob/v3.3.5/server/src/repositories/session.repository.ts).

## Local changes

Uploads, downloads, album operations, association copying, and trash use the same authenticated REST client. Successful local operations update only the relevant normalized entities and Finder appearances. They never enumerate the remote library or force a global refresh. Server deltas later reconcile those rows normally.

Supported uploads use a disk-backed multipart body and streaming SHA-1 matching Immich's checksum protocol. Downloads verify original checksums before ownership passes to File Provider. SHA-1 is used for protocol integrity/deduplication, not authentication. Standard TLS validation remains enabled, redirects are refused, and mutations are not blindly replayed by the HTTP client.

Edited originals are uploaded and verified, associations are copied, and the source is checked again before trashing. The durable edit journal records progress before subsequent mutations. New Finder appearances inherit explicit pin overrides from the previous asset. No force deletion is requested. Server trash availability/retention are checked before trashing; Immich has no atomic compare-and-delete endpoint.

## File Provider and storage

The sandboxed SwiftUI menu bar app contains a replicated File Provider extension. macOS owns visible placeholders, hydration, and eviction. The extension supplies enumerators, content, thumbnails, custom availability actions, and item decorations. It returns originals through the manager's temporary directory on the managed volume. Availability uses native content policies, including inheritance for new children.

SQLite uses WAL, full synchronization, and a busy timeout. Asset, album, owner-role, membership, and EXIF tables support changes proportional to the affected entities. Only albums owned by the connected user and eligible originals owned by that user are projected. Finder identifiers remain stable per original/album appearance. Initial publication iterates stored source rows rather than retaining the whole library as an in-memory snapshot.

The working set includes every exposed item. Finder change anchors combine a database epoch and monotonic event sequence. Page tokens include their container, keyset offset, and anchor. Approximately 50,000 recent events are retained; older anchors explicitly expire and trigger normal Finder enumeration.

Unsupported ordinary files and nested directories have durable local-only rows/content, a grey native decoration, a not-uploaded flag, and keep-downloaded policy. They are never included in server checkpoint state. Packages and symlinks use native exclusion. The exclusion error is not returned for existing cloud originals because macOS may follow it with remote deletion.

Sources: [Apple replicated File Provider](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension), [working-set synchronization](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension), [content policy](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy), and [context-menu actions](https://developer.apple.com/documentation/fileproviderui/adding-actions-to-the-context-menu).

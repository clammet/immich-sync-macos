# Architecture

OpenCloud is authoritative for file identities, directory structure, bytes, revisions, permissions and multi-client conflicts. The File Provider never projects Immich assets or albums into the synchronization tree.

| Component | Responsibilities |
| --- | --- |
| Menu bar app | OpenCloud app-token setup, optional Immich setup/mappings, sharing/media actions, recovery, sync controls |
| File Provider extension | Cached enumeration, conditional downloads/mutations, native availability policies, Finder actions |
| ImmichCore | OpenCloud WebDAV/Libre Graph, SQLite catalog, recovery journal, separate Immich media-action client |

## Authentication and separation

The app and extension share an App Group. `opencloud-account.json` contains OpenCloud account metadata, and each account has an `opencloud-catalog.sqlite` catalog. `immich-actions-account.json` contains optional Immich session metadata. Tokens are held in the hardened credential store with account/server/user/session binding, owner-only permissions, atomic replacement, bounded reads, and symlink/ACL validation. Passwords and OAuth verifiers are not saved. OpenCloud's app token is sent with HTTP Basic authentication; optional Immich uses Bearer sessions or an API key header.

Production URL sessions have no cookie, credential, or response caches and refuse redirects, including transfer redirects. Server-provided DAV URLs, pagination URLs and OpenCloud sharing-result URLs must retain the configured origin. HTTP is a per-service explicit opt-in. Mutations are not automatically replayed after an ambiguous response.

## OpenCloud contract

| Interface | Use |
| --- | --- |
| Libre Graph `v1.0/me`, `v1.0/me/drives` | Validate identity and discover member spaces, including pagination |
| Space root's `webDavUrl` | Exact server-provided DAV endpoint |
| DAV `PROPFIND`, Depth 0/1 | Stable `oc:fileid`, ETags, names, directory structure, sizes, permissions and SHA-1 where supplied |
| DAV `GET` | Stream content to disk with `If-Match`, length/checksum verification |
| DAV `PUT` | Disk-backed upload, `OC-Checksum`, `If-None-Match: *` for creates, `If-Match` for edits |
| DAV `MKCOL` | Real server directories, without replacing an existing collection |
| DAV `MOVE` | Within-space rename/reparent with `If-Match`, `Overwrite: F` |
| DAV `DELETE` | Conditional deletion; server retention and trash policy apply |
| Libre Graph `v1beta1/drives/.../createLink` | Read-only public link for a file/folder or space root |
| Libre Graph item's `webUrl` | Server UI for sharing management |

In-place uploads preserve server identities and let OpenCloud maintain revisions. Cross-space moves, partial uploads and revision restore/browsing are currently outside the client contract.

## Metadata and Finder

A scan walks each member space with Depth 1 requests, staging records in SQLite. It checks directory ETags after scanning their descendants and verifies the complete space list again before publication. Malformed XML, per-resource failures, missing required properties, duplicate identities, path escapes, or changed directories abort the scan. Only a complete scan atomically replaces visible records. Cached items and recovery remain available on failure. Polling performs full metadata scans; no unsupported delta endpoint is assumed.

DAV parsing uses namespace URIs and validates paths as opaque POSIX components. Original remote paths remain in records independently of local display names. Finder IDs derive from the space and server file ID, so moves and renames retain identity. Normal names have no suffix. A local index honors the home volume’s case sensitivity and handles genuine case/canonical-Unicode collisions. Directory moves update descendant locators. Finder change anchors contain an epoch and event sequence, with old-parent departures and new-parent arrivals for moves.

SQLite uses WAL, full synchronization and a busy timeout. A cancellable operation gate serializes extension work, and a per-catalog file lock excludes overlapping mutation/scan work from other processes. Pins remain attached to stable IDs; File Provider supplies inherited, keep-downloaded and on-demand policies. macOS owns placeholders, hydration and eviction.

## Pending edits and conflicts

Every create/modify stages content and a recovery manifest before connectivity or revision checks. Manifest paths within the local recovery store are relative to an operation directory; a file named `operation.json` cannot overwrite its manifest because content has a separate subdirectory. Pending operations are keyed by source/destination/base version/content hash, making repeated retries reuse their recovery entry.

The server checks ETag preconditions atomically. A mismatch or destination collision returns a conflict and leaves both server content and local recovery intact. When a successful upload is durably recorded but a following move fails, a retry validates that result before resuming. An ambiguous successful mutation without a recorded result stays recoverable and may require manual resolution. A failed scan cannot remove recovery. Directory deletion is rejected while staged descendant edits exist. Marking an operation resolved removes its guard while keeping its recovery files.

Disconnect uses macOS's preserve-downloaded-user-data mode. Account catalogs and recovery remain on disk.

## Immich media actions

The optional Immich client exposes discovery/search, authentication, album creation and sharing links. It has no asset upload/delete API and no synchronization stream. SyncEngine accepts only `OpenCloudRemote`.

Discovery queries `libraries` and `search/metadata`. A library-permission denial allows sample-path discovery to continue. Import roots, exclusion patterns and original paths are evidence about the Immich server/container, not an OpenCloud space identity. The APIs provide no authoritative cross-service mount correlation, so the app asks the user to confirm the corresponding OpenCloud media root and exact Immich path. It never guesses a space from a suffix.

Mappings are scoped to the Immich server/user, support multiple roots/libraries, match complete path components and prefer the most specific confirmed root. Media selection searches exact `originalPath` and optional `libraryId`, validates exact results, rejects ambiguous/trashed/locked assets, and compares checksums when OpenCloud provides SHA-1. It sends deduplicated existing asset IDs to album/link creation. Folder actions report skipped unindexed/unmapped descendants; explicitly selected unresolved files fail before creation. Immich failures do not enter the OpenCloud sync engine.

Finder custom actions save their results in the catalog. The app observes and displays them for copying/opening without attempting forbidden UI launches from a non-UI extension.

## Contracts consulted

- [OpenCloud WebDAV API](https://docs.opencloud.eu/docs/dev/server/apis/http/webdav/)
- [OpenCloud app tokens](https://docs.opencloud.eu/docs/user/admin/app-tokens/)
- [OpenCloud Libre Graph contract](https://github.com/opencloud-eu/libre-graph-api/blob/main/api/openapi-spec/v1.0.yaml)
- [Immich 3.3.5 contract for optional media actions](https://github.com/immich-app/immich/blob/v3.3.5/open-api/immich-openapi-specs.json)
- [Apple replicated File Provider](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)

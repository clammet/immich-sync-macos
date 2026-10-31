# Integration testing

Use macOS 14 or later, Xcode, Python 3, Docker Engine, and modern Docker Compose (2.24.4 or later, for `!override`). The signed smoke test additionally needs an Apple Development identity and matching Team-ID-prefixed App Groups. Use FileVault for stored credentials and media.

## Disposable local server

The harness uses the [official v3.3.5 release Compose file](https://github.com/immich-app/immich/releases/download/v3.3.5/docker-compose.yml), vendored unchanged with a SHA-256 check. It runs the version-matched server and machine-learning images, official pinned VectorChord/pgvectors Postgres image, and pinned Valkey image. The override adds dependency health checks, isolated names/volumes, and localhost-only port publication. Machine-learning inference is disabled during seeding; that service still runs and must become healthy.

If Docker is unavailable locally, install/start Colima and Compose:

```sh
brew install colima docker docker-compose
colima start --cpu 4 --memory 6
docker context use colima
```

The harness supports the Compose plugin or Homebrew's modern `docker-compose` executable. It uses the active Docker context. No global pruning or unrelated container changes are performed.

```sh
python3 scripts/integration.py up      # start all services and wait for health/version
python3 scripts/integration.py ready   # check the HTTP API and exact server version
python3 scripts/integration.py seed    # create synthetic media, accounts, album, folders
python3 scripts/integration.py test    # reset this stack, seed, run unsigned live tests
python3 scripts/integration.py status
python3 scripts/integration.py logs
python3 scripts/integration.py server-stop
python3 scripts/integration.py server-start
python3 scripts/integration.py reset   # delete this stack's volumes/local test data; start and seed
python3 scripts/integration.py down    # remove containers; retain volumes/local test data
python3 scripts/integration.py clean   # remove this stack's containers, volumes, and local test data
```

Access the web UI at `http://127.0.0.1:22830`. To change the port, set `IMMICH_TEST_PORT` before the first startup; resets retain the selected port. The Compose project is always `immich-sync-integration`. Existing Immich environment variables cannot replace its pinned images, mounts, or credentials.

All generated files are under ignored `build/integration` (mode `0700`), including random disposable credentials in `config.json`/`.env` (mode `0600`), synthetic PNGs, external-library folders, seed IDs, local SQLite catalogs, `test.log`, and `result.json`. Postgres, uploads, and model cache use project-scoped Docker volumes. Seeding is idempotent after completion; use `reset` after an interrupted seed. Never use real accounts or media with this harness. `test` resets its disposable data on every invocation; ordinary `swift test` skips the live test.

## Automated live coverage

The opt-in XCTest calls production `ImmichAPI`, `SyncEngine`, `Catalog`, and `FileCredentialStore`. Assertions inspect both local state and real server responses; a separate login/catalog checks that client writes reached Immich. Fault wrappers drop responses or interrupt real stream delivery without faking server state.

| Area | Assertions |
| --- | --- |
| Authentication/storage | Accepted/rejected passwords, dedicated session identity, logout/revocation; credential round-trip, owner/mode/backup exclusion, deletion, catalog secret exclusion |
| Bootstrap/incremental | Originals, owned albums/memberships, external folder projection, foreign/locked filtering, server-side additions and album rename, idle sync without path searches |
| Media | Byte-exact originals, SHA-1 verification, rejection of incorrect checksum without delivering a file, decodable thumbnail |
| Uploads/albums | Production uploads and deduplication; creation, rename, membership move/removal, album deletion retaining originals |
| Edits/deletion | Replacement content, copied favorite/album associations, pin retention; lost copy response and restart without reupload; trash/restore and permanent server deletion |
| Recovery | Lost acknowledgement response/replay, interrupted stream completion, deleted server checkpoints, explicit reset, new catalog rebuild, stable appearances/local-only content retention, actual container stop/restart |

The stream interruption is at a decoded batch boundary; the copy/ack faults occur after the server succeeds. These do not test a truncated TCP byte stream or a process killed mid-upload. The dataset is small and synthetic, not a performance benchmark.

## Local checks

```sh
sh scripts/check.sh
```

Unsigned app and extension build for Apple Silicon and Intel:

```sh
xcodebuild -project ImmichSync.xcodeproj -scheme ImmichSync \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' build
```

## Signed main-app/provider smoke

```sh
python3 scripts/integration.py up
python3 scripts/integration.py seed
IMMICH_SIGNING_TEAM=YOUR_TEAM_ID python3 scripts/integration.py smoke
```

This performs one signed Debug build, verifies signatures, installs `~/Applications/Immich Sync Integration.app`, and registers its extension. It uses the isolated `app.immich.sync.integration` bundle prefix and App Group. On first use, enable **Immich Sync Integration** in System Settings → General → Login Items & Extensions → File Providers. The run times out after four minutes if macOS permission/enablement is still pending; enable it and rerun.

The Debug-only `--integration-smoke` entry point is restricted to the integration bundle and loopback HTTP. It invokes the main app's production password sign-in and disconnect, checks App Group credentials and session identity, accesses the actual File Provider root, waits for embedded-provider indexing, and coordinates a read of a materialized original with a known checksum. Disconnect must remove credentials and revoke the server session. No smoke hook is compiled into Release builds.

The app remains installed for manual checks. Production disconnect deliberately preserves downloaded content; remove the synthetic retained copy in Finder after inspection, and remove the integration app when finished. `clean` removes Docker data and unsigned test catalogs, not the installed app, its macOS container, or preserved downloads.

For an ordinary signed build, set `Config/Local.xcconfig` as described in the README:

```sh
xcodebuild -project ImmichSync.xcodeproj -scheme ImmichSync \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData build
python3 scripts/verify-signing.py 'build/DerivedData/Build/Products/Debug/Immich Sync.app'
```

The verification command checks the app and embedded extension signatures, matching Team-ID-prefixed App Groups, sandbox and network entitlements, Hardened Runtime, and absence of provisioning profiles.

## Verified locally

On 2026-11-01, Apple Silicon/macOS 26.6.2: the live suite and signed main-app/provider smoke passed against the disposable Immich 3.3.5 stack. The existing 76 unit tests passed, and unsigned app/extension builds passed for Apple Silicon and Intel. The signed smoke used profile-free Apple Development signing; macOS required the integration provider to be enabled once. Visual Finder interaction was not automated.

## Remaining manual/uncovered checks

- [ ] **Installation:** install the main app in Applications, enable the extension, and confirm one Finder location. Test Open in Finder, app/provider restarts, and a clean user account.
- [ ] **Authentication:** browser sign-in/cancellation, reauthentication, password-disabled servers, and a real OAuth provider using redirect `immich-sync://oauth` (callback/state validation has unit coverage).
- [ ] **Credential storage:** audit the signed App Group's ownership/ACLs and backup exclusion; check runtime logs and account metadata for secret leakage beyond the catalog checks above.
- [ ] **Incremental sync:** large libraries and concurrent changes beyond the synthetic live coverage above.
- [ ] **Recovery:** truncated network streams, process death mid-mutation, and stale work during live reauthentication (unit coverage exists).
- [ ] **Folder updates:** upload through Finder, mobile, and web; change storage templates and labels. Verify paths converge, appearance IDs remain stable, and downloaded content and pin settings survive moves.
- [ ] **Path handling:** test case/Unicode collisions, invalid or unavailable paths, relative paths, and multiple external libraries. Check ownership and locked-asset filtering and external-library read-only behavior.
- [ ] **Media access:** representative image/video formats, pinned File Provider content offline, and on-demand eviction.
- [ ] **Uploads:** Finder bulk uploads, large videos, quota exhaustion, HTTP 413, and interrupted transfers.
- [ ] **Edits:** process death mid-upload/trash, concurrent server edits, Finder pin behavior, and trash-disabled servers.
- [ ] **Albums and deletion:** repeat the automated mutations through Finder, including rejected operations and concurrent changes.
- [ ] **Local-only content:** test unsupported files, custom folders, packages, and symlinks. Verify ignored badges, local edits/deletion, and content retention across restarts, resets, and remote folder/album removal.
- [ ] **Controls and disconnect:** pause/resume, launch at login, offline disconnect, and retained Finder content after app/provider restarts.
- [ ] **Platform and accessibility:** test two supported macOS releases, VoiceOver, dark appearance, badges, transfer progress, and a notarized Developer ID release.
- [ ] **Performance:** record initial indexing, idle checks, bulk changes, and request counts with representative library and album sizes.

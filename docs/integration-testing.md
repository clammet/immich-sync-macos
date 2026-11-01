# Integration testing

`sh scripts/check.sh` builds the Swift package, runs local tests, regenerates the Xcode project, and validates property lists. Tests cover namespace-aware DAV parsing, exact path mapping, precondition headers, server identity continuity, multi-client conflicts, incomplete scans, durable recovery, interrupted upload/move resumption, permissions, availability policies, credential-store security, and provider registration.

The container end-to-end suite provisions disposable OpenCloud and Immich instances and runs the production Swift API clients, sync engine, SQLite catalog, recovery code and media actions. No Finder, File Provider, signing, UI automation, or Keychain setup is involved.

## Container end-to-end suite

On macOS 14 or later, install Swift (Xcode), Python 3, Docker Engine and Docker Compose v2 or later. Start Docker Desktop or Colima before running:

```sh
python3 scripts/container-e2e.py
```

The runner pins OpenCloud 9.0.0 and Immich v3.3.5, with Immich's PostgreSQL/VectorChord and Valkey dependencies. It creates a unique Compose project, random credentials, unused loopback ports and project-scoped named volumes. It provisions an OpenCloud personal space and one-hour app token, plus Immich admin/ordinary users and an external library. No existing accounts, directories or containers are reused. The first run downloads images; allow several GB of disk and roughly 6 GB of VM memory.

OpenCloud's POSIX volume is mounted read-only into Immich. Small generated PNG fixtures are uploaded **through the Swift TUS client**, then scanned by Immich from those actual originals. Machine learning, geocoding and update checks are disabled; they are unrelated to the integration being tested.

The suite covers:

- Space/user discovery, recursive metadata synchronization, independent client catalogs, unchanged scan anchors and catalog reopening.
- Creation, editing, disk downloads and byte equality for ordinary, empty and binary files, dotfiles, Unicode names and URL punctuation.
- File rename/reparent, remote directory moves with stable descendant IDs, recursive deletion and deletion events.
- Conditional update rejection, conflicting edits, recovery manifests and preserved bytes after reopening the database, recovery under a new name, and deletion guards.
- An upload followed by a destination-conflicting move, then resumption from its durable upload record without another upload.
- TUS replacement with empty content and loss of a real accepted PATCH response, followed by catalog/client reopening and resumption without replaying accepted bytes.
- OpenCloud file/folder sharing links and management URLs.
- Immich session login/logout, identity, API-key search, administrator library discovery and the ordinary-user permission fallback.
- Real asynchronous external-library indexing, confirmed path/library mappings, excluded and unindexed selections, ambiguous mappings, deduplicated folder selections, albums and sharing links containing the existing indexed IDs. A final asset query checks that no native copies were uploaded.
- A separate phase that stops the Immich container and repeats OpenCloud create/edit/move/share/download/delete operations.

The runner executes three suites even if one fails: functional `ContainerEndToEndTests`, upstream `ContainerUploadContractTests`, then `ContainerImmichOfflineTests` after stopping Immich. It writes each suite's exit status, individual test outcomes, expected-failure counts and synthetic protocol observations to `results.json` in the run's artifact directory. Any failed or skipped enabled suite makes the command exit unsuccessfully after cleanup.

**Known server failures:** the functional suite retains three strict `XCTExpectFailure` checks for OpenCloud 9.0.0's ignored conditional DELETE/MOVE and create-only upload headers. The separate upload contract suite uses normal failing assertions for [Reva #866](https://github.com/opencloud-eu/reva/issues/866) and [#959](https://github.com/opencloud-eu/reva/issues/959), so the complete container command currently exits with failure. It covers TUS create-only collisions, empty uploads, missing targets, wildcard/stale ETags, ten concurrent creation-with-upload races and two sessions that both start before final PATCH. Raw PUT requests appear only in diagnostic baseline probes reproducing #866; production code and fixtures use TUS. See the [TUS test report](tus-testing.md) for observations. A green functional suite with expected failures does not establish atomic conflict protection.

Immich external-library checksums hash the original path, not its contents. Media actions validate exact paths/library IDs and pending-edit guards for external assets; content checksum comparison applies only to native assets. These tests do not establish that Immich metadata has refreshed after every content edit.

All project containers, networks and volumes are removed on success, failure, Ctrl-C or SIGTERM. Test output and the last 200 log lines per container are saved under `build/container-e2e/<project>/`; generated passwords and the app token are redacted from container diagnostics. Override this with `--artifacts <directory>` or adjust service-readiness waits with `--timeout <seconds>`. A hard kill or host crash cannot run cleanup; remove only the printed project's resources with `docker compose --project-name <project> --file Tests/Containers/compose.yml down --volumes` (supply temporary `E2E_PASSWORD`, `E2E_OPENCLOUD_PORT` and `E2E_IMMICH_PORT` values for Compose interpolation).

Ordinary `swift test` runs explicitly skip these tests. `scripts/check.sh` remains independent of a container runtime; run the container command as an additional check on a Mac with Docker available.

## Live OpenCloud API suite

Run a disposable OpenCloud server on loopback with an app token for a writable test space. This is a test-only account. Its server configuration must support the published WebDAV and Libre Graph endpoints. The suite creates and removes only a UUID-named test directory.

Set these environment variables without saving credentials in tracked files:

- `OPENCLOUD_INTEGRATION=1`
- `OPENCLOUD_TEST_SERVER` — loopback base URL
- `OPENCLOUD_TEST_USERNAME` — app-token login name
- `OPENCLOUD_TEST_TOKEN` — app token
- `OPENCLOUD_TEST_SPACE` — optional exact space ID; otherwise the first member space

```sh
python3 scripts/integration.py test
```

The suite checks ordinary-file upload/download, a second client's edit, server rejection of stale writes/deletes, preserved local recovery, server-side rename identity, and sharing links. Without the opt-in it skips explicitly. Loopback is required to keep live mutations away from production accounts. No Docker daemon or live credentials are assumed by the default suite.

## Signed provider smoke

Build a separately signed Debug app with a bundle prefix ending in `.integration` and install it in Applications. Enable its File Provider in System Settings. Use the executable/product filename configured by the build scripts.

Set `OPENCLOUD_SMOKE_SERVER` to a disposable HTTP loopback server, `OPENCLOUD_SMOKE_USERNAME`, and `OPENCLOUD_SMOKE_TOKEN`. Also set `OPENCLOUD_SMOKE_ITEM` to an existing Finder catalog ID (`cloud:` plus the SHA-256 of space ID, NUL and DAV file ID), and `OPENCLOUD_SMOKE_CHECKSUM` to the file's base64 SHA-1. Launch the signed app executable with `--integration-smoke`.

The harness exercises main-app setup, cross-process credential access, actual provider enumeration, coordinated hydration/checksum verification, and disconnect with preserved data. App-token revocation remains a server settings action. Run this only with the separately identified disposable integration app/account.

## Manual Finder and Immich checks

1. Browse at least two spaces; create ordinary files, dotfiles and nested folders. Confirm server names match unless the local filesystem requires disambiguation.
2. Rename/reparent files and directories within a space. Check stable placeholders, descendant paths and inherited availability. Exercise a case-only rename separately; destination collision remains a recoverable failure if the server rejects it.
3. Hydrate a file, pin a nested folder, then go offline. Confirm pinned files open and online-only files report availability errors. Reconnect and verify edits synchronize.
4. Edit one file on two clients. Confirm the stale client preserves its edit and the server retains its newer version/history. Test upload-response loss, app/extension restart, failed rename after successful upload, and recovery with a new name.
5. Delete a directory containing pending edits; confirm rejection. Mark a recovered entry resolved after copying it, and confirm its recovery files remain.
6. Create file/folder OpenCloud links from both app and Finder; copy/open results in the app. Open sharing management and exercise server policy failures.
7. Configure Immich to index the same backing media through an external library. Discover paths as admin and non-admin. Confirm container-prefix differences require a confirmed mapping and never infer a space by suffix.
8. Configure multiple roots/libraries. Create albums and media links from a folder and multiple files. Verify existing asset IDs are used, duplicate native originals are absent, skipped files are reported, and ambiguous/unindexed explicit selections fail.
9. Stop/disconnect Immich and use OpenCloud create/edit/move/share operations outside the media roots. Confirm they remain available.
10. Disconnect an OpenCloud account with downloaded and unsynced files. Inspect both preserved downloads and retained Recovery folders.

Local tests do not establish that these signed Finder workflows or a particular deployment's WebDAV precondition implementation passed. Record the OpenCloud/Immich versions and signed build used when running this checklist.

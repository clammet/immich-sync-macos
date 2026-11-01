# Integration testing

`sh scripts/check.sh` builds the Swift package, runs local tests, regenerates the Xcode project, and validates property lists. Tests cover namespace-aware DAV parsing, exact path mapping, precondition headers, server identity continuity, multi-client conflicts, incomplete scans, durable recovery, interrupted upload/move resumption, permissions, availability policies, credential-store security, and provider registration.

Live sync tests use a disposable OpenCloud instance. Immich action contract tests use indexed IDs and never exercise a native media upload path.

## Live OpenCloud API suite

Run a disposable OpenCloud server on loopback with an app token for a writable test space. This is a test-only account. Its server configuration must support the published WebDAV and Libre Graph endpoints. The suite creates and removes only a UUID-named test directory.

Set these environment variables without saving credentials in tracked files:

- `OPENCLOUD_INTEGRATION=1`
- `OPENCLOUD_TEST_SERVER` — loopback base URL
- `OPENCLOUD_TEST_USERNAME` — app-token login name or user UUID
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

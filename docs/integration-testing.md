# Integration testing

Use macOS 14 or later, FileVault, a signed app and extension with matching Team-ID-prefixed App Groups, and a disposable Immich 3.3.5 account/library. Configure the OAuth redirect as `immich-sync://oauth` for browser sign-in tests.

## Verified locally

- The main app and extension build and sign for Apple Silicon and Intel with matching Team IDs, sandbox entitlements, Hardened Runtime, and no provisioning profiles.
- An isolated signed File Provider diagnostic reads a dummy token through the production credential store, enumerates in Finder, and supplies a readable file.

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

## Signed build

Set `Config/Local.xcconfig` as described in the README, then build and verify:

```sh
xcodebuild -project ImmichSync.xcodeproj -scheme ImmichSync \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData build
python3 scripts/verify-signing.py 'build/DerivedData/Build/Products/Debug/Immich Sync.app'
```

The verification command checks the app and embedded extension signatures, matching Team-ID-prefixed App Groups, sandbox and network entitlements, Hardened Runtime, and absence of provisioning profiles.

## Pending integration checks

- [ ] **Installation:** install the main app in Applications, enable the extension, and confirm one Finder location. Test Open in Finder, app/provider restarts, and a clean user account.
- [ ] **Authentication:** test password and browser sign-in, cancellation, rejected credentials, revoked sessions, and reauthentication. Verify OAuth callback/state validation and password-disabled server behavior.
- [ ] **Credential storage:** verify directory mode `0700`, file mode `0600`, current-user ownership, no extended ACL, and backup exclusion. Check that logs, account metadata, and the catalog contain no tokens or passwords.
- [ ] **Incremental sync:** bootstrap a large library, then add, edit, trash, restore, and permanently delete assets on the server. Check album and membership changes. Verify idle checks make no path metadata requests.
- [ ] **Recovery:** interrupt streams and acknowledgements, reset the server session, and rebuild a missing local catalog. Verify checkpoint recovery, visible content retention, and rejection of stale work during reauthentication.
- [ ] **Folder updates:** upload through Finder, mobile, and web; change storage templates and labels. Verify paths converge, appearance IDs remain stable, and downloaded content and pin settings survive moves.
- [ ] **Path handling:** test case/Unicode collisions, invalid or unavailable paths, relative paths, and multiple external libraries. Check ownership and locked-asset filtering and external-library read-only behavior.
- [ ] **Media access:** browse thumbnails, open supported image/video formats, verify download checksums, and test pinned content offline and on-demand eviction.
- [ ] **Uploads:** test bulk uploads, deduplication, large videos, quota exhaustion, HTTP 413, server downtime, and interrupted transfers.
- [ ] **Edits:** interrupt upload/copy/trash operations and test recovery, concurrent server edits, pin retention, and trash-disabled behavior.
- [ ] **Albums and deletion:** verify album creation, rename, membership moves/removal, and deletion. Check that album deletion retains originals and library deletion uses trash.
- [ ] **Local-only content:** test unsupported files, custom folders, packages, and symlinks. Verify ignored badges, local edits/deletion, and content retention across restarts, resets, and remote folder/album removal.
- [ ] **Controls and disconnect:** test pause/resume and launch at login. Disconnect online and offline; verify local data retention, credential removal, and session revocation when reachable.
- [ ] **Platform and accessibility:** test two supported macOS releases, VoiceOver, dark appearance, badges, transfer progress, and a notarized Developer ID release.
- [ ] **Performance:** record initial indexing, idle checks, bulk changes, and request counts with representative library and album sizes.

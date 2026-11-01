# Immich Sync for macOS

A menu bar app that displays Immich photos, videos, and albums in Finder using Apple's File Provider framework.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Immich **3.3.5**.
- Xcode with macOS support for building.
- FileVault enabled.

## Connect

Enter your server URL and sign in with email/password or your server's OAuth provider. HTTPS is the default; HTTP can be enabled for a trusted local server.

For browser sign-in, add this redirect URI to the identity provider's Immich OAuth client:

```text
immich-sync://oauth
```

Each connection uses a dedicated Immich session. Its token is stored in an App Group file with owner-only permissions, shared by the app and extension. Passwords are not saved.

## Supported operations

| Feature | Behavior |
| --- | --- |
| Folder View | Browse media in its server-managed folder hierarchy |
| Albums | Browse, create, rename, and delete albums |
| On-demand access | Download originals when opened; fetch thumbnails separately |
| Offline availability | Keep files or folders downloaded, or allow on-demand eviction |
| Uploads | Add supported media through Folder View or an album |
| Album membership | Add, move, or remove album appearances while keeping originals |
| Media edits | Upload a replacement, copy supported associations, and trash the previous original |
| Library deletion | Move media deleted from Folder View to Immich trash |
| Unsupported files | Keep ordinary files and custom folders locally with a grey ignored badge |
| Sync controls | Sync now, pause/resume, and launch at login |

The extension exchanges changes with Immich over its sync stream and REST API. It maintains a local SQLite catalog for Finder. The menu bar app requests updates every minute while running; Finder activity can also trigger updates.

Folder View follows Immich's current paths and storage template. External libraries are read-only. Unsupported items remain on this Mac and are not backed up to Immich. Packages and symlinks are excluded.

Disconnecting preserves downloaded and unsynced files, removes the local credential, and attempts to revoke the session.

## Limits and validation

- One connected account and one Finder location on the Mac's home volume.
- Only the connected user's eligible originals and owned albums are shown. Locked assets are excluded.
- Server folders and original filenames cannot be renamed or reorganized in Finder. Albums cannot be nested.
- Media edits and library deletions require Immich trash with a positive retention period. Permanent deletion is not implemented.
- Finder tags, resource forks, new Live Photo pairing, and rendered non-destructive Immich edits are not synchronized.
- Faces, share links, and stacks are not transferred to edited replacements.
- The integration suite tests sync and mutations against a disposable Immich 3.3.5 server. A signed app/provider smoke test checks sign-in, enumeration, original downloads, and disconnect. Visual Finder workflows and OAuth integration testing remain pending; see [integration testing](docs/integration-testing.md).

## Build and run

1. Install full Xcode and select it as the active developer toolchain.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Set your development team and a unique bundle identifier.
3. Build the **ImmichSync** scheme in `ImmichSync.xcodeproj`. Both targets use manual Apple Development signing, no provisioning profile, and the same Team-ID-prefixed App Group.
4. Install the app in Applications and launch it. Use the setup window to sign in, then enable the File Provider in System Settings when prompted.

Build an Apple Development-signed DMG for this Mac with:

```sh
python3 scripts/build-dmg.py --team YOUR_TEAM_ID
```

See [developer DMGs](docs/distribution.md) for signing requirements and installation checks. 

Run local build, test, and project checks with:

```sh
sh scripts/check.sh
```

See [architecture](docs/architecture.md) for implementation details and [integration testing](docs/integration-testing.md) for signed bundle verification and the live test checklist.

This project is an independent Immich client.

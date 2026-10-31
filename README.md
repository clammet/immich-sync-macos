# Immich Sync for macOS

A native menu bar client that connects Immich to Finder using Apple's File Provider framework. Browse your library, open media on demand, upload files, and keep selected items available offline.

## Requirements

- macOS 14 or later.
- Immich **3.3.5**.
- Xcode with macOS support for building.
- FileVault enabled.

## Connect

Enter your server URL and sign in with email/password or your server's OAuth provider. HTTPS is the default; HTTP can be enabled for a trusted local server.

For browser sign-in, add this redirect URI to the identity provider's Immich OAuth client:

```text
immich-sync://oauth
```

Each connection uses a dedicated Immich session. Its token is stored in a protected file shared by the app and extension. Passwords are never saved.

## Implemented

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

The extension exchanges changes with Immich over its native sync stream and REST API. It maintains a local SQLite catalog for Finder. The menu bar app requests updates every minute while running; Finder activity can also trigger updates.

Folder View follows Immich's current paths and storage template. External libraries are read-only. Unsupported items remain on this Mac and are not backed up to Immich. Packages and symlinks are excluded.

Disconnecting preserves downloaded and unsynced files, removes the local credential, and attempts to revoke the session.

## Limits and validation

- One connected account and one Finder location on the Mac's home volume.
- Only the connected user's eligible originals and owned albums are shown. Locked assets are excluded.
- Server folders and original filenames cannot be renamed or reorganized in Finder. Albums cannot be nested.
- Media edits and library deletions require Immich trash with a positive retention period. Permanent deletion is not implemented.
- Finder tags, resource forks, new Live Photo pairing, and rendered non-destructive Immich edits are not synchronized.
- Faces, share links, and stacks are not transferred to edited replacements.
- Full-app Finder workflows, live-server sync, and OAuth integration testing are pending. An isolated Finder diagnostic has verified shared credential access, enumeration, and file retrieval.

## Build and run

1. Install full Xcode and select it as the active developer toolchain.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Set your development team and a unique bundle identifier.
3. Build the **ImmichSync** scheme in `ImmichSync.xcodeproj`. Both targets use manual Apple Development signing, no provisioning profile, and the same Team-ID-prefixed App Group.
4. Install the app in Applications, launch it, enable the extension if prompted, and connect through the menu bar item.

Run local build, test, and project checks with:

```sh
sh scripts/check.sh
```

See [architecture](docs/architecture.md) for implementation details and [integration testing](docs/integration-testing.md) for signed bundle verification and the live test checklist.

This project is an independent Immich client.

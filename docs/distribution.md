# Developer DMG

```sh
python3 scripts/build-dmg.py --team YOUR_TEAM_ID
```

Use the Team ID for an installed **Apple Development** certificate/private key. `IMMICH_SIGNING_TEAM` can supply the same value. A free Xcode Personal Team is sufficient; this build does not use notarization or require paid program membership. `--identity 'Apple Development: …'` selects a specific identity when several are installed. `--bundle-prefix` changes the default `app.immich.sync`; keep the same team and prefix for updates so existing credentials and Finder locations remain accessible.

The script builds Release for Apple Silicon only, verifies app/extension signatures, App Groups and architectures, and creates/signs a compressed DMG. It mounts the image read-only and checks the complete payload for scripts. The output is `build/DMG/Immich-Sync-VERSION-development.dmg`. Build and staging files stay in ignored `build/DMG`.

The DMG contains `Immich Sync.app` and an Applications shortcut. Drag the app into Applications, eject the image, and launch the installed copy.

On first launch, the app opens setup. After sign-in, it registers a Finder location and prompts you to enable the provider in System Settings. It restores a missing location and retries registration through domain-change notifications and periodic checks. Launching from the mounted DMG asks you to install the app first.

For installation checks, confirm setup opens, connect with an OpenCloud app token, enable File Providers, and check Finder shows one location. Quit/relaunch, disable/re-enable the provider, and verify an update reuses the account/domain. Run the signed smoke and manual checks in [integration testing](integration-testing.md); an unsigned build or local unit-test result does not verify a new DMG installation.

This is an unnotarized developer build for local use. 
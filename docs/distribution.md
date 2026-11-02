# Developer DMG

```sh
python3 scripts/build-dmg.py
```

The script uses Xcode's resolved Release settings, including `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`, `OPENCLOUD_BUNDLE_PREFIX`, and `OPENCLOUD_APP_GROUP` from `Config/Local.xcconfig`. Copy `Config/Local.xcconfig.example` to that ignored file and set your Team ID and bundle prefix once for both Xcode and DMG builds.

Use the Team ID for an installed **Apple Development** certificate/private key. `--team YOUR_TEAM_ID` overrides `OPENCLOUD_SIGNING_TEAM`, which overrides the configured `DEVELOPMENT_TEAM`. A free Xcode Personal Team is sufficient; this build does not use notarization or require paid program membership. `--identity 'Apple Development: …'` overrides the configured signing identity when several are installed. `--bundle-prefix` overrides the configured bundle prefix. The App Group follows the Xcode configuration; the example derives it from the selected team and bundle prefix.

The script builds Release for Apple Silicon only, verifies app/extension signatures, App Groups and architectures, and creates/signs a compressed DMG. It mounts the image read-only and checks the complete payload for scripts. The output is `build/DMG/OpenCloud-Sync-VERSION-development.dmg`. Build and staging files stay in ignored `build/DMG`.

By default, output includes build warnings and errors, brief progress messages, and the final DMG path. Use `python3 scripts/build-dmg.py --verbose` for full Xcode and disk image tool output. Tool stderr remains visible in both modes, and captured stdout is printed if a command fails.

On a clean build, Xcode may report `Metadata extraction skipped, no AppIntents.framework dependency found` for the app and extension. Neither target implements App Intents, so there is no metadata to extract and no missing dependency to add. This harmless Xcode diagnostic is unrelated to the File Provider architecture. Swift's complete concurrency checking remains enabled; compiler concurrency warnings should be addressed.

Some Xcode versions also log that the `Any Mac` destination is missing `operatingSystemVersion`. The message refers to Xcode's generic destination placeholder. The build script explicitly selects `arm64` and verifies the resulting app and extension architectures.

The DMG contains `OpenCloud Sync.app` and an Applications shortcut. Drag the app into Applications, eject the image, and launch the installed copy.

On first launch, the app opens setup. After sign-in, it registers a Finder location and prompts you to enable the provider in System Settings. It restores a missing location and retries registration through domain-change notifications and periodic checks. Launching from the mounted DMG asks you to install the app first.

For installation checks, confirm setup opens, connect with an OpenCloud app token, enable File Providers, and check Finder shows one location. Quit/relaunch, disable/re-enable the provider, and verify an update reuses the account/domain. Run the signed smoke and manual checks in [integration testing](integration-testing.md); an unsigned build or local unit-test result does not verify a new DMG installation.

This is an unnotarized developer build for local use.

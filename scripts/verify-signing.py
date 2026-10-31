#!/usr/bin/env python3
"""Verify the local app and provider's profile-free signing configuration."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path


def codesign(*args):
    return subprocess.run(["codesign", *map(str, args)], check=True, capture_output=True)


def info(bundle):
    return plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())


def verify(app):
    provider = app / "Contents" / "PlugIns" / "ImmichFileProvider.appex"
    bundles = (app, provider)
    if not all(bundle.is_dir() for bundle in bundles):
        raise ValueError("Expected Immich Sync.app with its embedded ImmichFileProvider.appex.")
    if any(path.suffix in (".provisionprofile", ".mobileprovision") for path in app.rglob("*")):
        raise ValueError("The local build must not contain provisioning profiles.")
    codesign("--verify", "--deep", "--strict", app)
    group = info(app).get("ImmichAppGroup")
    if not isinstance(group, str):
        raise ValueError("The app is missing its App Group configuration.")
    expected = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.security.application-groups": [group],
    }
    teams = set()
    for bundle in bundles:
        details = codesign("--display", "--verbose=4", bundle).stderr.decode()
        team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", details, re.M)
        if not team or not group.startswith(team[1] + "."):
            raise ValueError(f"{bundle.name}: App Group prefix must match the signing Team ID.")
        teams.add(team[1])
        if not re.search(r"^CodeDirectory .*\bruntime\b", details, re.M):
            raise ValueError(f"{bundle.name}: Hardened Runtime is missing.")
        entitlements = plistlib.loads(codesign("--display", "--entitlements", "-", "--xml", bundle).stdout)
        # Xcode enables debugger access in Debug builds; this entitlement needs no profile.
        debugger_access = entitlements.pop("com.apple.security.get-task-allow", False)
        if not isinstance(debugger_access, bool) or entitlements != expected:
            raise ValueError(f"{bundle.name}: unexpected signed entitlements.")
        if info(bundle).get("ImmichAppGroup") != group:
            raise ValueError(f"{bundle.name}: App Group configuration differs between targets.")
    if len(teams) != 1:
        raise ValueError("App and provider must have matching signing Team IDs.")
    if info(provider).get("NSExtension", {}).get("NSExtensionFileProviderDocumentGroup") != group:
        raise ValueError("The provider's document group differs from the shared App Group.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Path to the built Immich Sync.app")
    args = parser.parse_args()
    try:
        verify(args.app)
    except subprocess.CalledProcessError as error:
        parser.exit(1, "FAIL: " + error.stderr.decode(errors="replace"))
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print("PASS: valid app and provider signatures, matching Team-ID App Groups, sandbox, Hardened Runtime, and no provisioning profiles.")


if __name__ == "__main__":
    main()

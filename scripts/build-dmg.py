#!/usr/bin/env python3
"""Build an Apple Development-signed Apple Silicon app and drag-to-Applications developer DMG."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build/DMG"


def run(*args, capture=False):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True,
                          stdout=subprocess.PIPE if capture else None, text=capture)


def verify_payload(folder):
    entries = {p.name for p in folder.iterdir()}
    if entries != {"Immich Sync.app", "Applications"}:
        raise RuntimeError(f"Unexpected DMG contents: {sorted(entries)}")
    link = folder / "Applications"
    applications = Path(os.path.abspath(os.sep)) / "Applications"
    if not link.is_symlink() or link.resolve() != applications:
        raise RuntimeError("The Applications shortcut is missing or incorrect")
    app = folder / "Immich Sync.app"
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as file:
                if path.suffix.lower() in {".sh", ".bash", ".zsh", ".py", ".command", ".applescript", ".scpt"} or file.read(2) == b"#!":
                    raise RuntimeError(f"Scripts must not ship in the DMG: {path.relative_to(folder)}")
    run(sys.executable, "scripts/verify-signing.py", app)


def build(args):
    if not args.team or not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        raise RuntimeError("Set IMMICH_SIGNING_TEAM or pass --team with your Apple signing Team ID")
    identity = args.identity or "Apple Development"
    if not identity.startswith("Apple Development"):
        raise RuntimeError("This developer DMG uses an Apple Development identity")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    if identity not in identities:
        raise RuntimeError(f"No usable {identity} signing identity/private key is installed in the keychain")
    WORK.mkdir(parents=True, exist_ok=True)
    run(sys.executable, "scripts/generate-project.py")
    run("xcodebuild", "-project", "ImmichSync.xcodeproj", "-scheme", "ImmichSync", "-configuration", "Release",
        "-destination", "generic/platform=macOS", "-derivedDataPath", WORK / "DerivedData",
        "ONLY_ACTIVE_ARCH=NO", "ARCHS=arm64", "DEVELOPMENT_TEAM=" + args.team,
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
        "CODE_SIGN_IDENTITY=" + identity, "IMMICH_BUNDLE_PREFIX=" + args.bundle_prefix,
        "IMMICH_APP_GROUP=" + args.team + "." + args.bundle_prefix, "build")
    built = WORK / "DerivedData/Build/Products/Release/Immich Sync.app"
    run(sys.executable, "scripts/verify-signing.py", built)
    for executable in [built / "Contents/MacOS/Immich Sync",
                       built / "Contents/PlugIns/ImmichFileProvider.appex/Contents/MacOS/ImmichFileProvider"]:
        architectures = set(run("lipo", "-archs", executable, capture=True).stdout.split())
        if architectures != {"arm64"}:
            raise RuntimeError(f"Apple Silicon-only binary required: {executable.name}: {architectures}")
    info = plistlib.loads((built / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise RuntimeError("Invalid release version")
    output = WORK / f"Immich-Sync-{version}-development.dmg"
    with tempfile.TemporaryDirectory(prefix="payload-", dir=WORK) as temporary:
        payload = Path(temporary)
        app = payload / "Immich Sync.app"
        run("ditto", built, app)
        (payload / "Applications").symlink_to(Path(os.path.abspath(os.sep)) / "Applications", target_is_directory=True)
        verify_payload(payload)
        run("hdiutil", "create", "-volname", "Immich Sync", "-srcfolder", payload, "-format", "UDZO", "-ov", output)
    run("codesign", "--sign", identity, "--timestamp=none", output)
    run("hdiutil", "verify", output)
    mount = WORK / "verify-mount"
    mount.mkdir(exist_ok=True)
    attached = False
    try:
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, output)
        attached = True
        verify_payload(mount)
    finally:
        if attached:
            run("hdiutil", "detach", mount)
        mount.rmdir()
    print(f"Developer DMG: {output.relative_to(ROOT)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", default=os.environ.get("IMMICH_SIGNING_TEAM"))
    parser.add_argument("--identity", help="Full signing identity name; defaults to Apple Development")
    parser.add_argument("--bundle-prefix", default="app.immich.sync")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_prefix):
        parser.error("Invalid bundle prefix")
    try:
        build(args)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"DMG build failed: {error}\n")


if __name__ == "__main__":
    main()

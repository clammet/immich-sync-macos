#!/usr/bin/env python3
"""Build an Apple Development-signed Apple Silicon app and drag-to-Applications developer DMG."""
import argparse
import json
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
    try:
        return subprocess.run(list(map(str, args)), cwd=ROOT, check=True,
                              stdout=subprocess.PIPE if capture else None, text=capture)
    except subprocess.CalledProcessError as error:
        # Captured stdout may contain diagnostics; stderr always stays visible.
        if capture and error.stdout:
            print(error.stdout, end="", file=sys.stderr)
        raise


def xcodebuild_command(args):
    command = ["xcodebuild", "-project", "OpenCloudSync.xcodeproj", "-scheme", "OpenCloudSync",
               "-configuration", "Release", "-destination", "generic/platform=macOS",
               "-derivedDataPath", WORK / "DerivedData", "ONLY_ACTIVE_ARCH=NO", "ARCHS=arm64",
               "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"]
    if not args.verbose:
        command.append("-quiet")
    for setting, value in [("DEVELOPMENT_TEAM", args.team), ("CODE_SIGN_IDENTITY", args.identity),
                           ("OPENCLOUD_BUNDLE_PREFIX", args.bundle_prefix)]:
        if value is not None:
            command.append(setting + "=" + value)
    return command


def resolved_build_settings(command):
    # Let Xcode evaluate xcconfig includes, conditional settings, and variable references.
    targets = json.loads(run(*command, "-showBuildSettings", "-json", capture=True).stdout)
    for target in targets:
        if target.get("target") == "OpenCloudSync":
            return target["buildSettings"]
    raise RuntimeError("Xcode did not return build settings for the OpenCloudSync app target")


def verify_payload(folder, verbose=False):
    entries = {p.name for p in folder.iterdir()}
    if entries != {"OpenCloud Sync.app", "Applications"}:
        raise RuntimeError(f"Unexpected DMG contents: {sorted(entries)}")
    link = folder / "Applications"
    applications = Path(os.path.abspath(os.sep)) / "Applications"
    if not link.is_symlink() or link.resolve() != applications:
        raise RuntimeError("The Applications shortcut is missing or incorrect")
    app = folder / "OpenCloud Sync.app"
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as file:
                if path.suffix.lower() in {".sh", ".bash", ".zsh", ".py", ".command", ".applescript", ".scpt"} or file.read(2) == b"#!":
                    raise RuntimeError(f"Scripts must not ship in the DMG: {path.relative_to(folder)}")
    run(sys.executable, "scripts/verify-signing.py", app, capture=not verbose)


def build(args):
    print("Preparing build settings...", flush=True)
    WORK.mkdir(parents=True, exist_ok=True)
    run(sys.executable, "scripts/generate-project.py", capture=not args.verbose)
    command = xcodebuild_command(args)
    settings = resolved_build_settings(command)
    team = settings.get("DEVELOPMENT_TEAM", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise RuntimeError("Set DEVELOPMENT_TEAM in Config/Local.xcconfig, set OPENCLOUD_SIGNING_TEAM, "
                           "or pass --team with your 10-character Apple signing Team ID")
    identity = settings.get("CODE_SIGN_IDENTITY", "")
    if not identity.startswith("Apple Development"):
        raise RuntimeError("This developer DMG uses an Apple Development identity")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    if identity not in identities:
        raise RuntimeError(f"No usable {identity} signing identity/private key is installed in the keychain")
    print("Building Release app (arm64)...", flush=True)
    run(*command, "build")
    built = WORK / "DerivedData/Build/Products/Release/OpenCloud Sync.app"
    print("Verifying app signatures and architectures...", flush=True)
    run(sys.executable, "scripts/verify-signing.py", built, capture=not args.verbose)
    for executable in [built / "Contents/MacOS/OpenCloud Sync",
                       built / "Contents/PlugIns/OpenCloudFileProvider.appex/Contents/MacOS/OpenCloudFileProvider"]:
        architectures = set(run("lipo", "-archs", executable, capture=True).stdout.split())
        if architectures != {"arm64"}:
            raise RuntimeError(f"Apple Silicon-only binary required: {executable.name}: {architectures}")
    info = plistlib.loads((built / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise RuntimeError("Invalid release version")
    output = WORK / f"OpenCloud-Sync-{version}-development.dmg"
    print("Creating developer DMG...", flush=True)
    with tempfile.TemporaryDirectory(prefix="payload-", dir=WORK) as temporary:
        payload = Path(temporary)
        app = payload / "OpenCloud Sync.app"
        run("ditto", built, app)
        (payload / "Applications").symlink_to(Path(os.path.abspath(os.sep)) / "Applications", target_is_directory=True)
        verify_payload(payload, verbose=args.verbose)
        run("hdiutil", "create", "-volname", "OpenCloud Sync", "-srcfolder", payload, "-format", "UDZO", "-ov", output,
            capture=not args.verbose)
    run("codesign", "--sign", identity, "--timestamp=none", output)
    print("Verifying DMG and mounted payload...", flush=True)
    run("hdiutil", "verify", output, capture=not args.verbose)
    mount = WORK / "verify-mount"
    mount.mkdir(exist_ok=True)
    attached = False
    try:
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, output,
            capture=not args.verbose)
        attached = True
        verify_payload(mount, verbose=args.verbose)
    finally:
        if attached:
            run("hdiutil", "detach", mount, capture=not args.verbose)
        mount.rmdir()
    print(f"Developer DMG: {output.relative_to(ROOT)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", default=os.environ.get("OPENCLOUD_SIGNING_TEAM"),
                        help="Override DEVELOPMENT_TEAM (also accepts OPENCLOUD_SIGNING_TEAM)")
    parser.add_argument("--identity", help="Override CODE_SIGN_IDENTITY; configured default is Apple Development")
    parser.add_argument("--bundle-prefix", help="Override OPENCLOUD_BUNDLE_PREFIX from the Xcode configuration")
    parser.add_argument("--verbose", action="store_true", help="Show full build and disk image tool output")
    args = parser.parse_args()
    if args.bundle_prefix is not None and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_prefix):
        parser.error("Invalid bundle prefix")
    try:
        build(args)
    except (RuntimeError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        parser.exit(1, f"DMG build failed: {error}\n")


if __name__ == "__main__":
    main()

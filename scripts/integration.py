#!/usr/bin/env python3
"""Disposable, localhost-only Immich 3.3.5 integration stack (Python stdlib)."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "build/integration"
SOURCE = ROOT / "scripts/integration"
PROJECT = "immich-sync-integration"
VERSION = "3.3.5"
COMPOSE_SHA256 = "2601c893aa3217d3c0c7284c23aaa1699aac75b533c84c0315fd16b7889fd552"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def initialize(port=None):
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.chmod(0o700)
    upstream = SOURCE / "docker-compose.upstream.yml"
    if hashlib.sha256(upstream.read_bytes()).hexdigest() != COMPOSE_SHA256:
        raise RuntimeError("Vendored official Compose checksum mismatch")
    for source, target in [(upstream, "docker-compose.yml"), (SOURCE / "compose.override.yml", "override.yml")]:
        shutil.copyfile(source, STATE / target)
    config_path = STATE / "config.json"
    if not config_path.exists():
        port = int(os.environ.get("IMMICH_TEST_PORT", str(port or 22830)))
        if not 1024 <= port <= 65535:
            raise RuntimeError("IMMICH_TEST_PORT must be 1024..65535")
        write_json(config_path, {"port": port, "password": secrets.token_hex(20),
                                 "email": "integration@example.invalid", "adminEmail": "admin@example.invalid",
                                 "otherEmail": "other@example.invalid", "dbPassword": secrets.token_hex(20)})
    config = json.loads(config_path.read_text())
    env = {"IMMICH_VERSION": "v" + VERSION, "IMMICH_TEST_PORT": str(config["port"]),
           "UPLOAD_LOCATION": "upload", "DB_DATA_LOCATION": "database", "DB_PASSWORD": config["dbPassword"],
           "DB_USERNAME": "postgres", "DB_DATABASE_NAME": "immich", "TZ": "Etc/UTC"}
    (STATE / ".env").write_text("".join(f"{k}={v}\n" for k, v in env.items()))
    (STATE / ".env").chmod(0o600)
    return config


def compose(*args):
    initialize()
    # Homebrew also ships the modern Compose plugin as a standalone executable.
    plugin = subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0
    cli = ["docker", "compose"] if plugin else ["docker-compose"]
    env = os.environ.copy()
    # Never let a caller's Immich production environment replace these test mounts/images.
    env.update(line.split("=", 1) for line in (STATE / ".env").read_text().splitlines())
    return subprocess.run(cli + ["--project-name", PROJECT, "--project-directory", str(STATE),
                                 "--env-file", str(STATE / ".env"), "-f", str(STATE / "docker-compose.yml"),
                                 "-f", str(STATE / "override.yml"), *args], check=True, env=env)


def request(path, method="GET", body=None, token=None):
    config = initialize()
    url = f"http://127.0.0.1:{config['port']}/api/{path}"
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{method} {path}: HTTP {error.code}: {error.read().decode()}") from None


def ready(timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            version = request("server/version")
            if [version[k] for k in ("major", "minor", "patch")] != [3, 3, 5] or version.get("prerelease"):
                raise RuntimeError(f"Expected Immich {VERSION}, got {version}")
            print(f"Immich {VERSION} ready on http://127.0.0.1:{initialize()['port']}", flush=True)
            return
        except (OSError, RuntimeError) as error:
            last_error = error
            time.sleep(2)
    raise RuntimeError(f"Readiness timed out: {last_error}")


def png(path, seed):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    pixels = b"".join(b"\0" + bytes((seed * 17 + x * 3 + y * 5 + channel * 41) % 256
                                    for x in range(64) for channel in range(3)) for y in range(64))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def upload(path, token, visibility="timeline"):
    boundary = "integration-" + secrets.token_hex(12)
    fields = {"fileCreatedAt": "2024-03-12T12:00:00.000Z", "fileModifiedAt": "2024-03-12T12:00:00.000Z",
              "visibility": visibility}
    body = b"".join(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
                    for k, v in fields.items())
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="{path.name}"\r\n'
             'Content-Type: image/png\r\n\r\n').encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    config = initialize()
    req = urllib.request.Request(f"http://127.0.0.1:{config['port']}/api/assets", data=body,
                                 headers={"Authorization": "Bearer " + token,
                                          "Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)["id"]


def seed():
    ready()
    config = initialize()
    if (STATE / "seed.json").exists():
        print("Seed already present; reset for a fresh library.")
        return
    # Partial seeding is recoverable: reuse our admin only when its credentials match.
    try:
        request("auth/login", "POST", {"email": config["adminEmail"], "password": config["password"]})
    except RuntimeError:
        request("auth/admin-sign-up", "POST", {"email": config["adminEmail"], "password": config["password"], "name": "Integration admin"})
    admin = request("auth/login", "POST", {"email": config["adminEmail"], "password": config["password"]})["accessToken"]
    settings = request("system-config", token=admin)
    settings["machineLearning"]["enabled"] = False
    request("system-config", "PUT", settings, admin)
    users = request("admin/users", token=admin)
    identities = {}
    for key in ("email", "otherEmail"):
        found = next((u for u in users if u["email"] == config[key]), None)
        identities[key] = found or request("admin/users", "POST", {"email": config[key], "name": key,
            "password": config["password"], "shouldChangePassword": False, "notify": False}, admin)
    token = request("auth/login", "POST", {"email": config["email"], "password": config["password"]})["accessToken"]
    other = request("auth/login", "POST", {"email": config["otherEmail"], "password": config["password"]})["accessToken"]
    for index in range(12):
        png(STATE / "media" / f"synthetic-{index}.png", index)
    for index, folder in enumerate(("Trips/Summer", "Trips/Winter"), 20):
        png(STATE / "external" / folder / "landscape.png", index)
    assets = [upload(STATE / "media" / f"synthetic-{i}.png", token) for i in range(3)]
    hidden = upload(STATE / "media/synthetic-3.png", token, visibility="locked")
    foreign = upload(STATE / "media/synthetic-4.png", other)
    album = request("albums", "POST", {"albumName": "Seed album", "assetIds": assets[:2]}, token)
    library = request("libraries", "POST", {"ownerId": identities["email"]["id"], "name": "Synthetic folders",
                                              "importPaths": ["/integration-external"]}, admin)
    request(f"libraries/{library['id']}/scan", "POST", {}, admin)
    deadline = time.monotonic() + 120
    external = []
    while time.monotonic() < deadline:
        result = request("search/metadata", "POST", {"size": 100, "withExif": True}, token)
        external = [a for a in result["assets"]["items"] if a.get("libraryId") == library["id"]]
        if len(external) == 2:
            break
        time.sleep(1)
    if len(external) != 2:
        raise RuntimeError("External library did not import both synthetic folder assets")
    write_json(STATE / "seed.json", {"assets": assets, "hidden": hidden, "foreign": foreign, "album": album["id"],
                                    "external": [a["id"] for a in external], "userID": identities["email"]["id"]})
    print("Seeded two users, five eligible originals, locked/foreign originals, album, and external folders.")


def run_tests():
    print("Resetting only the disposable integration project's containers and volumes.", flush=True)
    port = initialize()["port"]
    compose("down", "--volumes", "--remove-orphans")
    shutil.rmtree(STATE)
    initialize(port=port)
    (STATE / "external").mkdir(exist_ok=True)
    compose("up", "-d", "--wait", "--wait-timeout", "240")
    seed()
    env = os.environ.copy()
    env["IMMICH_INTEGRATION_STATE"] = str(STATE)
    env["IMMICH_INTEGRATION_PYTHON"] = sys.executable
    command = ["swift", "test", "--filter", "LiveIntegrationTests"]
    started = time.monotonic()
    with (STATE / "test.log").open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            log.write(line)
            print(line, end="", flush=True)
        code = process.wait()
    write_json(STATE / "result.json", {"version": VERSION, "passed": code == 0,
                                      "testSeconds": round(time.monotonic() - started, 2)})
    if code:
        raise subprocess.CalledProcessError(code, command)


def smoke(team):
    if not team or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise RuntimeError("Set IMMICH_SIGNING_TEAM or pass --team with your Apple Development Team ID")
    seed()
    config = initialize()
    fixture = json.loads((STATE / "seed.json").read_text())
    subprocess.run(["python3", "scripts/generate-project.py"], cwd=ROOT, check=True)
    # All ordinary checks stay unsigned. This is the single necessary signed build.
    subprocess.run(["xcodebuild", "-project", "ImmichSync.xcodeproj", "-scheme", "ImmichSync", "-configuration", "Debug",
        "-destination", "generic/platform=macOS", "-derivedDataPath", "build/IntegrationSigned",
        "DEVELOPMENT_TEAM=" + team, "IMMICH_BUNDLE_PREFIX=app.immich.sync.integration",
        "IMMICH_APP_GROUP=" + team + ".app.immich.sync.integration", "build"], cwd=ROOT, check=True)
    built = ROOT / "build/IntegrationSigned/Build/Products/Debug/Immich Sync.app"
    subprocess.run(["python3", "scripts/verify-signing.py", str(built)], cwd=ROOT, check=True)
    installed = Path.home() / "Applications/Immich Sync Integration.app"
    installed.parent.mkdir(exist_ok=True)
    if installed.exists():
        info = subprocess.run(["codesign", "-dv", str(installed)], capture_output=True, text=True, check=True)
        if "Identifier=app.immich.sync.integration\n" not in info.stderr:
            raise RuntimeError("Refusing to replace an unrelated app at the smoke install location")
        shutil.rmtree(installed)
    shutil.copytree(built, installed)
    subprocess.run(["pluginkit", "-a", str(installed / "Contents/PlugIns/ImmichFileProvider.appex")], check=True)
    subprocess.run(["pluginkit", "-e", "use", "-i", "app.immich.sync.integration.FileProvider"], check=True)
    env = os.environ.copy()
    env.update({"IMMICH_SMOKE_SERVER": f"http://127.0.0.1:{config['port']}", "IMMICH_SMOKE_EMAIL": config["email"],
                "IMMICH_SMOKE_PASSWORD": config["password"], "IMMICH_SMOKE_ASSET": fixture["assets"][1],
                "IMMICH_SMOKE_CHECKSUM": base64.b64encode(hashlib.sha1((STATE / "media/synthetic-1.png").read_bytes()).digest()).decode()})
    print("If macOS disables the new provider, enable Immich Sync Integration in System Settings > General > Login Items & Extensions > File Providers.", flush=True)
    subprocess.run([str(installed / "Contents/MacOS/Immich Sync"), "--integration-smoke"], env=env, check=True, timeout=240)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["up", "ready", "seed", "test", "smoke", "reset", "down", "clean", "status", "logs", "server-stop", "server-start"])
    parser.add_argument("--team", default=os.environ.get("IMMICH_SIGNING_TEAM"), help="Apple Development Team ID for smoke only")
    args = parser.parse_args()
    # Keep resets/seeding from racing. Recovery commands are invoked by the locked test process.
    lock = None
    if args.command in ("up", "seed", "test", "smoke", "reset", "down", "clean"):
        (ROOT / "build").mkdir(exist_ok=True)
        lock = (ROOT / "build/integration.lock").open("a")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another integration lifecycle command is running") from None
    if args.command == "up":
        initialize()
        (STATE / "external").mkdir(exist_ok=True)
        compose("up", "-d", "--wait", "--wait-timeout", "240")
        ready()
    elif args.command == "ready":
        ready()
    elif args.command == "seed":
        seed()
    elif args.command == "test":
        run_tests()
    elif args.command == "smoke":
        smoke(args.team)
    elif args.command in ("reset", "clean"):
        port = initialize()["port"]
        compose("down", "--volumes", "--remove-orphans")
        shutil.rmtree(STATE)
        if args.command == "reset":
            initialize(port=port)
            (STATE / "external").mkdir(exist_ok=True)
            compose("up", "-d", "--wait", "--wait-timeout", "240")
            seed()
    elif args.command == "down":
        compose("down")
    elif args.command == "status":
        compose("ps", "-a")
    elif args.command == "logs":
        compose("logs", "--tail", "100")
    elif args.command == "server-stop":
        compose("stop", "immich-server")
    elif args.command == "server-start":
        compose("start", "immich-server")
        ready()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        sys.exit(str(error))

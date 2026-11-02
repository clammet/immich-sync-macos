#!/usr/bin/env python3
"""Provision disposable OpenCloud/Immich containers and exercise the Swift core.

Requires macOS, Swift and a running local Docker Engine with Compose v2+.
No signing, Keychain, Finder, or File Provider registration is used.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, ProxyHandler
import uuid

ROOT = Path(__file__).resolve().parents[1]
# Bypass host HTTP proxies for these disposable loopback services.
HTTP = build_opener(ProxyHandler({}))


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def request(url, *, body=None, headers=None, method=None):
    headers = dict(headers or {})
    if body is not None:
        body = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    with HTTP.open(Request(url, data=body, headers=headers, method=method), timeout=10) as response:
        data = response.read()
        return json.loads(data) if data else None


def wait_ready(label, probe, timeout):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                print(f"{label} ready", flush=True)
                return result
        except (HTTPError, URLError, TimeoutError, ConnectionError) as error:
            last_error = error
        time.sleep(1)
    raise RuntimeError(f"{label} not ready after {timeout}s: {last_error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=240, help="Readiness timeout per service, in seconds")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build" / "container-e2e", help="Failure logs and test output")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Run on macOS: the Swift core uses CryptoKit and Darwin")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL, check=True)
    subprocess.run(["docker", "compose", "version"], check=True)
    project = "opencloud-sync-e2e-" + uuid.uuid4().hex[:12]
    artifacts = args.artifacts.resolve() / project
    artifacts.mkdir(parents=True)
    password = secrets.token_urlsafe(32)
    oc_port, immich_port = free_port(), free_port()
    while immich_port == oc_port:
        immich_port = free_port()
    env = dict(os.environ, E2E_PASSWORD=password, E2E_OPENCLOUD_PORT=str(oc_port), E2E_IMMICH_PORT=str(immich_port))
    compose = ["docker", "compose", "--project-name", project, "--file", str(ROOT / "Tests" / "Containers" / "compose.yml")]

    def docker(*arguments, **kwargs):
        return subprocess.run(compose + list(arguments), env=env, check=True, **kwargs)

    def tests(class_name, test_env):
        # Stream without buffering so both humans and CI see the current test.
        with (artifacts / f"{class_name}.log").open("w") as log:
            process = subprocess.Popen(["swift", "test", "--filter", class_name], cwd=ROOT, env=test_env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                saw_test = False
                skipped = False
                probes = []
                cases = []
                expected_failures = 0
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    saw_test |= f"-[LiveIntegrationTests.{class_name} test" in line
                    skipped |= "Test skipped" in line
                    if line.startswith("PROBE "):
                        probes.append(json.loads(line.removeprefix("PROBE ")))
                    if line.startswith(f"Test Case '-[LiveIntegrationTests.{class_name} "):
                        for outcome in ("passed", "failed", "skipped"):
                            if f" {outcome} (" in line:
                                cases.append({"name": line.split(" ", 3)[3].split("]'", 1)[0], "outcome": outcome})
                    expected_failures += line.startswith("XCTExpectFailure: matcher accepted")
                code = process.wait()
                return {"suite": class_name, "passed": code == 0 and saw_test and not skipped,
                        "exitCode": code, "executed": saw_test, "skipped": skipped,
                        "expectedFailures": expected_failures, "cases": cases, "probes": probes}
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait()

    # A normal SIGTERM (including CI cancellation) follows the same cleanup path.
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    redactions = [password]
    try:
        print(f"Starting {project}: OpenCloud 9.0.0 / Immich v3.3.5", flush=True)
        docker("up", "--detach", "--pull", "missing")
        oc_url, immich_url = f"http://127.0.0.1:{oc_port}", f"http://127.0.0.1:{immich_port}"
        basic = {"Authorization": "Basic " + base64.b64encode(f"admin:{password}".encode()).decode()}
        user = wait_ready("OpenCloud", lambda: request(oc_url + "/graph/v1.0/me", headers=basic), args.timeout)
        drives = wait_ready("OpenCloud personal space", lambda: request(oc_url + "/graph/v1.0/me/drives", headers=basic)["value"], args.timeout)
        personal = [drive for drive in drives if drive.get("driveType") == "personal"]
        if len(personal) != 1:
            raise RuntimeError(f"Expected one personal space, got {[drive.get('driveType') for drive in drives]}")
        token_output = docker("exec", "-T", "opencloud", "opencloud", "auth-app", "create",
                              "--user-name", "admin", "--expiration", "1h",
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout
        tokens = [line.strip().removeprefix("token: ") for line in token_output.splitlines() if line.strip().startswith("token: ")]
        if len(tokens) != 1 or not tokens[0]:
            raise RuntimeError("OpenCloud did not return an app token")
        app_token = tokens[0]
        redactions.append(app_token)
        wait_ready("Immich", lambda: request(immich_url + "/api/server/ping"), args.timeout)
        email = "e2e@example.test"
        request(immich_url + "/api/auth/admin-sign-up", body={"email": email, "password": password, "name": "Container E2E"})
        # Login is exercised by ImmichAPI in Swift; this session only provisions fixtures.
        login = request(immich_url + "/api/auth/login", body={"email": email, "password": password})
        headers = {"Authorization": "Bearer " + login["accessToken"]}
        request(immich_url + "/api/admin/users/" + login["userId"], headers=headers,
                method="PUT", body={"shouldChangePassword": False})
        library_root = "/opencloud/storage/users/users/" + user["id"]
        library = request(immich_url + "/api/libraries", headers=headers, body={
            "name": "OpenCloud originals", "ownerId": login["userId"],
            "importPaths": [library_root], "exclusionPatterns": ["**/.opencloud/**", "**/excluded/**"],
        })
        # A second, unprivileged owner exercises the library-discovery permission fallback.
        request(immich_url + "/api/admin/users", headers=headers, body={
            "email": "reader@example.test", "password": password, "name": "Reader", "shouldChangePassword": False,
        })
        test_env = dict(env, CONTAINER_E2E="1", OPENCLOUD_TEST_SERVER=oc_url,
                        OPENCLOUD_TEST_USERNAME="admin", OPENCLOUD_TEST_TOKEN=app_token,
                        OPENCLOUD_TEST_SPACE=personal[0]["id"], IMMICH_TEST_SERVER=immich_url,
                        IMMICH_TEST_EMAIL=email, IMMICH_TEST_PASSWORD=password,
                        IMMICH_TEST_LIBRARY=library["id"], IMMICH_TEST_ROOT=library_root)
        results = [tests("ContainerEndToEndTests", test_env), tests("ContainerUploadContractTests", test_env)]
        print("Stopping Immich to verify OpenCloud remains usable", flush=True)
        docker("stop", "immich")
        results.append(tests("ContainerImmichOfflineTests", test_env))
        (artifacts / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        failures = [result["suite"] for result in results if not result["passed"]]
        print(f"Container results: {artifacts / 'results.json'}", flush=True)
        if failures:
            raise RuntimeError("Container suites failed: " + ", ".join(failures))
        print("All container suites passed (see logs for any explicit expected failures).", flush=True)
    finally:
        # Do not persist environment/config dumps or credentials in diagnostics.
        try:
            with (artifacts / "containers.log").open("w") as log:
                result = subprocess.run(compose + ["logs", "--no-color", "--tail", "200"], env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                output = result.stdout
                for secret in redactions:
                    output = output.replace(secret, "<redacted>")
                log.write(output)
        finally:
            docker("down", "--volumes", "--remove-orphans", "--timeout", "10")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, HTTPError, URLError) as error:
        sys.exit(str(error))
    except KeyboardInterrupt:
        sys.exit(130)

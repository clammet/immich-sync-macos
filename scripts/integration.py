#!/usr/bin/env python3
"""Run explicitly enabled tests against a disposable loopback OpenCloud server."""
import argparse
import os
from pathlib import Path
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["test"])
    parser.parse_args()
    required = ["OPENCLOUD_TEST_SERVER", "OPENCLOUD_TEST_USERNAME", "OPENCLOUD_TEST_TOKEN"]
    if any(not os.environ.get(key) for key in required):
        parser.error("Set the OPENCLOUD_TEST_SERVER, OPENCLOUD_TEST_USERNAME and OPENCLOUD_TEST_TOKEN environment variables. See docs/integration-testing.md.")
    if urlparse(os.environ["OPENCLOUD_TEST_SERVER"]).hostname not in {"127.0.0.1", "localhost", "::1"}:
        parser.error("Live mutations require a disposable loopback server")
    env = dict(os.environ, OPENCLOUD_INTEGRATION="1")
    subprocess.run(["swift", "test", "--filter", "LiveIntegrationTests"], cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    main()

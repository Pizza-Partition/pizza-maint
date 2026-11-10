#!/usr/bin/env python3
"""Fetch the digest-pinned EFI entry point used by release builds."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

lock = json.loads((pathlib.Path(__file__).resolve().parents[1] / "tools/efi-stub.json").read_text())
output = pathlib.Path(sys.argv[1])
with urllib.request.urlopen(lock["url"], timeout=120) as response:
    archive = response.read(64 * 1024 * 1024 + 1)
if hashlib.sha256(archive).hexdigest() != lock["archive_sha256"]:
    raise SystemExit("EFI stub package digest mismatch")
with tempfile.NamedTemporaryFile() as source:
    source.write(archive)
    source.flush()
    stub = subprocess.check_output(["bsdtar", "-xOf", source.name, lock["member"]])
if hashlib.sha256(stub).hexdigest() != lock["sha256"]:
    raise SystemExit("EFI stub executable digest mismatch")
output.write_bytes(stub)

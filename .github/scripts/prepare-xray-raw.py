#!/usr/bin/env python3
"""Reproduce pinned raw Xray Release assets from verified upstream ZIPs."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import urllib.request
import zipfile

VERSION = "v26.3.27"
COMMIT = "d2758a023cd7f4174a5a5fa4ff66e487d4342ba0"
DISTRIBUTION_TAG = f"xray-{VERSION}-r1"
UPSTREAM_BASE = f"https://github.com/XTLS/Xray-core/releases/download/{VERSION}"
# Every payload name derives from VERSION, so the names cannot drift apart.
LICENSE_NAME = f"xray-{VERSION}-LICENSE.txt"
CHECKSUM_NAME = f"xray-{VERSION}-SHA256SUMS"
PROVENANCE_NAME = f"xray-{VERSION}-PROVENANCE.json"
MEMBERS = ("xray", "geoip.dat", "geosite.dat", "LICENSE", "README.md")
PINS = {
    "amd64": {
        "zip": "Xray-linux-64.zip",
        "zip_size": 21136402,
        "zip_sha256": "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae",
        "raw": f"xray-{VERSION}-linux-amd64",
        "raw_size": 36577406,
        "raw_sha256": "8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed",
        "machine": "x86-64",
    },
    "arm64": {
        "zip": "Xray-linux-arm64-v8a.zip",
        "zip_size": 19716427,
        "zip_sha256": "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c",
        "raw": f"xray-{VERSION}-linux-arm64",
        "raw_size": 34209918,
        "raw_sha256": "c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04",
        "machine": "ARM aarch64",
    },
}


def fail(message):
    raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def exact(data, size, sha, label):
    if len(data) != size:
        fail(f"{label}: size {len(data)}, expected {size}")
    observed = digest(data)
    if observed != sha:
        fail(f"{label}: SHA-256 {observed}, expected {sha}")


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "xray-raw-publisher/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.geturl().split(":", 1)[0] != "https":
            fail("download redirected away from HTTPS")
        return response.read()


def archive_members(archive):
    infos = archive.infolist()
    names = [info.filename for info in infos]
    # The exact inventory also settles duplicates, directories and every unsafe
    # path: each name must be one of the five fixed plain names, exactly once.
    if len(infos) != len(MEMBERS) or sorted(names) != sorted(MEMBERS):
        fail("archive member inventory differs")
    for info in infos:
        mode = info.external_attr >> 16
        if stat.S_IFMT(mode) != stat.S_IFREG:
            fail(f"archive member is not regular: {info.filename}")
        if info.filename == "xray" and stat.S_IMODE(mode) & 0o111 == 0:
            fail("xray archive member is not executable")
    bad = archive.testzip()
    if bad is not None:
        fail(f"archive CRC failed: {bad}")


def check_version(label, output):
    # An executable that prints nothing is refused, not an IndexError.
    lines = str(output).splitlines()
    if not lines or VERSION.removeprefix("v") not in lines[0]:
        fail(f"{label}: wrong version output")


def command_output(command, label):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=30, check=False)
    if result.returncode != 0:
        fail(f"{label} failed ({result.returncode}): {result.stdout.strip()}")
    return result.stdout


def prepare(arch, output, source=None):
    pin = PINS[arch]
    url = f"{UPSTREAM_BASE}/{pin['zip']}"
    data = Path(source).read_bytes() if source else download(url)
    exact(data, pin["zip_size"], pin["zip_sha256"], pin["zip"])
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        archive_members(archive)
        raw = archive.read("xray")
        license_bytes = archive.read("LICENSE")
    exact(raw, pin["raw_size"], pin["raw_sha256"], pin["raw"])
    raw_path = output / pin["raw"]
    raw_path.write_bytes(raw)
    raw_path.chmod(0o755)
    file_text = command_output(["file", "-b", str(raw_path)], "file")
    if "ELF 64-bit" not in file_text or pin["machine"] not in file_text:
        fail(f"{pin['raw']}: wrong ELF architecture: {file_text.strip()}")
    if "dynamically linked" in file_text or "interpreter" in file_text:
        fail(f"{pin['raw']}: binary is dynamically linked")
    version_output = command_output([str(raw_path.resolve()), "version"], "xray version")
    check_version(pin["raw"], version_output)
    (output / f"LICENSE.{arch}").write_bytes(license_bytes)
    record = {
        "architecture": arch,
        "upstream_version": VERSION,
        "upstream_commit": COMMIT,
        "source": {"name": pin["zip"], "url": url, "size": pin["zip_size"],
                   "sha256": pin["zip_sha256"], "members": list(MEMBERS)},
        "raw": {"name": pin["raw"], "size": pin["raw_size"],
                "sha256": pin["raw_sha256"], "unchanged_member": "xray"},
        "verification": {"file": file_text.strip(), "version": version_output.strip()},
    }
    (output / f"provenance.{arch}.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def check_record(arch, record):
    """Refuse a per-architecture record that does not describe its own pins."""
    pin = PINS[arch]
    expected = {
        "architecture": arch,
        "upstream_version": VERSION,
        "upstream_commit": COMMIT,
        "source": {"name": pin["zip"], "url": f"{UPSTREAM_BASE}/{pin['zip']}", "size": pin["zip_size"],
                   "sha256": pin["zip_sha256"], "members": list(MEMBERS)},
        "raw": {"name": pin["raw"], "size": pin["raw_size"],
                "sha256": pin["raw_sha256"], "unchanged_member": "xray"},
    }
    if not isinstance(record, dict) or set(record) != set(expected) | {"verification"}:
        fail(f"{arch}: provenance record has the wrong fields")
    for key, value in expected.items():
        if record[key] != value:
            fail(f"{arch}: provenance {key} differs from the pin")
    verification = record["verification"]
    if not isinstance(verification, dict) or set(verification) != {"file", "version"}:
        fail(f"{arch}: provenance verification has the wrong fields")
    if pin["machine"] not in verification["file"] or "ELF 64-bit" not in verification["file"]:
        fail(f"{arch}: provenance file(1) evidence is not this architecture")
    check_version(f"{arch}: provenance", verification["version"])


def assemble(source, output, repository_commit):
    records = []
    licenses = []
    output.mkdir(parents=True, exist_ok=True)
    for arch, pin in PINS.items():
        raw = (source / pin["raw"]).read_bytes()
        exact(raw, pin["raw_size"], pin["raw_sha256"], pin["raw"])
        record = json.loads((source / f"provenance.{arch}.json").read_text())
        check_record(arch, record)
        (output / pin["raw"]).write_bytes(raw)
        (output / pin["raw"]).chmod(0o755)
        records.append(record)
        licenses.append((source / f"LICENSE.{arch}").read_bytes())
    if licenses[0] != licenses[1]:
        fail("architecture ZIPs contain different Xray licenses")
    (output / LICENSE_NAME).write_bytes(licenses[0])
    checksums = []
    for name in sorted([pin["raw"] for pin in PINS.values()] + [LICENSE_NAME]):
        checksums.append(f"{digest((output / name).read_bytes())}  {name}")
    (output / CHECKSUM_NAME).write_text("\n".join(checksums) + "\n", encoding="ascii")
    # Only fields fixed by the commit: a re-dispatch must assemble the same
    # bytes, or an asset one run already uploaded blocks every later run. The
    # run that prepared the draft is named in the release notes instead.
    provenance = {
        "schema": 1,
        "distribution_tag": DISTRIBUTION_TAG,
        "upstream_version": VERSION,
        "upstream_commit": COMMIT,
        "statement": "Each executable is the unchanged xray member of its verified official upstream ZIP.",
        "repository_commit": repository_commit,
        "assets": records,
    }
    (output / PROVENANCE_NAME).write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    subs = parser.add_subparsers(dest="command", required=True)
    prep = subs.add_parser("prepare")
    prep.add_argument("--arch", choices=PINS, required=True)
    prep.add_argument("--output", type=Path, required=True)
    prep.add_argument("--source", type=Path)
    assembly = subs.add_parser("assemble")
    assembly.add_argument("--input", type=Path, required=True)
    assembly.add_argument("--output", type=Path, required=True)
    assembly.add_argument("--repository-commit", default=os.environ.get("GITHUB_SHA", "local"))
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            args.output.mkdir(parents=True, exist_ok=True)
            prepare(args.arch, args.output, args.source)
        else:
            assemble(args.input, args.output, args.repository_commit)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print(f"prepare-xray-raw: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

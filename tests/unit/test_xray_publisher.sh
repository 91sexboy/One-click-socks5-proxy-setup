#!/bin/sh
# Reproducible raw publisher rejects transformed or unsafe source archives.
S5T_NAME=test_xray_publisher
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
t_mktestroot

PREP=$S5_REPO_ROOT/.github/scripts/prepare-xray-raw.py
WORK=$S5_TEST_ROOT/publisher
mkdir -p "$WORK/source" "$WORK/out"

# The production publisher pins full official sizes and hashes, so fixture-level
# archive rejection is exercised through its reusable archive_members boundary.
python3 - "$S5_REPO_ROOT" "$WORK" <<'PY'
import importlib.util
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
work = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("prepare_xray_raw", root / ".github/scripts/prepare-xray-raw.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

cases = ("good", "noxray", "duplicate", "extra", "subdir", "traversal", "symlink", "device")
import subprocess
subprocess.run([sys.executable, str(root / "tests/lib/mkasset.py"), str(work / "source"), *cases], check=True,
               stdout=subprocess.DEVNULL)
expected = {"xray", "geoip.dat", "geosite.dat", "LICENSE", "README.md"}
with zipfile.ZipFile(work / "source/good.zip") as archive:
    module.archive_members(archive)
    assert set(archive.namelist()) == expected
for case in cases[1:]:
    try:
        with zipfile.ZipFile(work / f"source/{case}.zip") as archive:
            module.archive_members(archive)
    except ValueError:
        continue
    raise SystemExit("unsafe fixture accepted: " + case)
PY
assert_eq "publisher archive policy rejects every hostile fixture" 0 "$?"

publisher_text=$(cat "$S5_REPO_ROOT/.github/workflows/publish-xray-raw.yml")
assert_contains "publisher is manually dispatched" 'workflow_dispatch:' "$publisher_text"
assert_not_contains "publisher has no push trigger" 'push:' "$publisher_text"
assert_not_contains "publisher never clobbers release assets" '--clobber' "$publisher_text"
assert_contains "publisher requires the primary branch" 'refs/heads/xray-only' "$publisher_text"
assert_contains "publisher uses the immutable r1 tag" 'xray-v26.3.27-r1' "$publisher_text"
assert_contains "publisher verifies uploaded asset bytes" 'cmp -s "$path" "$tmp"' "$publisher_text"

notes=$(cat "$S5_REPO_ROOT/.github/releases/xray-v26.3.27-r1.md")
assert_contains "release notes identify unchanged upstream members" 'unchanged `xray` member' "$notes"
assert_contains "release notes preserve old installer availability" 'older `xray-v26.3.27` Release remains unchanged' "$notes"

t_summary

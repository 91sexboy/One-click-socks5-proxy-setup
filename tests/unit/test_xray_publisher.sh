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

cases = ("good", "noxray", "duplicate", "extra", "subdir", "traversal", "symlink", "device", "noexec")
import subprocess
subprocess.run([sys.executable, str(root / "tests/lib/mkasset.py"), str(work / "source"), *cases], check=True,
               stdout=subprocess.DEVNULL)
expected = {"xray", "geoip.dat", "geosite.dat", "LICENSE", "README.md"}
with zipfile.ZipFile(work / "source/good.zip") as archive:
    module.archive_members(archive)
    assert set(archive.namelist()) == expected
# Each hostile archive is refused for its own reason, not for any ValueError.
reasons = {
    "noxray": "archive member inventory differs",
    "duplicate": "archive member inventory differs",
    "extra": "archive member inventory differs",
    "subdir": "archive member inventory differs",
    "traversal": "archive member inventory differs",
    "symlink": "archive member is not regular: xray",
    "device": "archive member is not regular: geoip.dat",
    "noexec": "xray archive member is not executable",
}
for case in cases[1:]:
    try:
        with zipfile.ZipFile(work / f"source/{case}.zip") as archive:
            module.archive_members(archive)
    except ValueError as error:
        if str(error) != reasons[case]:
            raise SystemExit(f"{case}: refused for the wrong reason: {error}")
        continue
    raise SystemExit("unsafe fixture accepted: " + case)

# An executable that prints nothing is a clean refusal, not an IndexError.
for output in ("", "\n", "Xray 1.0.0 (wrong)\n"):
    try:
        module.check_version("xray-candidate", output)
    except ValueError as error:
        assert str(error) == "xray-candidate: wrong version output", error
    else:
        raise SystemExit("version output accepted: %r" % output)
module.check_version("xray-candidate", "Xray 26.3.27 (Xray) d2758a0\n")

# assemble checks each architecture's record against its own pins.
def record(arch):
    pin = module.PINS[arch]
    return {
        "architecture": arch, "upstream_version": module.VERSION, "upstream_commit": module.COMMIT,
        "source": {"name": pin["zip"], "url": f"{module.UPSTREAM_BASE}/{pin['zip']}",
                   "size": pin["zip_size"], "sha256": pin["zip_sha256"], "members": list(module.MEMBERS)},
        "raw": {"name": pin["raw"], "size": pin["raw_size"], "sha256": pin["raw_sha256"],
                "unchanged_member": "xray"},
        "verification": {"file": "ELF 64-bit LSB executable, %s, statically linked" % pin["machine"],
                         "version": "Xray 26.3.27 (Xray) d2758a0"},
    }
for arch in module.PINS:
    module.check_record(arch, record(arch))
faults = {
    "missing": (lambda r: r.pop("raw"), "amd64: provenance record has the wrong fields"),
    "other-arch": (lambda r: r.update(architecture="arm64"), "amd64: provenance architecture differs from the pin"),
    "raw-sha": (lambda r: r["raw"].update(sha256="0" * 64), "amd64: provenance raw differs from the pin"),
    "source-size": (lambda r: r["source"].update(size=1), "amd64: provenance source differs from the pin"),
    "not-run": (lambda r: r["verification"].update(version="not-run"), "amd64: provenance: wrong version output"),
    "wrong-elf": (lambda r: r["verification"].update(file="ELF 64-bit LSB executable, ARM aarch64"),
                  "amd64: provenance file(1) evidence is not this architecture"),
}
for label, (mutate, message) in faults.items():
    bad = record("amd64")
    mutate(bad)
    try:
        module.check_record("amd64", bad)
    except ValueError as error:
        assert str(error) == message, (label, str(error))
    else:
        raise SystemExit("provenance fault accepted: " + label)
PY
assert_eq "publisher archive policy rejects every hostile fixture" 0 "$?"

publisher_text=$(cat "$S5_REPO_ROOT/.github/workflows/publish-xray-raw.yml")
assert_contains "publisher is manually dispatched" 'workflow_dispatch:' "$publisher_text"
assert_not_contains "publisher has no push trigger" 'push:' "$publisher_text"
assert_not_contains "publisher never clobbers release assets" '--clobber' "$publisher_text"
assert_contains "publisher requires the primary branch" 'refs/heads/xray-only' "$publisher_text"
assert_contains "publisher uses the immutable r1 tag" 'xray-v26.3.27-r1' "$publisher_text"
assert_contains "publisher publishes through the tested script" \
    'sh .github/scripts/publish-release.sh publish' "$publisher_text"

# The draft life cycle against a stateful fake gh: an upload cut off part way,
# then a re-dispatch that completes and publishes the same draft.
_pub=$S5_TEST_ROOT/release
mkdir -p "$_pub/dist" "$_pub/bin" "$_pub/state"
printf '#!/bin/sh\nexec python3 "%s/tests/lib/fake_gh.py" "$@"\n' "$S5_REPO_ROOT" >"$_pub/bin/gh"
chmod 0755 "$_pub/bin/gh"
printf 'amd64 executable\n' >"$_pub/dist/xray-v26.3.27-linux-amd64"
printf 'arm64 executable bytes\n' >"$_pub/dist/xray-v26.3.27-linux-arm64"
printf 'license\n' >"$_pub/dist/xray-v26.3.27-LICENSE.txt"
(cd "$_pub/dist" && sha256sum xray-v26.3.27-LICENSE.txt xray-v26.3.27-linux-amd64 \
    xray-v26.3.27-linux-arm64 >xray-v26.3.27-SHA256SUMS)
printf '{"schema": 1}\n' >"$_pub/dist/xray-v26.3.27-PROVENANCE.json"
# Our draft sits beyond the first page of the listing.
python3 - "$_pub/state/state.json" <<'STATE'
import json, sys
releases = [{"id": n, "tag_name": "unrelated-%d" % n, "target_commitish": "0" * 40,
             "draft": False, "assets": []} for n in range(1, 131)]
json.dump({"tag": None, "releases": releases, "next_id": 1000, "failed": []}, open(sys.argv[1], "w"))
STATE
# s5t_publish <step> [VAR=value...]: one publish-release.sh step in the fixture.
s5t_publish() {
    _sp_step=$1
    shift
    env PATH="$_pub/bin:$PATH" FAKE_GH_STATE="$_pub/state" FAKE_GH_PAGE_SIZE=100 \
        GITHUB_REPOSITORY=owner/repo GITHUB_SHA=1111111111111111111111111111111111111111 \
        GITHUB_REF=refs/heads/xray-only DISTRIBUTION_TAG=xray-v26.3.27-r1 \
        DIST="$_pub/dist" NOTES="$S5_REPO_ROOT/.github/releases/xray-v26.3.27-r1.md" \
        GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=77 "$@" \
        sh "$S5_REPO_ROOT/.github/scripts/publish-release.sh" "$_sp_step"
}
t_run s5t_publish claim
assert_eq "the first dispatch claims a new draft" 0 "$T_STATUS"
_pub_id=$T_OUT
t_run s5t_publish upload RELEASE_ID="$_pub_id" FAKE_GH_FAIL_UPLOAD=xray-v26.3.27-linux-arm64
assert_ne "an upload cut off part way fails the dispatch" 0 "$T_STATUS"
t_run s5t_publish claim
assert_eq "a re-dispatch finds the same draft past the first listing page" "$_pub_id" "$T_OUT"
t_run s5t_publish upload RELEASE_ID="$_pub_id"
assert_eq "a re-dispatch completes the draft" 0 "$T_STATUS"
t_run s5t_publish publish RELEASE_ID="$_pub_id"
assert_eq "the completed draft is published" 0 "$T_STATUS"
assert_eq "the fake records the full life cycle in order" 'create-tag 1111111111111111111111111111111111111111
create-release 1000
upload xray-v26.3.27-linux-amd64
upload-cut xray-v26.3.27-linux-arm64
delete xray-v26.3.27-linux-arm64
upload xray-v26.3.27-linux-arm64
upload xray-v26.3.27-LICENSE.txt
upload xray-v26.3.27-SHA256SUMS
upload xray-v26.3.27-PROVENANCE.json
patch draft=false' "$(cat "$_pub/state/calls.log")"
t_run python3 - "$_pub/state" "$_pub/dist" <<'CHECK'
import json, sys
from pathlib import Path
state, dist = Path(sys.argv[1]), Path(sys.argv[2])
release = [r for r in json.loads((state / "state.json").read_text())["releases"] if r["id"] == 1000][0]
assert release["draft"] is False and release["body"].endswith("Prepared by workflow run https://github.com/owner/repo/actions/runs/77.\n")
assert sorted(a["name"] for a in release["assets"]) == sorted(p.name for p in dist.iterdir())
for asset in release["assets"]:
    assert asset["state"] == "uploaded"
    assert (state / ("asset-%d" % asset["id"])).read_bytes() == (dist / asset["name"]).read_bytes()
CHECK
assert_eq "the published release holds exactly the assembled bytes" 0 "$T_STATUS"
t_run s5t_publish claim
assert_ne "a published release is never claimed again" 0 "$T_STATUS"
assert_contains "the refusal names the published release" 'refusing to alter a published release' "$T_OUT"

# An uploaded asset whose bytes differ is refused, never replaced.
python3 - "$_pub/state/state.json" <<'RESET'
import json, sys
state = json.load(open(sys.argv[1]))
for release in state["releases"]:
    if release["id"] == 1000:
        release["draft"] = True
json.dump(state, open(sys.argv[1], "w"))
RESET
printf 'changed amd64 executable\n' >"$_pub/dist/xray-v26.3.27-linux-amd64"
t_run s5t_publish upload RELEASE_ID="$_pub_id"
assert_ne "a mismatched uploaded asset stops the dispatch" 0 "$T_STATUS"
assert_contains "the mismatch is named" 'refusing mismatched existing asset: xray-v26.3.27-linux-amd64' "$T_OUT"
t_run s5t_publish claim GITHUB_REF=refs/heads/other
assert_ne "a dispatch from another branch is refused" 0 "$T_STATUS"

notes=$(cat "$S5_REPO_ROOT/.github/releases/xray-v26.3.27-r1.md")
assert_contains "release notes identify unchanged upstream members" 'unchanged `xray` member' "$notes"
assert_contains "release notes preserve old installer availability" 'older `xray-v26.3.27` Release remains unchanged' "$notes"

t_summary

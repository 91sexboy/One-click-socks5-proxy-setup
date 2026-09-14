#!/usr/bin/env python3
"""Build deterministic Xray archive fixtures without a runnable engine."""

import hashlib
from pathlib import Path
import struct
import sys
import warnings
import zipfile

sys.dont_write_bytecode = True
REG = 0o100644
EXE = 0o100755
LNK = 0o120777
DEV = 0o020666


def stub_xray():
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 2, 0x3E, 1)
    struct.pack_into("<H", header, 52, 64)
    return bytes(header)


def members(case, binary):
    good = [("xray", binary, EXE)] + [
        (name, ("synthetic-" + label + "\n").encode(), REG)
        for name, label in (("geoip.dat", "geoip"), ("geosite.dat", "geosite"),
                            ("LICENSE", "license"), ("README.md", "readme"))
    ]
    if case == "good":
        return good
    if case == "noxray":
        return good[1:]
    if case == "duplicate":
        return [good[0]] + good
    if case == "extra":
        return good + [("install.sh", b"synthetic-extra\n", REG)]
    if case == "subdir":
        return [("bin/xray", binary, EXE)] + good[1:]
    if case == "traversal":
        return good + [("../../etc/cron.d/synthetic", b"synthetic-cron\n", REG)]
    if case == "symlink":
        return [("xray", b"/etc/passwd", LNK)] + good[1:]
    if case == "device":
        return [good[0], ("geoip.dat", b"", DEV)] + good[2:]
    raise ValueError("unknown archive case: " + case)


def main():
    output = Path(sys.argv[1])
    binary = stub_xray()
    (output / "asset-xray").write_bytes(binary)
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Duplicate name:", category=UserWarning)
        for case in sys.argv[2:]:
            with zipfile.ZipFile(output / (case + ".zip"), "w") as archive:
                for name, data, mode in members(case, binary):
                    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                    info.external_attr = mode << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, data)
    print(len(binary), hashlib.sha256(binary).hexdigest())


if __name__ == "__main__":
    main()

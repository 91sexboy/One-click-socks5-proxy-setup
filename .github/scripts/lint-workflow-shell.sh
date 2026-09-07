#!/bin/sh
# Lint the shell that lives inside the workflow files themselves.
#
# The two lifecycle gates were moved into this directory so that the repo's
# `sh -n` and shellcheck steps could read them, but every remaining inline
# `run:` block stayed invisible to both -- around 140 lines that no guard here
# checked. Moving the next three into files would shrink the hole rather than
# close it: the hole is that inline blocks are unreachable, so a block added
# later would be unchecked again. This extracts all of them instead.
set -eu

# The same exemptions the tracked scripts in this directory already carry.
# SC2034 is the `for n in $(seq 1 60)` bounded-retry idiom, whose counter is
# deliberately unused. Anything narrower stays an inline disable at its site so
# it remains visible, which is how the rest of the repo is linted.
SC_EXCLUDE=SC2317,SC2034,SC2016

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# GitHub expression syntax is not shell, so `${{ ... }}` becomes a placeholder
# rather than a reason to skip the whole block it appears in.
python3 - "$work" .github/workflows/*.yml <<'PY'
import os
import re
import sys

import yaml

work = sys.argv[1]
for path in sys.argv[2:]:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    for job, spec in (doc.get("jobs") or {}).items():
        for index, step in enumerate(spec.get("steps") or []):
            run = step.get("run")
            if not run:
                continue
            body = re.sub(r"\$\{\{[^}]*\}\}", "GH_EXPR_PLACEHOLDER", run)
            name = "%s.%s.%02d.sh" % (
                os.path.basename(path).rsplit(".", 1)[0],
                job.replace("/", "_"),
                index,
            )
            with open(os.path.join(work, name), "w", encoding="utf-8") as out:
                out.write(body if body.endswith("\n") else body + "\n")
PY

# A check that cannot fail is not a check. The workflows do carry inline run
# blocks, so extracting none means the extractor broke -- not that there is
# nothing to lint -- and that must fail rather than report success.
count=$(find "$work" -name '*.sh' -type f | wc -l | tr -d '[:space:]')
if [ "$count" -eq 0 ]; then
    printf 'no inline run blocks were extracted from .github/workflows\n' >&2
    exit 1
fi

for f in "$work"/*.sh; do
    sh -n "$f"
    shellcheck -s sh -e "$SC_EXCLUDE" "$f"
done
printf 'inline workflow run blocks checked: %s\n' "$count"

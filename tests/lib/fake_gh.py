#!/usr/bin/env python3
"""A stateful stand-in for the gh api calls publish-release.sh makes.

State lives in $FAKE_GH_STATE: state.json plus one file per asset. It models
exactly what the publisher relies on: the tag ref, a paginated release listing,
draft creation, asset upload (including an upload cut off mid-transfer, which
leaves an incomplete "starter" asset), asset download and deletion, and the
publishing PATCH. Every mutating call is appended to calls.log.
"""

import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
STATE = Path(os.environ["FAKE_GH_STATE"])


def load():
    path = STATE / "state.json"
    if path.exists():
        return json.loads(path.read_text())
    return {"tag": None, "releases": [], "next_id": 1000, "failed": []}


def save(state):
    (STATE / "state.json").write_text(json.dumps(state))


def log(line):
    with (STATE / "calls.log").open("a") as handle:
        handle.write(line + "\n")


def public(release):
    view = dict(release)
    view["assets"] = [{"id": asset["id"], "name": asset["name"], "state": asset["state"]}
                      for asset in release["assets"]]
    return view


def find(state, release_id):
    for release in state["releases"]:
        if str(release["id"]) == str(release_id):
            return release
    print(json.dumps({"message": "Not Found"}))
    sys.exit(1)


def main(argv):
    if argv[:1] != ["api"]:
        sys.exit("fake gh: only gh api is modelled")
    method, fields, source, paginate, path = "GET", {}, None, False, None
    items = iter(argv[1:])
    for item in items:
        if item == "--method":
            method = next(items)
        elif item == "-H":
            next(items)
        elif item in ("-f", "-F"):
            key, _, value = next(items).partition("=")
            fields[key] = value
        elif item == "--input":
            source = next(items)
        elif item == "--paginate":
            paginate = True
        else:
            path = item
    path = path.removeprefix("https://uploads.github.com/")
    state = load()
    repo = "repos/" + os.environ["GITHUB_REPOSITORY"] + "/"
    if not path.startswith(repo):
        sys.exit("fake gh: foreign repository " + path)
    route = path[len(repo):]
    tag = os.environ["DISTRIBUTION_TAG"]

    if route == "git/ref/tags/" + tag:
        if state["tag"] is None:
            print(json.dumps({"message": "Not Found", "status": "404"}))
            sys.exit(1)
        print(json.dumps({"ref": "refs/tags/" + tag, "object": {"sha": state["tag"]}}))
    elif route == "git/refs" and method == "POST":
        state["tag"] = fields["sha"]
        log("create-tag " + fields["sha"])
    elif route.startswith("releases?") and method == "GET":
        size = int(os.environ.get("FAKE_GH_PAGE_SIZE", "100"))
        listed = [public(release) for release in state["releases"]]
        pages = [listed[start:start + size] for start in range(0, len(listed), size)] or [[]]
        for page in pages if paginate else pages[:1]:
            print(json.dumps(page))
    elif route == "releases" and method == "POST":
        body = json.loads(sys.stdin.read() if source == "-" else Path(source).read_text())
        release = dict(body, id=state["next_id"], assets=[])
        state["next_id"] += 1
        state["releases"].append(release)
        log("create-release %d" % release["id"])
        print(json.dumps(public(release)))
    elif route.startswith("releases/assets/"):
        asset_id = int(route.rsplit("/", 1)[1])
        for release in state["releases"]:
            for asset in release["assets"]:
                if asset["id"] == asset_id:
                    if method == "DELETE":
                        release["assets"].remove(asset)
                        log("delete " + asset["name"])
                    else:
                        sys.stdout.buffer.write((STATE / ("asset-%d" % asset_id)).read_bytes())
                    save(state)
                    return
        sys.exit("fake gh: no asset %d" % asset_id)
    elif route.startswith("releases/") and "/assets?name=" in route:
        release_id, _, name = route[len("releases/"):].partition("/assets?name=")
        release = find(state, release_id)
        data = Path(source).read_bytes()
        asset_id = state["next_id"]
        state["next_id"] += 1
        if name == os.environ.get("FAKE_GH_FAIL_UPLOAD") and name not in state["failed"]:
            # The transfer dies part way: the name is taken by an asset that
            # never completed.
            state["failed"].append(name)
            release["assets"].append({"id": asset_id, "name": name, "state": "starter"})
            (STATE / ("asset-%d" % asset_id)).write_bytes(data[:len(data) // 2])
            log("upload-cut " + name)
            save(state)
            sys.exit(1)
        release["assets"].append({"id": asset_id, "name": name, "state": "uploaded"})
        (STATE / ("asset-%d" % asset_id)).write_bytes(data)
        log("upload " + name)
    elif route.startswith("releases/"):
        release = find(state, route[len("releases/"):])
        if method == "PATCH":
            release["draft"] = fields.get("draft") != "false"
            log("patch draft=%s" % fields.get("draft"))
        else:
            print(json.dumps(public(release)))
    else:
        sys.exit("fake gh: unmodelled route " + route)
    save(state)


if __name__ == "__main__":
    main(sys.argv[1:])

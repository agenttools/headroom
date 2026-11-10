#!/usr/bin/env python3
"""dock-tile.py — add or remove Headroom's tile in a Dock plist FILE (used by install.sh / uninstall.sh).

    dock-tile.py has    <dock.plist> <app-path>
    dock-tile.py add    <dock.plist> <app-path> <out.plist>
    dock-tile.py remove <dock.plist> <app-path> <out.plist>

It only reads and writes files. The caller exports the live Dock with `defaults export`, and imports
the result with `defaults import` (or, in tests, works on a copied plist and never touches the Dock).
Exit codes: 0 = done / present, 3 = nothing to do / absent, 1 = error.
"""
import pathlib
import plistlib
import random
import sys
import urllib.parse

BUNDLE_ID = "dev.adder.headroom"


def tile_path(tile):
    data = tile.get("tile-data", {})
    url = data.get("file-data", {}).get("_CFURLString", "")
    return urllib.parse.unquote(urllib.parse.urlparse(url).path).rstrip("/")


def is_ours(tile, app):
    return tile.get("tile-data", {}).get("bundle-identifier") == BUNDLE_ID or tile_path(tile) == app


def main(argv):
    if len(argv) < 3 or argv[0] not in ("has", "add", "remove"):
        print(__doc__, file=sys.stderr)
        return 1
    cmd, src, app = argv[0], argv[1], str(pathlib.Path(argv[2])).rstrip("/")
    with open(src, "rb") as f:
        dock = plistlib.load(f)
    apps = dock.setdefault("persistent-apps", [])
    present = [t for t in apps if is_ours(t, app)]
    if cmd == "has":
        return 0 if present else 3
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 1
    out = argv[3]
    if cmd == "add":
        if present:
            return 3
        apps.append({
            "GUID": random.randint(1, 2**31 - 1),
            "tile-type": "file-tile",
            "tile-data": {
                "bundle-identifier": BUNDLE_ID,
                "file-label": "Headroom",
                "file-type": 41,
                "dock-extra": False,
                "file-data": {"_CFURLString": pathlib.Path(app).as_uri() + "/", "_CFURLStringType": 15},
            },
        })
    else:
        if not present:
            return 3
        dock["persistent-apps"] = [t for t in apps if not is_ours(t, app)]
    with open(out, "wb") as f:
        plistlib.dump(dock, f, fmt=plistlib.FMT_BINARY)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

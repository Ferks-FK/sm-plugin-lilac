#!/usr/bin/env python3
"""Keep updatefile.txt's version and Source file list in sync with the repo.

Run from the repository root (CI does this on every push to master). Only
touches the "Latest" version field and the "Source" file list — "Notes" and
the "Plugin" (translations/smx) entries still need a human, since a script
can't summarize what changed in a release.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GLOBALS_SP = ROOT / "addons/sourcemod/scripting/lilac/lilac_globals.sp"
LILAC_DIR = ROOT / "addons/sourcemod/scripting/lilac"
UPDATEFILE = ROOT / "updatefile.txt"


def main():
    globals_text = GLOBALS_SP.read_text(encoding="utf-8")
    version_match = re.search(r'PLUGIN_VERSION\s+"([^"]+)"', globals_text)
    if not version_match:
        sys.exit("Could not find PLUGIN_VERSION in lilac_globals.sp")
    version = version_match.group(1)

    # Default universal-newlines read normalizes any CRLF/CR in the file to
    # \n, so the regexes below only ever have to deal with \n. Write forces
    # \n back out explicitly (newline="\n") so the file stays LF regardless
    # of the platform running this.
    content = UPDATEFILE.read_text(encoding="utf-8")

    content, n = re.subn(r'("Latest"\s+)"[^"]*"', rf'\g<1>"{version}"', content, count=1)
    if n != 1:
        sys.exit('Could not find the "Latest" version field in updatefile.txt')

    sources = ["lilac.sp"] + sorted(f"lilac/{p.name}" for p in LILAC_DIR.glob("*.sp"))
    source_lines = "\n".join(f'\t\t"Source"\t"Path_SM/scripting/{s}"' for s in sources)

    content, n = re.subn(
        r'(?:\t\t"Source"\t"[^"]*"\n?)+',
        source_lines + "\n",
        content,
        count=1,
    )
    if n != 1:
        sys.exit('Could not find the "Source" file list in updatefile.txt')

    UPDATEFILE.write_text(content, encoding="utf-8", newline="\n")
    print(f"Synced updatefile.txt: version={version}, {len(sources)} source files.")


if __name__ == "__main__":
    main()

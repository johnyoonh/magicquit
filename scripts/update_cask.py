#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: update_cask.py VERSION SHA256", file=sys.stderr)
        return 2

    version, sha256 = sys.argv[1:]
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        raise SystemExit(f"invalid version: {version}")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit("invalid SHA256")

    path = pathlib.Path("packaging/homebrew/magicquit.rb")
    text = path.read_text()
    text = re.sub(r'^  version ".*"$', f'  version "{version}"', text, flags=re.MULTILINE)
    text = re.sub(r'^  sha256 ".*"$', f'  sha256 "{sha256}"', text, flags=re.MULTILINE)
    path.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Require every shipped Mach-O file to support both native Mac architectures."""

import argparse
import subprocess
import sys
from pathlib import Path


MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def verify(root):
    if not root.is_dir():
        raise ValueError(f"Missing distribution directory: {root}")
    count = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as source:
            magic = source.read(4)
        if magic not in MACHO_MAGIC:
            continue
        architectures = set(subprocess.check_output(
            ["/usr/bin/lipo", "-archs", str(path)], text=True).split())
        if not {"arm64", "x86_64"}.issubset(architectures):
            raise ValueError(f"Native architecture missing: {path.relative_to(root)} ({', '.join(sorted(architectures))})")
        count += 1
    if not count:
        raise ValueError("No Mach-O code found in distribution")
    print(f"Verified native arm64 and x86_64 support: {count} Mach-O files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        verify(args.directory)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Architecture validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

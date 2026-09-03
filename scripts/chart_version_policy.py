#!/usr/bin/env python3
import re
import sys
from collections.abc import Iterable
from pathlib import PurePosixPath


VALUES_FILE = re.compile(r"values(?:-[^/]+)?\.ya?ml")


def requires_version_increment(changed_paths: Iterable[str]) -> bool:
    for raw_path in changed_paths:
        path = PurePosixPath(raw_path)
        if path.parts[:2] != ("charts", "apps") or len(path.parts) < 4:
            continue
        if len(path.parts) == 4 and VALUES_FILE.fullmatch(path.name):
            continue
        return True
    return False


if __name__ == "__main__":
    print(str(requires_version_increment(sys.argv[1:])).lower())

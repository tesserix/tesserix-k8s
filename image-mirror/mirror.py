#!/usr/bin/env python3
"""
Mirror third-party container images into ghcr.io/tesserix/third-party/*.

Reads image-mirror/images.yaml and, for each entry, copies the chosen upstream
tag into the target registry using `crane`. Idempotent: crane copy is a no-op
when the destination digest already matches the source, so re-runs are cheap.

  mode: tag     -> copy entry.tag verbatim.
  mode: semver  -> list upstream tags, filter by tagFilter, keep those inside
                   `constraint` (">=A.B.C <D.E.F"), copy the highest one.

Env:
  REGISTRY   target base (default from manifest `registry:` key)
  DRY_RUN    "1" to resolve + log without copying
  ONLY       comma-separated entry names to limit the run (optional)

Exit code is non-zero if any image fails, after attempting them all.
"""
import os
import re
import subprocess
import sys

import yaml

MANIFEST = os.path.join(os.path.dirname(__file__), "images.yaml")
DRY_RUN = os.environ.get("DRY_RUN") == "1"
ONLY = {s for s in os.environ.get("ONLY", "").split(",") if s}


def run(cmd, capture=False):
    """Run a command; return stdout (capture) or None. Raises on failure."""
    res = subprocess.run(
        cmd, check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return res.stdout if capture else None


def parse_version(tag):
    """Strip a leading 'v' and parse leading numeric dotted parts to a tuple."""
    t = tag[1:] if tag.startswith("v") else tag
    m = re.match(r"^(\d+(?:\.\d+){0,3})", t)
    if not m:
        return None
    parts = [int(p) for p in m.group(1).split(".")]
    while len(parts) < 4:
        parts.append(0)
    return tuple(parts[:4])


def parse_bound(token):
    """'>=1.24.0' -> ('>=', (1,24,0,0)). Supports >=, >, <=, <, =."""
    m = re.match(r"^(>=|<=|>|<|=)?\s*(\d+(?:\.\d+)*)$", token)
    if not m:
        raise ValueError(f"bad constraint token: {token!r}")
    op = m.group(1) or "="
    return op, parse_version(m.group(2))


def satisfies(ver, constraint):
    for token in constraint.split():
        op, bound = parse_bound(token)
        if op == ">=" and not ver >= bound:
            return False
        if op == ">" and not ver > bound:
            return False
        if op == "<=" and not ver <= bound:
            return False
        if op == "<" and not ver < bound:
            return False
        if op == "=" and not ver == bound:
            return False
    return True


def resolve_semver_tag(source, constraint, tag_filter):
    """Return the highest upstream tag inside the constraint, or None."""
    out = run(["crane", "ls", source], capture=True)
    candidates = []
    pat = re.compile(tag_filter) if tag_filter else re.compile(r"^v?\d+(\.\d+){1,3}$")
    for raw in out.splitlines():
        raw = raw.strip()
        if not raw or not pat.match(raw):
            continue
        ver = parse_version(raw)
        if ver is None or not satisfies(ver, constraint):
            continue
        candidates.append((ver, raw))
    if not candidates:
        return None
    # Highest version wins; if two raw tags map to the same version keep the
    # lexically larger raw tag for stability.
    candidates.sort(key=lambda c: (c[0], c[1]))
    return candidates[-1][1]


def main():
    with open(MANIFEST) as fh:
        manifest = yaml.safe_load(fh)

    registry = os.environ.get("REGISTRY") or manifest["registry"]
    failures, copied, skipped = [], [], []

    for entry in manifest["images"]:
        name = entry["name"]
        if ONLY and name not in ONLY:
            continue
        source = entry["source"]
        mode = entry["mode"]

        try:
            if mode == "tag":
                tag = str(entry["tag"])
            elif mode == "semver":
                tag = resolve_semver_tag(
                    source, entry["constraint"], entry.get("tagFilter")
                )
                if tag is None:
                    raise RuntimeError(
                        f"no upstream tag satisfies {entry['constraint']!r}"
                    )
            else:
                raise RuntimeError(f"unknown mode {mode!r}")

            src = f"{source}:{tag}"
            dst = f"{registry}/{name}:{tag}"
            print(f"==> {name}: {src}  ->  {dst}", flush=True)

            if DRY_RUN:
                skipped.append((name, tag))
                continue

            run(["crane", "copy", src, dst])
            copied.append((name, tag))
        except subprocess.CalledProcessError as exc:
            msg = (exc.stderr or "").strip() or str(exc)
            print(f"!! {name}: crane failed: {msg}", file=sys.stderr, flush=True)
            failures.append((name, msg))
        except Exception as exc:  # noqa: BLE001 - report and continue
            print(f"!! {name}: {exc}", file=sys.stderr, flush=True)
            failures.append((name, str(exc)))

    # GitHub step summary (best-effort).
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write("## Third-party image mirror\n\n")
            fh.write(f"- copied: **{len(copied)}**\n")
            fh.write(f"- dry-run resolved: **{len(skipped)}**\n")
            fh.write(f"- failures: **{len(failures)}**\n\n")
            if copied:
                fh.write("### Copied\n")
                for n, t in copied:
                    fh.write(f"- `{n}:{t}`\n")
            if failures:
                fh.write("\n### Failures\n")
                for n, m in failures:
                    fh.write(f"- `{n}` — {m}\n")

    print(
        f"\nDone. copied={len(copied)} resolved(dry)={len(skipped)} "
        f"failed={len(failures)}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

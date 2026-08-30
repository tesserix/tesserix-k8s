#!/usr/bin/env python3
"""Delete stale GHCR container versions for every package in an organization.

The script deliberately uses only Python's standard library so it can run on a
GitHub-hosted runner without installing dependencies.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.utils
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Mapping, Sequence


API_VERSION = "2026-03-10"
DEFAULT_API_URL = "https://api.github.com"
PARTIAL = "partial"
COMPLETE = "complete"
_DURATION_RE = re.compile(r"^(?P<count>[1-9][0-9]*)\s*(?P<unit>[dhm])$")


class CleanupError(RuntimeError):
    """A fatal cleanup error."""


class SoftDeadlineReached(RuntimeError):
    """The run should stop cleanly and continue in another workflow run."""


@dataclass(frozen=True)
class Response:
    status: int
    headers: Mapping[str, str]
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


@dataclass
class CleanupResult:
    status: str = COMPLETE
    packages_discovered: int = 0
    packages_processed: int = 0
    versions_examined: int = 0
    versions_deleted: int = 0
    versions_would_delete: int = 0
    resume_after: str = ""


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_duration(value: str) -> dt.timedelta:
    match = _DURATION_RE.fullmatch(value.strip().lower())
    if not match:
        raise argparse.ArgumentTypeError(
            "duration must be a positive integer followed by d, h, or m (for example: 5d)"
        )
    count = int(match.group("count"))
    unit = match.group("unit")
    return {
        "d": dt.timedelta(days=count),
        "h": dt.timedelta(hours=count),
        "m": dt.timedelta(minutes=count),
    }[unit]


def parse_github_time(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


_TAG_RE = re.compile(r'^\s*tag:\s*["\']?([A-Za-z0-9][A-Za-z0-9._-]*)["\']?\s*(?:#.*)?$')
# Kargo writes image tags into ArgoCD Application helm parameters as
# `value: "<tag>"` lines; over-matching unrelated values only over-protects.
_PARAM_VALUE_RE = re.compile(
    r'^\s*value:\s*["\']?([A-Za-z0-9][A-Za-z0-9._-]*)["\']?\s*(?:#.*)?$'
)


def deployed_image_tags(chart_root: str) -> set[str]:
    """Collect every image tag pinned by a manifest under `chart_root`.

    These are the tags production is actually running. A cluster on preemptible
    nodes re-pulls an image whenever a pod moves, so deleting one of these from
    GHCR does not fail loudly at deletion time — it fails days or weeks later,
    when a node is replaced and the pull 404s with the workload already down.
    Reading them from the charts keeps the keep-list honest without needing
    cluster access from CI.
    """
    tags: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(chart_root):
        for filename in filenames:
            if not filename.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, filename)
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    for line in handle:
                        match = _TAG_RE.match(line) or _PARAM_VALUE_RE.match(line)
                        if match:
                            tags.add(match.group(1))
            except OSError:
                continue
    return tags


def select_deletable_versions(
    versions: Sequence[Mapping[str, Any]],
    *,
    cutoff: dt.datetime,
    keep: int,
    protected_tags: Iterable[str] = (),
) -> list[Mapping[str, Any]]:
    """Return versions outside the newest `keep` whose updated_at is old enough.

    A version carrying any protected tag is never deletable, however old it is:
    something in production is pinned to it. Age is a poor proxy for "unused" —
    an app that simply has not been rebuilt in months is still running.
    """
    protected = {tag for tag in protected_tags if tag}
    ordered = sorted(
        versions,
        key=lambda version: (
            parse_github_time(str(version["updated_at"])),
            int(version["id"]),
        ),
        reverse=True,
    )
    return [
        version
        for version in ordered[keep:]
        if parse_github_time(str(version["updated_at"])) < cutoff
        and not (protected & set(version_tag_list(version)))
    ]


class GitHubClient:
    def __init__(
        self,
        token: str,
        *,
        api_url: str = DEFAULT_API_URL,
        deadline_monotonic: float | None = None,
        request: Callable[[urllib.request.Request], Response] | None = None,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
        wall_time: Callable[[], float] = time.time,
        max_attempts: int = 8,
    ) -> None:
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.deadline_monotonic = deadline_monotonic
        self._request = request or self._urlopen
        self._sleep = sleep
        self._monotonic = monotonic
        self._wall_time = wall_time
        self.max_attempts = max_attempts

    @staticmethod
    def _urlopen(request: urllib.request.Request) -> Response:
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return Response(
                    status=response.status,
                    headers={
                        key.lower(): value for key, value in response.headers.items()
                    },
                    body=response.read(),
                )
        except urllib.error.HTTPError as error:
            return Response(
                status=error.code,
                headers={key.lower(): value for key, value in error.headers.items()},
                body=error.read(),
            )

    def _ensure_time_for(self, delay: float) -> None:
        if (
            self.deadline_monotonic is not None
            and self._monotonic() + max(delay, 0) >= self.deadline_monotonic
        ):
            raise SoftDeadlineReached

    def _wait(self, delay: float, reason: str) -> None:
        delay = max(delay, 1)
        self._ensure_time_for(delay)
        print(f"Waiting {delay:.0f}s before retrying ({reason})", flush=True)
        self._sleep(delay)

    @staticmethod
    def _message(response: Response) -> str:
        try:
            payload = response.json()
            return str(payload.get("message", response.body.decode("utf-8", "replace")))
        except (json.JSONDecodeError, AttributeError):
            return response.body.decode("utf-8", "replace")

    def _retry_delay(
        self, response: Response, attempt: int
    ) -> tuple[float, str] | None:
        retry_after = response.headers.get("retry-after")
        if retry_after:
            try:
                return float(retry_after) + 1, "GitHub Retry-After"
            except ValueError:
                try:
                    retry_at = email.utils.parsedate_to_datetime(
                        retry_after
                    ).timestamp()
                    return max(
                        retry_at - self._wall_time(), 1
                    ) + 1, "GitHub Retry-After"
                except (TypeError, ValueError):
                    pass

        remaining = response.headers.get("x-ratelimit-remaining")
        reset = response.headers.get("x-ratelimit-reset")
        if response.status == 403 and remaining == "0" and reset:
            try:
                return max(
                    float(reset) - self._wall_time(), 1
                ) + 5, "primary rate limit"
            except ValueError:
                pass

        message = self._message(response).lower()
        if response.status == 403 and not any(
            marker in message
            for marker in ("rate limit", "abuse", "temporarily blocked")
        ):
            return None
        if response.status in {403, 429}:
            delay = min(2**attempt, 300) + random.uniform(0, 1)
            return delay, "secondary rate limit"
        if response.status >= 500:
            delay = min(2**attempt, 60) + random.uniform(0, 1)
            return delay, f"GitHub HTTP {response.status}"
        return None

    def call(
        self,
        method: str,
        path: str,
        *,
        expected: Iterable[int] = (200,),
    ) -> Response:
        url = path if path.startswith("http") else f"{self.api_url}{path}"
        expected_statuses = set(expected)
        last_error = ""

        for attempt in range(self.max_attempts):
            self._ensure_time_for(0)
            request = urllib.request.Request(
                url,
                method=method,
                headers={
                    "Accept": "application/vnd.github+json",
                    "Authorization": f"Bearer {self.token}",
                    "User-Agent": "tesserix-ghcr-cleanup",
                    "X-GitHub-Api-Version": API_VERSION,
                },
            )
            try:
                response = self._request(request)
            except (TimeoutError, urllib.error.URLError, ConnectionError) as error:
                last_error = str(error)
                if attempt + 1 >= self.max_attempts:
                    break
                self._wait(
                    min(2**attempt, 60) + random.uniform(0, 1),
                    f"network error: {error}",
                )
                continue

            if response.status in expected_statuses:
                return response

            diagnostic_headers = []
            for header in (
                "x-github-request-id",
                "x-github-api-version-selected",
                "x-accepted-github-permissions",
            ):
                if value := response.headers.get(header):
                    diagnostic_headers.append(f"{header}={value}")
            diagnostics = (
                f" ({', '.join(diagnostic_headers)})" if diagnostic_headers else ""
            )
            last_error = (
                f"HTTP {response.status}: {self._message(response)}{diagnostics}"
            )
            retry = self._retry_delay(response, attempt)
            if retry is None or attempt + 1 >= self.max_attempts:
                break
            self._wait(*retry)

        raise CleanupError(f"{method} {url} failed after retries: {last_error}")

    def paginated(self, path: str) -> list[Mapping[str, Any]]:
        separator = "&" if "?" in path else "?"
        url = f"{path}{separator}per_page=100&page=1"
        items: list[Mapping[str, Any]] = []
        while url:
            response = self.call("GET", url)
            payload = response.json()
            if not isinstance(payload, list):
                raise CleanupError(
                    f"Expected a list from {url}, received {type(payload).__name__}"
                )
            items.extend(payload)
            url = next_link(response.headers.get("link", ""))
        return items


_MANIFEST_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


class RegistryClient:
    """Resolves which untagged versions are children of kept multi-arch tags.

    GHCR stores every child manifest of a multi-arch image as an *untagged*
    package version. Deleting those by age alone leaves the tagged parent
    resolving to 404ing children: the tag still lists, the pull fails.
    """

    def __init__(self, token: str, *, registry: str = "https://ghcr.io") -> None:
        self._token = token
        self._registry = registry.rstrip("/")
        self._bearer_cache: dict[str, str] = {}

    def _bearer(self, repository: str) -> str:
        cached = self._bearer_cache.get(repository)
        if cached:
            return cached
        basic = base64.b64encode(f"x:{self._token}".encode()).decode()
        request = urllib.request.Request(
            f"{self._registry}/token?scope=repository:{repository}:pull",
            headers={"Authorization": f"Basic {basic}"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            bearer = json.load(response).get("token", "")
        if not bearer:
            raise CleanupError(f"registry token exchange failed for {repository}")
        self._bearer_cache[repository] = bearer
        return bearer

    def child_digests(self, repository: str, digest: str) -> set[str]:
        request = urllib.request.Request(
            f"{self._registry}/v2/{repository}/manifests/{digest}",
            headers={
                "Authorization": f"Bearer {self._bearer(repository)}",
                "Accept": _MANIFEST_ACCEPT,
            },
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            manifest = json.load(response)
        return {
            str(entry["digest"])
            for entry in manifest.get("manifests", ())
            if entry.get("digest")
        }


def drop_referenced_untagged(
    registry: RegistryClient | None,
    repository: str,
    versions: Sequence[Mapping[str, Any]],
    deletable: Sequence[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    """Keep untagged versions that kept tags still reference (or might).

    Only registry-verified orphans are deletable; if the registry cannot be
    consulted, every untagged version survives — orphan blobs are cheap,
    a 404ing production tag is not.
    """
    untagged = [v for v in deletable if not version_tag_list(v)]
    if not untagged:
        return list(deletable)
    referenced: set[str] | None
    if registry is None:
        referenced = None
    else:
        deletable_ids = {int(v["id"]) for v in deletable}
        try:
            referenced = set()
            for version in versions:
                if int(version["id"]) in deletable_ids:
                    continue
                if not version_tag_list(version):
                    continue
                referenced |= registry.child_digests(
                    repository, str(version["name"])
                )
        except (CleanupError, OSError, ValueError) as error:
            print(
                f"{repository}: registry lookup failed ({error}); "
                "keeping all untagged versions",
                flush=True,
            )
            referenced = None
    if referenced is None:
        return [v for v in deletable if version_tag_list(v)]
    return [
        v
        for v in deletable
        if version_tag_list(v) or str(v["name"]) not in referenced
    ]


def next_link(link_header: str) -> str:
    for entry in link_header.split(","):
        match = re.match(r'\s*<([^>]+)>;\s*rel="([^"]+)"', entry)
        if match and match.group(2) == "next":
            return match.group(1)
    return ""


def package_versions_path(org: str, package_name: str) -> str:
    encoded_name = urllib.parse.quote(package_name, safe="")
    return f"/orgs/{urllib.parse.quote(org, safe='')}/packages/container/{encoded_name}/versions"


def version_tag_list(version: Mapping[str, Any]) -> list[str]:
    """The tags on a version, as a list. `version_tags` formats these for logs."""
    metadata = version.get("metadata")
    if not isinstance(metadata, Mapping):
        return []
    container = metadata.get("container")
    if not isinstance(container, Mapping):
        return []
    tags = container.get("tags")
    if not isinstance(tags, list):
        return []
    return [str(tag) for tag in tags]


def version_tags(version: Mapping[str, Any]) -> str:
    metadata = version.get("metadata")
    if not isinstance(metadata, Mapping):
        return "<untagged>"
    container = metadata.get("container")
    if not isinstance(container, Mapping):
        return "<untagged>"
    tags = container.get("tags")
    if not isinstance(tags, list) or not tags:
        return "<untagged>"
    return ",".join(str(tag) for tag in tags)


def cleanup(
    client: GitHubClient,
    *,
    org: str,
    cutoff_delta: dt.timedelta,
    keep: int,
    dry_run: bool,
    resume_after: str = "",
    protected_tags: Iterable[str] = (),
    registry: RegistryClient | None = None,
    now: dt.datetime | None = None,
) -> CleanupResult:
    protected_tags = set(protected_tags)
    result = CleanupResult(resume_after=resume_after)
    try:
        packages = client.paginated(
            f"/orgs/{urllib.parse.quote(org, safe='')}/packages?package_type=container"
        )
    except SoftDeadlineReached:
        result.status = PARTIAL
        print(
            "Soft deadline reached while listing packages; "
            f"the continuation will resume after {resume_after or '<start>'}",
            flush=True,
        )
        return result
    packages = sorted(packages, key=lambda package: str(package["name"]).casefold())
    result.packages_discovered = len(packages)
    cutoff = (now or utc_now()) - cutoff_delta
    print(
        f"Discovered {len(packages)} container packages in {org}; "
        f"cutoff={cutoff.isoformat()}, keep={keep}, dry_run={dry_run}, "
        f"protected_tags={len(protected_tags)}",
        flush=True,
    )

    for package in packages:
        name = str(package["name"])
        if resume_after and name.casefold() <= resume_after.casefold():
            continue
        try:
            versions_path = package_versions_path(org, name)
            versions = client.paginated(versions_path)
            result.versions_examined += len(versions)
            deletable = select_deletable_versions(
                versions, cutoff=cutoff, keep=keep, protected_tags=protected_tags
            )
            deletable = drop_referenced_untagged(
                registry, f"{org}/{name}", versions, deletable
            )
            print(
                f"{name}: {len(versions)} versions, {len(deletable)} eligible for deletion",
                flush=True,
            )
            for version in deletable:
                version_id = int(version["id"])
                tags = version_tags(version)
                if dry_run:
                    result.versions_would_delete += 1
                    print(
                        f"DRY RUN {name}: would delete version {version_id} "
                        f"updated={version['updated_at']} tags={tags}",
                        flush=True,
                    )
                    continue
                client.call(
                    "DELETE",
                    f"{versions_path}/{version_id}",
                    expected=(204,),
                )
                result.versions_deleted += 1
                print(
                    f"{name}: deleted version {version_id} "
                    f"updated={version['updated_at']} tags={tags}",
                    flush=True,
                )
        except SoftDeadlineReached:
            result.status = PARTIAL
            print(
                f"Soft deadline reached while processing {name}; "
                f"the continuation will resume after {result.resume_after or '<start>'}",
                flush=True,
            )
            return result

        result.packages_processed += 1
        result.resume_after = name

    result.resume_after = ""
    return result


def write_github_outputs(result: CleanupResult) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    values = {
        "status": result.status,
        "resume-after": result.resume_after,
        "packages-discovered": result.packages_discovered,
        "packages-processed": result.packages_processed,
        "versions-examined": result.versions_examined,
        "versions-deleted": result.versions_deleted,
        "versions-would-delete": result.versions_would_delete,
    }
    with open(output_path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", required=True)
    parser.add_argument("--cut-off", type=parse_duration, default=parse_duration("5d"))
    parser.add_argument("--keep", type=int, default=3)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume-after", default="")
    parser.add_argument(
        "--soft-timeout-seconds",
        type=int,
        default=19_800,
        help="Stop cleanly after this many seconds so another workflow run can continue",
    )
    parser.add_argument(
        "--api-url", default=os.environ.get("GITHUB_API_URL", DEFAULT_API_URL)
    )
    parser.add_argument(
        "--protect-tags-from",
        action="append",
        default=[],
        help=(
            "Directory to scan for pinned image tags (repeatable). Any GHCR "
            "version carrying one of those tags is never deleted, regardless of "
            "age — production is running it."
        ),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.keep < 0:
        raise SystemExit("--keep cannot be negative")
    token = os.environ.get("GHCR_TOKEN", "").strip()
    if not token:
        raise SystemExit("GHCR_TOKEN is required")

    protected_tags: set[str] = set()
    for protect_root in args.protect_tags_from:
        if not os.path.isdir(protect_root):
            raise SystemExit(
                f"--protect-tags-from: no such directory: {protect_root}"
            )
        found = deployed_image_tags(protect_root)
        # Deleting an in-use image is silent until a node is replaced, so a
        # misconfigured path that silently protected nothing would be worse than
        # the bug this guards against. Fail loudly instead.
        if not found:
            raise SystemExit(
                f"--protect-tags-from: no image tags found under "
                f"{protect_root}; refusing to run with an empty keep-list"
            )
        protected_tags |= found
    if args.protect_tags_from:
        print(f"Protecting {len(protected_tags)} tags pinned by manifests", flush=True)

    deadline = time.monotonic() + args.soft_timeout_seconds
    client = GitHubClient(
        token,
        api_url=args.api_url,
        deadline_monotonic=deadline,
    )
    try:
        result = cleanup(
            client,
            org=args.org,
            cutoff_delta=args.cut_off,
            keep=args.keep,
            dry_run=args.dry_run,
            resume_after=args.resume_after,
            protected_tags=protected_tags,
            registry=RegistryClient(token),
        )
    except (CleanupError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    write_github_outputs(result)
    print(
        "Result: "
        f"status={result.status}, packages={result.packages_processed}/"
        f"{result.packages_discovered}, examined={result.versions_examined}, "
        f"deleted={result.versions_deleted}, "
        f"would_delete={result.versions_would_delete}, "
        f"resume_after={result.resume_after or '<none>'}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

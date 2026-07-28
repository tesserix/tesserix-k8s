import datetime as dt
import importlib.util
import pathlib
import shutil
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "ghcr_cleanup.py"
SPEC = importlib.util.spec_from_file_location("ghcr_cleanup", SCRIPT)
assert SPEC and SPEC.loader
ghcr_cleanup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ghcr_cleanup
SPEC.loader.exec_module(ghcr_cleanup)


UTC = dt.timezone.utc


def version(version_id, days_old, *, now, tags=None):
    return {
        "id": version_id,
        "updated_at": (now - dt.timedelta(days=days_old)).isoformat(),
        "metadata": {"container": {"tags": tags or []}},
    }


class FakeCleanupClient:
    def __init__(self, packages, versions, *, deadline_package=None):
        self.packages = packages
        self.versions = versions
        self.deadline_package = deadline_package
        self.deleted = []

    def paginated(self, path):
        if path.endswith("package_type=container"):
            return self.packages
        package_name = path.split("/container/", 1)[1].split("/versions", 1)[0]
        package_name = ghcr_cleanup.urllib.parse.unquote(package_name)
        if package_name == self.deadline_package:
            raise ghcr_cleanup.SoftDeadlineReached
        return self.versions[package_name]

    def call(self, method, path, *, expected=(200,)):
        self.deleted.append((method, path))
        return ghcr_cleanup.Response(204, {}, b"")


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 7, 26, 12, 0, tzinfo=UTC)

    def test_keeps_newest_three_even_when_all_are_old(self):
        versions = [
            version(1, 20, now=self.now, tags=["one"]),
            version(2, 19, now=self.now, tags=["two"]),
            version(3, 18, now=self.now, tags=["three"]),
            version(4, 17, now=self.now, tags=["four"]),
            version(5, 16, now=self.now, tags=["five"]),
        ]

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=7),
            keep=3,
        )

        self.assertEqual([2, 1], [item["id"] for item in selected])

    def test_never_deletes_a_tag_a_chart_still_pins(self):
        # The outage: tesserix-auth-bff was pinned to main-3a47f1d in May and not
        # rebuilt since, so it fell outside both newest-3 and the 5-day cutoff and
        # was deleted. Nothing broke until GKE recycled the spot node it ran on,
        # months later, and the re-pull 404'd.
        versions = [
            version(1, 90, now=self.now, tags=["main-3a47f1d"]),
            version(2, 80, now=self.now, tags=["main-older"]),
            version(3, 70, now=self.now, tags=["main-oldest"]),
            version(4, 60, now=self.now, tags=["stale-a"]),
            version(5, 50, now=self.now, tags=["stale-b"]),
        ]

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=5),
            keep=3,
            protected_tags={"main-3a47f1d"},
        )

        # Newest-3 (5, 4, 3) are retained by the keep rule; of the remaining
        # (2, 1) only the pinned one is spared.
        self.assertNotIn(1, [item["id"] for item in selected])
        self.assertEqual([2], [item["id"] for item in selected])

    def test_protects_a_version_when_any_of_its_tags_is_pinned(self):
        # GHCR deletes a whole version, and a version can carry several tags. If
        # even one is pinned, deleting the version takes the pinned tag with it.
        versions = [
            version(1, 90, now=self.now, tags=["sha-22dfeda1af45", "latest"]),
            version(2, 80, now=self.now, tags=["unused"]),
            version(3, 70, now=self.now, tags=["unused-2"]),
            version(4, 60, now=self.now, tags=["unused-3"]),
        ]

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=5),
            keep=3,
            protected_tags={"sha-22dfeda1af45"},
        )

        self.assertEqual([], selected)

    def test_untagged_versions_are_still_collectable(self):
        # The keep-list must not turn cleanup into a no-op: untagged layers are
        # the bulk of what this workflow exists to reclaim.
        versions = [
            version(1, 90, now=self.now, tags=["pinned"]),
            version(2, 80, now=self.now, tags=[]),
            version(3, 70, now=self.now, tags=[]),
            version(4, 60, now=self.now, tags=[]),
            version(5, 50, now=self.now, tags=[]),
        ]

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=5),
            keep=3,
            protected_tags={"pinned"},
        )

        # 1 is pinned and spared; 2 is untagged, old, and outside newest-3, so
        # cleanup still reclaims it.
        self.assertEqual([2], [item["id"] for item in selected])

    def test_keeps_versions_newer_than_cutoff_beyond_newest_three(self):
        versions = [
            version(1, 1, now=self.now),
            version(2, 2, now=self.now),
            version(3, 3, now=self.now),
            version(4, 4, now=self.now),
            version(5, 8, now=self.now),
        ]

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=7),
            keep=3,
        )

        self.assertEqual([5], [item["id"] for item in selected])

    def test_exact_cutoff_is_retained(self):
        versions = [version(index, index, now=self.now) for index in range(1, 8)]
        versions.append(version(8, 7, now=self.now))

        selected = ghcr_cleanup.select_deletable_versions(
            versions,
            cutoff=self.now - dt.timedelta(days=7),
            keep=3,
        )

        self.assertNotIn(8, [item["id"] for item in selected])

    def test_dry_run_never_calls_delete(self):
        client = FakeCleanupClient(
            [{"name": "service"}],
            {
                "service": [
                    version(index, index + 10, now=self.now) for index in range(1, 6)
                ]
            },
        )

        result = ghcr_cleanup.cleanup(
            client,
            org="tesserix",
            cutoff_delta=dt.timedelta(days=7),
            keep=3,
            dry_run=True,
            now=self.now,
        )

        self.assertEqual(2, result.versions_would_delete)
        self.assertEqual([], client.deleted)
        self.assertEqual(ghcr_cleanup.COMPLETE, result.status)

    def test_partial_package_is_retried_by_continuation(self):
        client = FakeCleanupClient(
            [{"name": "alpha"}, {"name": "bravo"}, {"name": "charlie"}],
            {"alpha": [], "bravo": [], "charlie": []},
            deadline_package="bravo",
        )

        result = ghcr_cleanup.cleanup(
            client,
            org="tesserix",
            cutoff_delta=dt.timedelta(days=7),
            keep=3,
            dry_run=False,
            now=self.now,
        )

        self.assertEqual(ghcr_cleanup.PARTIAL, result.status)
        self.assertEqual("alpha", result.resume_after)
        self.assertEqual(1, result.packages_processed)

    def test_resume_cursor_skips_completed_packages(self):
        client = FakeCleanupClient(
            [{"name": "charlie"}, {"name": "alpha"}, {"name": "bravo"}],
            {"alpha": [], "bravo": [], "charlie": []},
        )

        result = ghcr_cleanup.cleanup(
            client,
            org="tesserix",
            cutoff_delta=dt.timedelta(days=7),
            keep=3,
            dry_run=False,
            resume_after="bravo",
            now=self.now,
        )

        self.assertEqual(1, result.packages_processed)
        self.assertEqual("", result.resume_after)


class ApiClientTests(unittest.TestCase):
    def test_requests_current_github_api_version(self):
        request = mock.Mock(
            return_value=ghcr_cleanup.Response(200, {}, b"[]")
        )
        client = ghcr_cleanup.GitHubClient("token", request=request)

        client.call("GET", "/items")

        sent_request = request.call_args.args[0]
        self.assertEqual(
            "2026-03-10",
            sent_request.headers["X-github-api-version"],
        )

    def test_pagination_follows_next_link(self):
        responses = [
            ghcr_cleanup.Response(
                200,
                {"link": '<https://api.github.test/items?page=2>; rel="next"'},
                b'[{"id": 1}]',
            ),
            ghcr_cleanup.Response(200, {}, b'[{"id": 2}]'),
        ]
        request = mock.Mock(side_effect=responses)
        client = ghcr_cleanup.GitHubClient("token", request=request)

        items = client.paginated("/items")

        self.assertEqual([1, 2], [item["id"] for item in items])
        self.assertEqual(2, request.call_count)

    def test_waits_for_primary_rate_limit_reset_then_retries(self):
        clock = {"monotonic": 0.0, "wall": 1_000.0}
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            clock["monotonic"] += seconds
            clock["wall"] += seconds

        request = mock.Mock(
            side_effect=[
                ghcr_cleanup.Response(
                    403,
                    {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1010"},
                    b'{"message":"rate limit exceeded"}',
                ),
                ghcr_cleanup.Response(200, {}, b"[]"),
            ]
        )
        client = ghcr_cleanup.GitHubClient(
            "token",
            request=request,
            sleep=sleep,
            monotonic=lambda: clock["monotonic"],
            wall_time=lambda: clock["wall"],
            deadline_monotonic=100,
        )

        response = client.call("GET", "/items")

        self.assertEqual(200, response.status)
        self.assertEqual([15], sleeps)
        self.assertEqual(2, request.call_count)

    def test_stops_before_retry_would_cross_soft_deadline(self):
        response = ghcr_cleanup.Response(
            403,
            {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1100"},
            b'{"message":"rate limit exceeded"}',
        )
        client = ghcr_cleanup.GitHubClient(
            "token",
            request=mock.Mock(return_value=response),
            sleep=mock.Mock(),
            monotonic=lambda: 0,
            wall_time=lambda: 1_000,
            deadline_monotonic=50,
        )

        with self.assertRaises(ghcr_cleanup.SoftDeadlineReached):
            client.call("GET", "/items")

    def test_retries_server_errors_and_fails_non_retryable_errors(self):
        sleeps = []
        request = mock.Mock(
            side_effect=[
                ghcr_cleanup.Response(503, {}, b'{"message":"unavailable"}'),
                ghcr_cleanup.Response(200, {}, b"[]"),
            ]
        )
        client = ghcr_cleanup.GitHubClient(
            "token",
            request=request,
            sleep=sleeps.append,
            monotonic=lambda: 0,
            deadline_monotonic=10_000,
        )

        self.assertEqual(200, client.call("GET", "/items").status)
        self.assertEqual(1, len(sleeps))

        fatal_client = ghcr_cleanup.GitHubClient(
            "token",
            request=mock.Mock(
                return_value=ghcr_cleanup.Response(
                    401, {}, b'{"message":"bad credentials"}'
                )
            ),
        )
        with self.assertRaisesRegex(ghcr_cleanup.CleanupError, "401"):
            fatal_client.call("GET", "/items")

    def test_does_not_retry_permission_denied(self):
        request = mock.Mock(
            return_value=ghcr_cleanup.Response(
                403,
                {"x-ratelimit-remaining": "4999"},
                b'{"message":"Resource not accessible by integration"}',
            )
        )
        client = ghcr_cleanup.GitHubClient(
            "token",
            request=request,
            sleep=mock.Mock(),
        )

        with self.assertRaisesRegex(ghcr_cleanup.CleanupError, "not accessible"):
            client.call("DELETE", "/items/1", expected=(204,))
        self.assertEqual(1, request.call_count)

    def test_encodes_nested_package_names_as_one_path_component(self):
        path = ghcr_cleanup.package_versions_path("tesserix", "team/service")
        self.assertEqual(
            "/orgs/tesserix/packages/container/team%2Fservice/versions",
            path,
        )


class ParsingTests(unittest.TestCase):
    def test_default_cutoff_is_five_days(self):
        args = ghcr_cleanup.build_parser().parse_args(["--org", "tesserix"])
        self.assertEqual(dt.timedelta(days=5), args.cut_off)

    def test_duration_parser(self):
        self.assertEqual(dt.timedelta(days=7), ghcr_cleanup.parse_duration("7d"))
        self.assertEqual(dt.timedelta(hours=24), ghcr_cleanup.parse_duration("24h"))
        self.assertEqual(dt.timedelta(minutes=30), ghcr_cleanup.parse_duration("30m"))
        with self.assertRaises(Exception):
            ghcr_cleanup.parse_duration("7 days")

    def test_next_link(self):
        header = (
            '<https://api.example/items?page=1>; rel="prev", '
            '<https://api.example/items?page=3>; rel="next"'
        )
        self.assertEqual(
            "https://api.example/items?page=3",
            ghcr_cleanup.next_link(header),
        )


class DeployedImageTagTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def write(self, relpath, body):
        path = pathlib.Path(self.root, relpath)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")

    def test_collects_tags_across_nested_charts(self):
        self.write(
            "apps/tesserix-auth-bff/values.yaml",
            """
            image:
              repository: ghcr.io/tesserix/mark8ly-auth-bff
              tag: "main-3a47f1d"
            """,
        )
        self.write(
            "apps/tesserix-storybook/values.yaml",
            """
            image:
              tag: sha-22dfeda1af45 # CI rewrites this on every push
            """,
        )

        self.assertEqual(
            {"main-3a47f1d", "sha-22dfeda1af45"},
            ghcr_cleanup.deployed_image_tags(self.root),
        )

    def test_reads_quoted_unquoted_and_commented_forms(self):
        self.write(
            "apps/a/values.yaml",
            """
            image:
              tag: "double"
            other:
              tag: 'single'
            third:
              tag: bare
            fourth:
              tag: trailing # with a comment
            """,
        )

        self.assertEqual(
            {"double", "single", "bare", "trailing"},
            ghcr_cleanup.deployed_image_tags(self.root),
        )

    def test_ignores_non_yaml_files(self):
        self.write("README.md", "tag: not-a-chart\n")

        self.assertEqual(set(), ghcr_cleanup.deployed_image_tags(self.root))

    def test_empty_tag_values_are_skipped(self):
        # `tag: ""` means "use the chart default" — it is not a real tag and must
        # not end up in the keep-list as an empty string.
        self.write(
            "apps/a/values.yaml",
            """
            image:
              tag: ""
            """,
        )

        self.assertEqual(set(), ghcr_cleanup.deployed_image_tags(self.root))


if __name__ == "__main__":
    unittest.main()

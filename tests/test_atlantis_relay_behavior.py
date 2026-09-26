import json
import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).parents[1]


class AtlantisRelayBehaviorTests(unittest.TestCase):
    def run_relay(
        self,
        *,
        plan="success",
        statuses=None,
        extra_checks=None,
        comments=None,
        draft=False,
    ):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/atlantis-auto-apply.yml").read_text()
        )
        script = workflow["jobs"]["request-apply"]["steps"][0]["with"]["script"]
        fixture = {
            "plan": plan,
            "statuses": statuses or [],
            "checks": extra_checks or [],
            "comments": comments or [],
            "draft": draft,
        }
        harness = (
            r"""
const fixture = JSON.parse(process.argv[1]);
const posted = [];
const checks = fixture.plan === null ? [] : [{name: "atlantis/plan", status: "completed", conclusion: fixture.plan}];
const github = {rest: {
  pulls: {get: async () => ({data: {state: "open", draft: fixture.draft, head: {sha: "head", repo: {fork: false}}}}), listReviews: async () => []},
  repos: {getCombinedStatusForRef: async () => ({data: {statuses: fixture.statuses}})},
  checks: {listForRef: async () => [...checks, ...fixture.checks]},
  issues: {listComments: async () => fixture.comments, createComment: async (data) => posted.push(data)}
}, paginate: async (fn, args) => fn(args)};
const context = {repo: {owner: "test", repo: "test"}, eventName: "check_run", payload: {check_run: {pull_requests: [{number: 1}]}}};
const core = {info: () => {}};
(async () => {
"""
            + script
            + "\n})().then(() => process.stdout.write(JSON.stringify(posted)));"
        )
        result = subprocess.run(
            ["node", "-e", harness, json.dumps(fixture)],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)

    def test_successful_plan_check_requests_apply_without_reviews(self):
        posted = self.run_relay()
        self.assertEqual(1, len(posted))
        self.assertTrue(posted[0]["body"].startswith("atlantis apply\n"))

    def test_failed_missing_and_pending_plans_block_apply(self):
        for plan in ("failure", None, "cancelled"):
            with self.subTest(plan=plan):
                self.assertEqual([], self.run_relay(plan=plan))

    def test_pending_ci_blocks_apply(self):
        self.assertEqual(
            [],
            self.run_relay(
                extra_checks=[
                    {
                        "name": "Repository tests",
                        "status": "in_progress",
                        "conclusion": None,
                    }
                ]
            ),
        )

    def test_failed_commit_status_blocks_apply(self):
        self.assertEqual(
            [], self.run_relay(statuses=[{"context": "security", "state": "failure"}])
        )

    def test_draft_blocks_apply(self):
        self.assertEqual([], self.run_relay(draft=True))

    def test_duplicate_head_does_not_request_apply_twice(self):
        self.assertEqual(
            [],
            self.run_relay(
                comments=[{"body": "atlantis apply\n<!-- atlantis-auto-apply:head -->"}]
            ),
        )

    def test_legacy_plan_status_is_supported(self):
        self.assertEqual(
            1,
            len(
                self.run_relay(
                    plan=None,
                    statuses=[{"context": "atlantis/plan", "state": "success"}],
                )
            ),
        )

    def test_pending_apply_does_not_block_its_own_request(self):
        self.assertEqual(
            1,
            len(
                self.run_relay(
                    extra_checks=[
                        {
                            "name": "atlantis/apply",
                            "status": "in_progress",
                            "conclusion": None,
                        }
                    ]
                )
            ),
        )

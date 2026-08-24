const assert = require("node:assert/strict");
const test = require("node:test");

const {
  isAtlantisManagedPath,
  run,
} = require("./atlantis-merge-gate.cjs");

test("classifies only paths covered by Atlantis projects", () => {
  const managed = [
    "atlantis.yaml",
    "terraform-new/stacks/01-foundation/main.tf",
    "terraform-new/modules/workload-identity/main.tf",
    "terraform-new/environments/prod/terraform.tfvars",
    "terraform-new/stacks/09-github-arc/runner-values.yaml",
    "terraform-new/stacks/09-github-arc/runner-values.yaml.tftpl",
  ];
  const unmanaged = [
    "charts/thirdparty/atlantis/values.yaml",
    "terraform-new/README.md",
    "terraform-new/stacks/01-foundation/.terraform.lock.hcl",
    "terraform-new/stacks/01-foundation/nested/main.tf",
    "terraform-new/stacks/09-github-arc/runner-values.yml",
    ".github/workflows/atlantis-auto-apply.yml",
  ];

  for (const path of managed) assert.equal(isAtlantisManagedPath(path), true, path);
  for (const path of unmanaged) assert.equal(isAtlantisManagedPath(path), false, path);
});

function harness(files, pullOverrides = {}) {
  const statuses = [];
  const messages = [];
  const listFiles = () => {};
  const pull = {
    number: 42,
    state: "open",
    draft: false,
    head: { sha: "abc123", repo: { fork: false } },
    ...pullOverrides,
  };
  const github = {
    paginate: async (method, parameters) => {
      assert.equal(method, listFiles);
      assert.equal(parameters.pull_number, pull.number);
      return files.map((filename) => ({ filename }));
    },
    rest: {
      pulls: { listFiles },
      repos: {
        createCommitStatus: async (status) => statuses.push(status),
      },
    },
  };
  const context = {
    repo: { owner: "tesserix", repo: "tesserix-k8s" },
    payload: { pull_request: pull },
    serverUrl: "https://github.com",
    runId: "12345",
  };
  const core = { info: (message) => messages.push(message) };
  return { core, github, context, messages, statuses };
}

test("posts only an apply success for a non-Terraform pull request", async () => {
  const fixture = harness(["charts/thirdparty/atlantis/values.yaml"]);

  await run(fixture);

  assert.equal(fixture.statuses.length, 1);
  assert.deepEqual(fixture.statuses[0], {
    owner: "tesserix",
    repo: "tesserix-k8s",
    sha: "abc123",
    state: "success",
    context: "atlantis/apply",
    description: "Not required: no Atlantis-managed changes.",
    target_url: "https://github.com/tesserix/tesserix-k8s/actions/runs/12345",
  });
});

test("does not bypass the apply status for a managed Terraform change", async () => {
  const fixture = harness(["terraform-new/stacks/01-foundation/main.tf"]);

  await run(fixture);

  assert.deepEqual(fixture.statuses, []);
});

test("does not grant a bypass to fork pull requests", async () => {
  const fixture = harness(
    ["charts/thirdparty/atlantis/values.yaml"],
    { head: { sha: "abc123", repo: { fork: true } } },
  );

  await run(fixture);

  assert.deepEqual(fixture.statuses, []);
});

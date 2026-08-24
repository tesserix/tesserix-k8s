function isAtlantisManagedPath(path) {
  return (
    path === "atlantis.yaml" ||
    path === "terraform-new/environments/prod/terraform.tfvars" ||
    /^terraform-new\/stacks\/[^/]+\/[^/]+\.tf$/.test(path) ||
    /^terraform-new\/modules\/.+\.tf$/.test(path) ||
    /^terraform-new\/stacks\/09-github-arc\/[^/]+\.yaml(?:\.tftpl)?$/.test(path)
  );
}

async function run({ github, context, core }) {
  const pull = context.payload.pull_request;
  if (
    !pull ||
    pull.state !== "open" ||
    pull.draft ||
    !pull.head.repo ||
    pull.head.repo.fork
  ) {
    core.info("The apply bypass is disabled for closed, draft, or fork pull requests.");
    return;
  }

  const files = await github.paginate(github.rest.pulls.listFiles, {
    ...context.repo,
    pull_number: pull.number,
    per_page: 100,
  });
  if (files.some(({ filename }) => isAtlantisManagedPath(filename))) {
    core.info("Atlantis-managed changes require the real atlantis/apply status.");
    return;
  }

  await github.rest.repos.createCommitStatus({
    ...context.repo,
    sha: pull.head.sha,
    state: "success",
    context: "atlantis/apply",
    description: "Not required: no Atlantis-managed changes.",
    target_url: `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
  });
}

module.exports = { isAtlantisManagedPath, run };

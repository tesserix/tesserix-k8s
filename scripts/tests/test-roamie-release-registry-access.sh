#!/usr/bin/env bash
set -euo pipefail

test_root=$(cd "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export TEST_GCLOUD_CALLS="$test_dir/calls"
cat > "$test_dir/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GCLOUD_CALLS"
case "$*" in
  'auth list '*) printf '%s\n' "${TEST_ACCOUNT:-unidevidp@gmail.com}" ;;
  'config get-value project') printf '%s\n' tesseracthub-480811 ;;
  'artifacts repositories get-iam-policy '*) printf '%s\n' '{"bindings":[]}' ;;
esac
MOCK
chmod +x "$test_dir/gcloud"
export PATH="$test_dir:$PATH"

bash "$test_root/scripts/setup-roamie-release-registry-access.sh" > "$test_dir/plan"
if grep -q 'add-iam-policy-binding' "$TEST_GCLOUD_CALLS"; then
  echo 'FAIL: default plan changed IAM' >&2; exit 1
fi
: > "$TEST_GCLOUD_CALLS"
bash "$test_root/scripts/setup-roamie-release-registry-access.sh" --apply > "$test_dir/apply"
for identity in kargo-controller@tesseracthub-480811.iam.gserviceaccount.com 849928263410-compute@developer.gserviceaccount.com; do
  grep -Fqx "artifacts repositories add-iam-policy-binding global --project=tesseracthub-480811 --location=asia-south1 --member=serviceAccount:$identity --role=roles/artifactregistry.reader --condition=None" "$TEST_GCLOUD_CALLS"
done
[[ $(grep -c 'add-iam-policy-binding' "$TEST_GCLOUD_CALLS") == 2 ]]
: > "$TEST_GCLOUD_CALLS"
if TEST_ACCOUNT=other@example.com bash "$test_root/scripts/setup-roamie-release-registry-access.sh" --apply > /dev/null 2>&1; then
  echo 'FAIL: unexpected cloud identity accepted' >&2; exit 1
fi
if grep -q 'add-iam-policy-binding' "$TEST_GCLOUD_CALLS"; then
  echo 'FAIL: identity mismatch changed IAM' >&2; exit 1
fi
if bash "$test_root/scripts/setup-roamie-release-registry-access.sh" --unknown > /dev/null 2>&1; then
  echo 'FAIL: unknown argument accepted' >&2; exit 1
fi
echo 'PASS: plan is read-only, apply grants exactly two repository readers, wrong identity and unknown arguments fail closed'

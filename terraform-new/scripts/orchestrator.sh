#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_FILE="$ROOT_DIR/dependencies.yaml"

ACTION="${1:-plan}"
TARGET_STACK="${2:-all}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
PARALLELISM="${PARALLELISM:-10}"
DRY_RUN="${DRY_RUN:-false}"

usage() {
  command cat <<'EOF'
Usage: ./scripts/orchestrator.sh <action> [stack]

Actions:
  deps      Print the canonical stack graph
  fmt       Check Terraform formatting
  validate  Initialize without a backend and validate
  init      Initialize the configured GCS backend
  plan      Create a saved plan after checking dependency state
  apply     Apply an existing saved plan; never creates a new plan
  output    Print stack outputs as JSON

Set DRY_RUN=true to print mutating/read commands without executing them.
The orchestrator intentionally has no destroy action.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

yaml() {
  yq -r "$1" "$DEPS_FILE"
}

stack_value() {
  local stack="$1"
  local field="$2"
  yaml ".stacks.\"${stack}\".${field}"
}

execution_order() {
  yaml '.execution_order[].stacks[]'
}

stack_dependencies() {
  local stack="$1"
  yaml ".stacks.\"${stack}\".dependencies[]" 2>/dev/null || true
}

ensure_stack() {
  local stack="$1"
  [[ "$(stack_value "$stack" path)" != "null" ]] || fail "unknown stack: $stack"
}

check_dependency_state() {
  local stack="$1"
  local dependency prefix object
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    prefix="$(stack_value "$dependency" state_prefix)"
    object="gs://${STATE_BUCKET}/${prefix}/default.tfstate"
    if [[ "$DRY_RUN" == "true" ]]; then
      run gcloud storage objects describe "$object"
    elif ! gcloud storage objects describe "$object" >/dev/null 2>&1; then
      fail "$stack depends on $dependency, but $object does not exist"
    fi
  done < <(stack_dependencies "$stack")
}

stack_command() {
  local action="$1"
  local stack="$2"
  local relative_path stack_dir plan_file

  ensure_stack "$stack"
  relative_path="$(stack_value "$stack" path)"
  stack_dir="$ROOT_DIR/$relative_path"
  plan_file="$stack_dir/$stack.tfplan"

  case "$action" in
    fmt)
      run terraform -chdir="$stack_dir" fmt -check -diff
      ;;
    validate)
      run terraform -chdir="$stack_dir" init -backend=false -input=false
      run terraform -chdir="$stack_dir" validate
      ;;
    init)
      run terraform -chdir="$stack_dir" init -input=false
      ;;
    plan)
      check_dependency_state "$stack"
      run terraform -chdir="$stack_dir" init -input=false
      run terraform -chdir="$stack_dir" plan \
        -input=false \
        -parallelism="$PARALLELISM" \
        -var-file="$ROOT_DIR/environments/$ENVIRONMENT/terraform.tfvars" \
        -out="$plan_file"
      ;;
    apply)
      check_dependency_state "$stack"
      if [[ "$DRY_RUN" != "true" && ! -f "$plan_file" ]]; then
        fail "saved plan not found: $plan_file; run plan first"
      fi
      run terraform -chdir="$stack_dir" init -input=false
      run terraform -chdir="$stack_dir" apply -input=false "$plan_file"
      ;;
    output)
      run terraform -chdir="$stack_dir" output -json
      ;;
    *)
      fail "unsupported action: $action"
      ;;
  esac
}

show_dependencies() {
  local stack dependencies
  while IFS= read -r stack; do
    dependencies="$(stack_dependencies "$stack" | paste -sd, -)"
    printf '%-28s %s\n' "$stack" "${dependencies:-(root)}"
  done < <(execution_order)
}

main() {
  [[ -f "$DEPS_FILE" ]] || fail "missing $DEPS_FILE"
  require_command yq

  case "$ACTION" in
    help|-h|--help)
      usage
      exit 0
      ;;
    deps)
      show_dependencies
      exit 0
      ;;
    fmt|validate|init|plan|apply|output)
      require_command terraform
      ;;
    destroy)
      fail "destroy is intentionally disabled; use an explicitly reviewed break-glass procedure"
      ;;
    *)
      usage >&2
      fail "unsupported action: $ACTION"
      ;;
  esac

  PROJECT_ID="$(yaml '.project.id')"
  STATE_BUCKET="$(yaml '.state.bucket')"
  CONFIGURED_ENVIRONMENT="$(yaml '.project.environment')"
  export PROJECT_ID STATE_BUCKET

  [[ "$ENVIRONMENT" == "$CONFIGURED_ENVIRONMENT" ]] || \
    fail "only the canonical $CONFIGURED_ENVIRONMENT environment is configured"
  [[ -f "$ROOT_DIR/environments/$ENVIRONMENT/terraform.tfvars" ]] || \
    fail "missing environment tfvars for $ENVIRONMENT"

  if [[ "$ACTION" == "plan" || "$ACTION" == "apply" ]]; then
    require_command gcloud
  fi

  if [[ "$TARGET_STACK" == "all" ]]; then
    while IFS= read -r stack; do
      printf '==> %s %s\n' "$ACTION" "$stack"
      stack_command "$ACTION" "$stack"
    done < <(execution_order)
  else
    stack_command "$ACTION" "$TARGET_STACK"
  fi
}

main "$@"

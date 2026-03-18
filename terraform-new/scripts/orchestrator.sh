#!/bin/bash
# Terraform Stack Orchestrator
# Manages multi-stack Terraform deployments with dependency awareness

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_FILE="${ROOT_DIR}/dependencies.yaml"

# Default values
ENVIRONMENT="${ENVIRONMENT:-prod}"
ACTION="${1:-plan}"
TARGET_STACK="${2:-all}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
PARALLELISM="${PARALLELISM:-10}"
DRY_RUN="${DRY_RUN:-false}"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."

    if ! command -v terraform &> /dev/null; then
        log_error "terraform is not installed"
        exit 1
    fi

    if ! command -v yq &> /dev/null; then
        log_warn "yq is not installed. Installing via brew..."
        brew install yq || { log_error "Failed to install yq"; exit 1; }
    fi

    if ! command -v jq &> /dev/null; then
        log_warn "jq is not installed. Installing via brew..."
        brew install jq || { log_error "Failed to install jq"; exit 1; }
    fi

    log_success "All dependencies satisfied"
}

# Parse dependencies.yaml
parse_config() {
    if [[ ! -f "$DEPS_FILE" ]]; then
        log_error "Dependencies file not found: $DEPS_FILE"
        exit 1
    fi

    # Extract project configuration
    PROJECT_ID=$(yq '.project.id' "$DEPS_FILE")
    STATE_BUCKET=$(yq '.state.bucket' "$DEPS_FILE")
    STATE_PREFIX=$(yq '.state.prefix' "$DEPS_FILE")
    STATE_REGION=$(yq '.state.region' "$DEPS_FILE")

    log_info "Project: $PROJECT_ID"
    log_info "State Bucket: $STATE_BUCKET"
}

# Get stack dependencies
get_stack_deps() {
    local stack=$1
    yq ".stacks.\"$stack\".dependencies[]" "$DEPS_FILE" 2>/dev/null || echo ""
}

# Get stack path
get_stack_path() {
    local stack=$1
    yq ".stacks.\"$stack\".path" "$DEPS_FILE"
}

# Get stack state prefix
get_stack_state_prefix() {
    local stack=$1
    yq ".stacks.\"$stack\".state_prefix" "$DEPS_FILE"
}

# Get all stacks in order
get_execution_order() {
    yq '.execution_order[].stacks[]' "$DEPS_FILE"
}

# Get destroy order
get_destroy_order() {
    yq '.destroy_order[]' "$DEPS_FILE"
}

# Check if stack dependencies are met
check_stack_deps() {
    local stack=$1
    local deps
    deps=$(get_stack_deps "$stack")

    if [[ -z "$deps" ]]; then
        return 0
    fi

    for dep in $deps; do
        local dep_state_prefix
        dep_state_prefix=$(get_stack_state_prefix "$dep")
        local state_path="gs://${STATE_BUCKET}/stacks/${ENVIRONMENT}/${dep_state_prefix}/default.tfstate"

        # Check if dependency state exists
        if ! gsutil -q stat "$state_path" 2>/dev/null; then
            log_error "Dependency not met: $dep (state not found)"
            return 1
        fi
    done

    return 0
}

# Initialize a stack
init_stack() {
    local stack=$1
    local stack_path
    stack_path=$(get_stack_path "$stack")
    local state_prefix
    state_prefix=$(get_stack_state_prefix "$stack")

    log_step "Initializing stack: $stack"

    cd "${ROOT_DIR}/${stack_path}"

    terraform init \
        -backend-config="bucket=${STATE_BUCKET}" \
        -backend-config="prefix=stacks/${ENVIRONMENT}/${state_prefix}" \
        -reconfigure

    cd "$ROOT_DIR"
}

# Plan a stack
plan_stack() {
    local stack=$1
    local stack_path
    stack_path=$(get_stack_path "$stack")

    log_step "Planning stack: $stack"

    # Check dependencies first
    if ! check_stack_deps "$stack"; then
        log_error "Cannot plan $stack - dependencies not met"
        return 1
    fi

    cd "${ROOT_DIR}/${stack_path}"

    terraform plan \
        -var-file="${ROOT_DIR}/environments/${ENVIRONMENT}/terraform.tfvars" \
        -var="project_id=${PROJECT_ID}" \
        -var="environment=${ENVIRONMENT}" \
        -out="${stack}.tfplan"

    cd "$ROOT_DIR"
    log_success "Plan completed for: $stack"
}

# Apply a stack
apply_stack() {
    local stack=$1
    local stack_path
    stack_path=$(get_stack_path "$stack")

    log_step "Applying stack: $stack"

    # Check dependencies first
    if ! check_stack_deps "$stack"; then
        log_error "Cannot apply $stack - dependencies not met"
        return 1
    fi

    cd "${ROOT_DIR}/${stack_path}"

    local approve_flag=""
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        approve_flag="-auto-approve"
    fi

    if [[ -f "${stack}.tfplan" ]]; then
        terraform apply $approve_flag "${stack}.tfplan"
    else
        terraform apply \
            -var-file="${ROOT_DIR}/environments/${ENVIRONMENT}/terraform.tfvars" \
            -var="project_id=${PROJECT_ID}" \
            -var="environment=${ENVIRONMENT}" \
            $approve_flag
    fi

    cd "$ROOT_DIR"
    log_success "Apply completed for: $stack"
}

# Destroy a stack
destroy_stack() {
    local stack=$1
    local stack_path
    stack_path=$(get_stack_path "$stack")

    log_step "Destroying stack: $stack"

    cd "${ROOT_DIR}/${stack_path}"

    local approve_flag=""
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        approve_flag="-auto-approve"
    fi

    terraform destroy \
        -var-file="${ROOT_DIR}/environments/${ENVIRONMENT}/terraform.tfvars" \
        -var="project_id=${PROJECT_ID}" \
        -var="environment=${ENVIRONMENT}" \
        $approve_flag

    cd "$ROOT_DIR"
    log_success "Destroy completed for: $stack"
}

# Output stack outputs
output_stack() {
    local stack=$1
    local stack_path
    stack_path=$(get_stack_path "$stack")

    log_step "Getting outputs for stack: $stack"

    cd "${ROOT_DIR}/${stack_path}"
    terraform output -json
    cd "$ROOT_DIR"
}

# Validate all stacks
validate_stacks() {
    log_info "Validating all stacks..."

    local stacks
    stacks=$(get_execution_order)

    for stack in $stacks; do
        local stack_path
        stack_path=$(get_stack_path "$stack")

        log_step "Validating: $stack"
        cd "${ROOT_DIR}/${stack_path}"
        terraform validate
        cd "$ROOT_DIR"
    done

    log_success "All stacks validated successfully"
}

# Show dependency graph
show_deps() {
    log_info "Stack Dependencies:"
    echo ""

    local stacks
    stacks=$(get_execution_order)

    for stack in $stacks; do
        local deps
        deps=$(get_stack_deps "$stack")

        if [[ -z "$deps" ]]; then
            echo "  $stack: (no dependencies)"
        else
            echo "  $stack:"
            for dep in $deps; do
                echo "    -> $dep"
            done
        fi
    done

    echo ""
    log_info "Execution Phases:"
    yq '.execution_order[] | "  Phase " + (.phase | tostring) + " (parallel: " + (.parallel | tostring) + "): " + (.stacks | join(", "))' "$DEPS_FILE"
}

# Execute action on all stacks or specific stack
execute() {
    local action=$1
    local target=$2

    parse_config

    if [[ "$target" == "all" ]]; then
        local stacks
        if [[ "$action" == "destroy" ]]; then
            stacks=$(get_destroy_order)
        else
            stacks=$(get_execution_order)
        fi

        for stack in $stacks; do
            case $action in
                init)
                    init_stack "$stack"
                    ;;
                plan)
                    init_stack "$stack"
                    plan_stack "$stack"
                    ;;
                apply)
                    init_stack "$stack"
                    apply_stack "$stack"
                    ;;
                destroy)
                    init_stack "$stack"
                    destroy_stack "$stack"
                    ;;
                output)
                    output_stack "$stack"
                    ;;
            esac
        done
    else
        # Single stack operation
        case $action in
            init)
                init_stack "$target"
                ;;
            plan)
                init_stack "$target"
                plan_stack "$target"
                ;;
            apply)
                init_stack "$target"
                apply_stack "$target"
                ;;
            destroy)
                init_stack "$target"
                destroy_stack "$target"
                ;;
            output)
                output_stack "$target"
                ;;
        esac
    fi
}

# Print usage
usage() {
    cat << EOF
Terraform Stack Orchestrator

Usage: $0 <action> [stack] [options]

Actions:
  init      Initialize Terraform for stacks
  plan      Generate execution plans
  apply     Apply infrastructure changes
  destroy   Destroy infrastructure
  validate  Validate Terraform configurations
  deps      Show dependency graph
  output    Show stack outputs

Arguments:
  stack     Stack name (e.g., 01-foundation, 02-network) or 'all'

Environment Variables:
  ENVIRONMENT     Target environment (default: prod)
  AUTO_APPROVE    Skip approval prompts (default: false)
  PARALLELISM     Terraform parallelism (default: 10)
  DRY_RUN         Show what would be done (default: false)

Examples:
  $0 plan all                    # Plan all stacks
  $0 apply 01-foundation         # Apply foundation stack
  $0 destroy all                 # Destroy all stacks (in reverse order)
  ENVIRONMENT=staging $0 plan    # Plan for staging environment
  AUTO_APPROVE=true $0 apply all # Apply all without prompts

Stacks (in execution order):
  01-foundation          GCP APIs enablement
  02-network             VPC, Subnets, Firewall
  03-storage             Buckets, Secret Manager, KMS
  04-gke                 GKE Cluster and Node Pools
  05-k8s-bootstrap       Kong, Cert-Manager, ArgoCD
  06-workload-identity   Service Accounts, WI Bindings
  07-app-secrets         Application Secrets
  08-communication-services  Email, SMS, Push
  09-github-arc          GitHub Actions Runners

EOF
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "  Terraform Stack Orchestrator v1.0"
    echo "=========================================="
    echo ""

    check_dependencies

    case "${ACTION}" in
        init|plan|apply|destroy|output)
            execute "$ACTION" "$TARGET_STACK"
            ;;
        validate)
            validate_stacks
            ;;
        deps)
            show_deps
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage
            exit 1
            ;;
    esac

    echo ""
    log_success "Orchestrator completed"
}

main "$@"

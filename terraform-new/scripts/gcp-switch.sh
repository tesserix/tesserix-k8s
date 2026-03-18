#!/bin/bash
# =============================================================================
# GCP Account Switcher
# =============================================================================
# Switch between devtest and prod GCP configurations easily.
#
# Usage:
#   source ./scripts/gcp-switch.sh          # Show current config
#   source ./scripts/gcp-switch.sh devtest  # Switch to devtest
#   source ./scripts/gcp-switch.sh prod     # Switch to prod
#   source ./scripts/gcp-switch.sh login    # Login to current config
#   source ./scripts/gcp-switch.sh status   # Show detailed status
#
# Add to ~/.bashrc or ~/.zshrc for easy access:
#   alias gcp-devtest='gcloud config configurations activate devtest'
#   alias gcp-prod='gcloud config configurations activate prod'
#   alias gcp-status='gcloud config configurations list'
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
DEVTEST_PROJECT="tesseracthub-480811"
DEVTEST_REGION="australia-southeast1"
DEVTEST_ACCOUNT="unidevidp@gmail.com"

PROD_PROJECT="tesseracthub-480811"
PROD_REGION="asia-south1"
PROD_ACCOUNT="samyak.rout@gmail.com"

show_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    GCP Configuration Status                ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Get current configuration
    CURRENT_CONFIG=$(gcloud config configurations list --filter="is_active=true" --format="value(name)" 2>/dev/null)
    CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
    CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
    CURRENT_REGION=$(gcloud config get-value compute/region 2>/dev/null)

    echo -e "  ${GREEN}Active Configuration:${NC} ${CURRENT_CONFIG}"
    echo -e "  ${GREEN}Account:${NC}              ${CURRENT_ACCOUNT:-'(not set)'}"
    echo -e "  ${GREEN}Project:${NC}              ${CURRENT_PROJECT:-'(not set)'}"
    echo -e "  ${GREEN}Region:${NC}               ${CURRENT_REGION:-'(not set)'}"
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BLUE}All Configurations:${NC}"
    echo ""
    gcloud config configurations list 2>/dev/null
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

switch_to_devtest() {
    echo -e "${BLUE}Switching to DevTest...${NC}"
    gcloud config configurations activate devtest 2>/dev/null

    # Verify account is set
    ACCOUNT=$(gcloud config get-value account 2>/dev/null)
    if [ -z "$ACCOUNT" ]; then
        echo -e "${YELLOW}Account not set. Setting account...${NC}"
        gcloud config set account "$DEVTEST_ACCOUNT"
    fi

    echo ""
    echo -e "${GREEN}✓ Switched to DevTest${NC}"
    echo -e "  Project: ${DEVTEST_PROJECT}"
    echo -e "  Region:  ${DEVTEST_REGION}"
    echo -e "  Account: $(gcloud config get-value account 2>/dev/null)"
    echo ""
}

switch_to_prod() {
    echo -e "${BLUE}Switching to Production...${NC}"
    gcloud config configurations activate prod 2>/dev/null

    # Check if authenticated
    ACCOUNT=$(gcloud config get-value account 2>/dev/null)
    if [ -z "$ACCOUNT" ]; then
        echo ""
        echo -e "${YELLOW}⚠ Production account not authenticated yet.${NC}"
        echo ""
        echo -e "Please run one of the following:"
        echo ""
        echo -e "  ${CYAN}# If you have access via ${PROD_ACCOUNT}:${NC}"
        echo -e "  gcloud auth login ${PROD_ACCOUNT}"
        echo ""
        echo -e "  ${CYAN}# Or use any account with access to tesseracthub-480811 project:${NC}"
        echo -e "  gcloud auth login"
        echo ""
        echo -e "  ${CYAN}# Then set the account:${NC}"
        echo -e "  gcloud config set account YOUR_EMAIL"
        echo ""
        return 1
    fi

    echo ""
    echo -e "${GREEN}✓ Switched to Production${NC}"
    echo -e "  Project: ${PROD_PROJECT}"
    echo -e "  Region:  ${PROD_REGION}"
    echo -e "  Account: ${ACCOUNT}"
    echo ""
}

do_login() {
    CURRENT_CONFIG=$(gcloud config configurations list --filter="is_active=true" --format="value(name)" 2>/dev/null)

    echo -e "${BLUE}Logging in for configuration: ${CURRENT_CONFIG}${NC}"
    echo ""

    if [ "$CURRENT_CONFIG" = "prod" ]; then
        echo -e "Recommended account: ${CYAN}${PROD_ACCOUNT}${NC}"
    else
        echo -e "Recommended account: ${CYAN}${DEVTEST_ACCOUNT}${NC}"
    fi
    echo ""

    gcloud auth login

    # Also set application default credentials
    echo ""
    echo -e "${BLUE}Setting application default credentials...${NC}"
    gcloud auth application-default login
}

show_help() {
    echo ""
    echo -e "${CYAN}GCP Account Switcher${NC}"
    echo ""
    echo "Usage: source ./scripts/gcp-switch.sh [command]"
    echo ""
    echo "Commands:"
    echo "  devtest    Switch to devtest configuration (tesseracthub-480811)"
    echo "  prod       Switch to prod configuration (tesseracthub-480811)"
    echo "  status     Show detailed configuration status"
    echo "  login      Login to current configuration"
    echo "  help       Show this help message"
    echo ""
    echo "Quick aliases (add to ~/.bashrc or ~/.zshrc):"
    echo ""
    echo "  alias gcp-devtest='gcloud config configurations activate devtest'"
    echo "  alias gcp-prod='gcloud config configurations activate prod'"
    echo "  alias gcp-status='gcloud config configurations list'"
    echo "  alias gcp-login='gcloud auth login && gcloud auth application-default login'"
    echo ""
}

# Main
case "${1:-status}" in
    devtest|dev|d)
        switch_to_devtest
        ;;
    prod|production|p)
        switch_to_prod
        ;;
    login|l)
        do_login
        ;;
    status|s|"")
        show_status
        ;;
    help|h|-h|--help)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        ;;
esac

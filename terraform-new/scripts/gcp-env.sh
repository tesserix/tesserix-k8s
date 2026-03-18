#!/bin/bash
# =============================================================================
# GCP Environment Switcher (gcloud CLI + ADC)
# =============================================================================
# Switches both gcloud configuration AND Application Default Credentials
#
# Usage:
#   source ./scripts/gcp-env.sh devtest   # Switch to devtest
#   source ./scripts/gcp-env.sh prod      # Switch to prod
#   source ./scripts/gcp-env.sh status    # Show current status
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              GCP Environment Status                        ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # gcloud CLI config
    ACTIVE_CONFIG=$(gcloud config configurations list --filter="is_active=true" --format="value(name)" 2>/dev/null)
    CLI_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
    CLI_PROJECT=$(gcloud config get-value project 2>/dev/null)

    echo -e "${GREEN}gcloud CLI:${NC}"
    echo -e "  Configuration: ${ACTIVE_CONFIG}"
    echo -e "  Account:       ${CLI_ACCOUNT}"
    echo -e "  Project:       ${CLI_PROJECT}"
    echo ""

    # ADC status
    ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"
    if [ -f "$ADC_FILE" ]; then
        ADC_QUOTA=$(grep -o '"quota_project_id": "[^"]*"' "$ADC_FILE" 2>/dev/null | cut -d'"' -f4)
        echo -e "${GREEN}Application Default Credentials (ADC):${NC}"
        echo -e "  Quota Project: ${ADC_QUOTA:-'not set'}"
        echo -e "  File:          ${ADC_FILE}"
    else
        echo -e "${YELLOW}ADC: Not configured${NC}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

    # Check if they match
    if [ "$CLI_PROJECT" != "$ADC_QUOTA" ] && [ -n "$ADC_QUOTA" ]; then
        echo ""
        echo -e "${YELLOW}⚠ Warning: CLI project ($CLI_PROJECT) differs from ADC quota project ($ADC_QUOTA)${NC}"
        echo -e "${YELLOW}  Terraform will use ADC credentials. Run this script to sync them.${NC}"
    fi
    echo ""
}

switch_to_devtest() {
    echo -e "${BLUE}Switching to DevTest environment...${NC}"
    echo ""

    # Switch gcloud configuration
    gcloud config configurations activate devtest 2>/dev/null

    # Update ADC quota project
    echo "Updating ADC quota project..."
    gcloud auth application-default set-quota-project tesseracthub-480811 2>/dev/null || true

    echo ""
    echo -e "${GREEN}✓ Switched to DevTest${NC}"
    echo -e "  Project:  tesseracthub-480811"
    echo -e "  Region:   australia-southeast1"
    echo -e "  Account:  $(gcloud config get-value account 2>/dev/null)"
    echo ""
    echo -e "${CYAN}Terraform will now use DevTest credentials.${NC}"
    echo ""
}

switch_to_prod() {
    echo -e "${BLUE}Switching to Production environment...${NC}"
    echo ""

    # Switch gcloud configuration
    gcloud config configurations activate prod 2>/dev/null

    # Update ADC quota project
    echo "Updating ADC quota project..."
    gcloud auth application-default set-quota-project tesseracthub-480811 2>/dev/null || true

    echo ""
    echo -e "${GREEN}✓ Switched to Production${NC}"
    echo -e "  Project:  tesseracthub-480811"
    echo -e "  Region:   asia-south1"
    echo -e "  Account:  $(gcloud config get-value account 2>/dev/null)"
    echo ""
    echo -e "${CYAN}Terraform will now use Production credentials.${NC}"
    echo ""
}

refresh_adc() {
    local env=$1
    echo -e "${BLUE}Refreshing Application Default Credentials...${NC}"
    echo ""
    echo "This will open a browser for authentication."
    echo ""

    gcloud auth application-default login

    if [ "$env" = "prod" ]; then
        gcloud auth application-default set-quota-project tesseracthub-480811
    else
        gcloud auth application-default set-quota-project tesseracthub-480811
    fi

    echo ""
    echo -e "${GREEN}✓ ADC refreshed${NC}"
}

show_help() {
    echo ""
    echo -e "${CYAN}GCP Environment Switcher${NC}"
    echo ""
    echo "Usage: source ./scripts/gcp-env.sh [command]"
    echo ""
    echo "Commands:"
    echo "  devtest     Switch to DevTest (tesseracthub-480811)"
    echo "  prod        Switch to Production (tesseracthub-480811)"
    echo "  status      Show current environment status"
    echo "  refresh     Refresh ADC credentials (opens browser)"
    echo "  help        Show this help"
    echo ""
    echo "Examples:"
    echo "  source ./scripts/gcp-env.sh devtest   # Switch to devtest"
    echo "  source ./scripts/gcp-env.sh prod      # Switch to prod"
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
    status|s|"")
        show_status
        ;;
    refresh|r)
        CURRENT=$(gcloud config configurations list --filter="is_active=true" --format="value(name)" 2>/dev/null)
        refresh_adc "$CURRENT"
        ;;
    help|h|-h|--help)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        ;;
esac

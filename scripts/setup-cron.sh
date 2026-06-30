#!/bin/bash
# setup-cron.sh — One-click cron job configuration for recurring workflows
# Usage: setup-cron.sh <workflow-name> <cron-schedule> [claude-args...]
#        setup-cron.sh --list
#        setup-cron.sh --remove <workflow-name>
#        setup-cron.sh --dry-run <workflow-name> <cron-schedule> [claude-args...]
#
# Examples:
#   bash scripts/setup-cron.sh recurring-briefing "0 9 * * 1-5"
#   bash scripts/setup-cron.sh recurring-briefing "0 9 * * 1-5" --param topic=AI-news
#   bash scripts/setup-cron.sh --dry-run my-workflow "30 8 * * *" --param env=prod
#   bash scripts/setup-cron.sh --list
#   bash scripts/setup-cron.sh --remove my-workflow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
DRY_RUN=false
MODE="add"  # add | list | remove

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Help ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  $(basename "$0") <workflow-name> <cron-schedule> [claude-args...]
  $(basename "$0") --list
  $(basename "$0") --remove <workflow-name>
  $(basename "$0") --dry-run <workflow-name> <cron-schedule> [claude-args...]

Arguments:
  workflow-name   Name of the workflow to schedule
  cron-schedule   Cron expression (e.g. "0 9 * * 1-5" for weekdays at 9am)
  claude-args     Additional arguments passed to "claude -p" (e.g. --param topic=AI-news)

Options:
  --list          List all currently configured cron workflows
  --remove NAME   Remove a cron workflow by name
  --dry-run       Print what would be done without modifying crontab
  -h, --help      Show this help message
EOF
    exit 0
}

# ── Parse args ──────────────────────────────────────────────────────
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --dry-run) DRY_RUN=true; shift ;;
        --list)    MODE="list"; shift ;;
        --remove)  MODE="remove"; shift; WORKFLOW_NAME="${1:-}"; shift || true ;;
        *)         POSITIONAL+=("$1"); shift ;;
    esac
done

# ── List mode ───────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
    header "Configured Cron Workflows"
    # Fetch current crontab, find lines with our marker
    CRONTAB=$(crontab -l 2>/dev/null || true)
    if [[ -z "$CRONTAB" ]]; then
        info "No crontab configured."
        exit 0
    fi
    MATCHED=0
    while IFS= read -r line; do
        # Look for lines containing our comment marker
        if echo "$line" | grep -q '# claude-workflow:'; then
            SCHED=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
            NAME=$(echo "$line" | sed -n 's/.*# claude-workflow: \([^ ]*\).*/\1/p')
            CMD=$(echo "$line" | sed 's/.*# claude-workflow: [^ ]* //' 2>/dev/null || echo "$line")
            echo -e "  ${GREEN}$NAME${NC}"
            echo "    Schedule: $SCHED"
            echo "    Command:  $CMD"
            MATCHED=1
        fi
    done <<< "$CRONTAB"
    if [[ "$MATCHED" -eq 0 ]]; then
        info "No Claude workflow cron jobs found."
    fi
    exit 0
fi

# ── Remove mode ─────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
    if [[ -z "$WORKFLOW_NAME" ]]; then
        error "Usage: $(basename "$0") --remove <workflow-name>"
        exit 1
    fi
    header "Removing Cron Workflow: $WORKFLOW_NAME"
    CRONTAB=$(crontab -l 2>/dev/null || true)
    if [[ -z "$CRONTAB" ]]; then
        error "No crontab found."
        exit 1
    fi
    NEW_CRONTAB=$(echo "$CRONTAB" | grep -v "# claude-workflow: $WORKFLOW_NAME " || true)
    if [[ "$NEW_CRONTAB" == "$CRONTAB" ]]; then
        error "Workflow '$WORKFLOW_NAME' not found in crontab."
        exit 1
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        info "Would remove cron entry for '$WORKFLOW_NAME':"
        echo "$CRONTAB" | grep "# claude-workflow: $WORKFLOW_NAME "
    else
        echo "$NEW_CRONTAB" | crontab -
        info "Removed cron job for '$WORKFLOW_NAME'."
    fi
    exit 0
fi

# ── Add mode arg validation ────────────────────────────────────────
WORKFLOW_NAME="${POSITIONAL[0]:-}"
CRON_SCHED="${POSITIONAL[1]:-}"
CLAUDE_ARGS=("${POSITIONAL[@]:2}")

if [[ -z "$WORKFLOW_NAME" || -z "$CRON_SCHED" ]]; then
    error "Missing required arguments: <workflow-name> and <cron-schedule>"
    echo ""
    usage
fi

# Validate cron expression (simple check: 5 or 6 fields)
FIELD_COUNT=$(echo "$CRON_SCHED" | awk '{print NF}')
if [[ "$FIELD_COUNT" -lt 5 || "$FIELD_COUNT" -gt 6 ]]; then
    error "Invalid cron expression: '$CRON_SCHED' (expected 5-6 fields)"
    exit 1
fi

# Build the full command
CLAUDE_ARGS_STR=""
if [[ ${#CLAUDE_ARGS[@]} -gt 0 ]]; then
    CLAUDE_ARGS_STR=" "
    for arg in "${CLAUDE_ARGS[@]}"; do
        CLAUDE_ARGS_STR+="$arg "
    done
    CLAUDE_ARGS_STR="${CLAUDE_ARGS_STR%" "}"
fi

FULL_CMD="cd ${PROJECT_DIR} && ${CLAUDE_CMD} -p \"/workflow run ${WORKFLOW_NAME}${CLAUDE_ARGS_STR}\""
CRON_LINE="# claude-workflow: ${WORKFLOW_NAME} ${CLAUDE_ARGS_STR}"
CRON_LINE+=$'\n'"${CRON_SCHED} ${FULL_CMD}"

# ── Dry-run ─────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    header "Dry-Run: Would add cron entry"
    echo "  Workflow:   $WORKFLOW_NAME"
    echo "  Schedule:   $CRON_SCHED"
    echo "  Command:    $FULL_CMD"
    echo ""
    echo "  Crontab entry to be added:"
    echo "    # claude-workflow: ${WORKFLOW_NAME}${CLAUDE_ARGS_STR}"
    echo "    ${CRON_SCHED} ${FULL_CMD}"
    exit 0
fi

# ── Install ─────────────────────────────────────────────────────────
CRONTAB=$(crontab -l 2>/dev/null || true)

# Remove existing entry for this workflow
CRONTAB=$(echo "$CRONTAB" | grep -v "# claude-workflow: ${WORKFLOW_NAME} " || true)

# Append new entry
CRONTAB="${CRONTAB}
# claude-workflow: ${WORKFLOW_NAME}${CLAUDE_ARGS_STR}
${CRON_SCHED} ${FULL_CMD}"

echo "$CRONTAB" | crontab -

info "Cron job configured:"
echo "  Workflow:   $WORKFLOW_NAME"
echo "  Schedule:   $CRON_SCHED"
echo "  Command:    $FULL_CMD"
echo ""
info "View all: bash scripts/setup-cron.sh --list"

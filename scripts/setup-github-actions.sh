#!/bin/bash
# setup-github-actions.sh — Generate GitHub Actions workflow YAML for Claude workflows
# Usage: setup-github-actions.sh <workflow-name> <trigger-type> [options]
#
# Trigger types:
#   schedule             Run on a cron schedule
#   push                 Run on push to specified branch(es)
#   pr                   Run on pull request open/sync
#
# Options:
#   --branch BRANCH          Branch filter (default: main, used with push/pr triggers)
#   --paths "path1 path2"    Path filters (space-separated, used with push/pr triggers)
#   --param NAME=VALUE       Default parameter passed via GitHub vars (repeatable)
#   --secret NAME            Secret name to use instead of CLAUDE_API_KEY (default: CLAUDE_API_KEY)
#   --output DIR             Output directory (default: .github/workflows/)
#   -h, --help               Show this help message
#
# Examples:
#   bash scripts/setup-github-actions.sh daily-report schedule "0 8 * * *"
#   bash scripts/setup-github-actions.sh deploy push --branch main --paths "src/ deploy/"
#   bash scripts/setup-github-actions.sh review pr --param reviewer=senior
#   bash scripts/setup-github-actions.sh briefing schedule "0 9 * * 1-5" --param topic=tech-news

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ── Defaults ────────────────────────────────────────────────────────
OUTPUT_DIR=".github/workflows"
SECRET_NAME="CLAUDE_API_KEY"
BRANCH="main"
PARAMS=()
PATHS=()

# ── Help ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  $(basename "$0") <workflow-name> schedule "<cron-expr>" [options]
  $(basename "$0") <workflow-name> push [options]
  $(basename "$0") <workflow-name> pr [options]

Arguments:
  workflow-name    Name of the workflow to schedule
  trigger-type     One of: schedule, push, pr

Options:
  --branch BRANCH       Branch filter (default: main)
  --paths "p1 p2"       Path filters (space-separated, for push/pr triggers)
  --param NAME=VALUE    Default parameter passed via GitHub vars (repeatable)
  --secret NAME         Secret name (default: CLAUDE_API_KEY)
  --output DIR          Output directory (default: .github/workflows/)
  -h, --help            Show this help message
EOF
    exit 0
}

# ── Parse args ──────────────────────────────────────────────────────
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --branch)   BRANCH="$2"; shift 2 ;;
        --paths)    IFS=' ' read -ra PATHS <<< "$2"; shift 2 ;;
        --param)    PARAMS+=("$2"); shift 2 ;;
        --secret)   SECRET_NAME="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        *)          POSITIONAL+=("$1"); shift ;;
    esac
done

WORKFLOW_NAME="${POSITIONAL[0]:-}"
TRIGGER_TYPE="${POSITIONAL[1]:-}"
CRON_EXPR="${POSITIONAL[2]:-}"

if [[ -z "$WORKFLOW_NAME" || -z "$TRIGGER_TYPE" ]]; then
    error "Missing required arguments: <workflow-name> and <trigger-type>"
    echo ""
    usage
fi

case "$TRIGGER_TYPE" in
    schedule|push|pr) ;;
    *)
        error "Invalid trigger type: '$TRIGGER_TYPE' (must be: schedule, push, pr)"
        exit 1
        ;;
esac

if [[ "$TRIGGER_TYPE" == "schedule" && -z "$CRON_EXPR" ]]; then
    error "schedule trigger requires a cron expression as the 3rd argument"
    exit 1
fi

# ── Build workflow YAML ─────────────────────────────────────────────
# Convert workflow name to a safe filename
SAFE_NAME=$(echo "$WORKFLOW_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
OUTPUT_FILE="${OUTPUT_DIR}/claude-${SAFE_NAME}.yml"

# Build the `on:` trigger section
ON_SECTION=""
case "$TRIGGER_TYPE" in
    schedule)
        ON_SECTION="on:
  schedule:
    - cron: '${CRON_EXPR}'
  workflow_dispatch:" ;;
    push)
        ON_SECTION="on:
  push:
    branches:
      - '${BRANCH}'"
        if [[ ${#PATHS[@]} -gt 0 ]]; then
            ON_SECTION+="
    paths:"
            for p in "${PATHS[@]}"; do
                ON_SECTION+="
      - '${p}'"
            done
        fi
        ;;
    pr)
        ON_SECTION="on:
  pull_request:
    branches:
      - '${BRANCH}'"
        if [[ ${#PATHS[@]} -gt 0 ]]; then
            ON_SECTION+="
    paths:"
            for p in "${PATHS[@]}"; do
                ON_SECTION+="
      - '${p}'"
            done
        fi
        ;;
esac

# Build the `run:` command with params
PARAM_PARTS=()
for p in "${PARAMS[@]}"; do
    KEY="${p%%=*}"
    PARAM_PARTS+=("--param ${KEY}=\${{ vars.${KEY} }}")
done
PARAM_CMD=""
if [[ ${#PARAM_PARTS[@]} -gt 0 ]]; then
    PARAM_CMD=" "
    PARAM_CMD+=$(IFS=' '; echo "${PARAM_PARTS[*]}")
fi

RUN_CMD="npx claude -p \"/workflow run ${WORKFLOW_NAME}${PARAM_CMD}\""

# Build env vars section
ENV_SECTION=""
if [[ ${#PARAMS[@]} -gt 0 ]]; then
    ENV_SECTION="
        env:
          CLAUDE_API_KEY: \${{ secrets.${SECRET_NAME} }}"
fi

# Assemble full YAML
YAML_CONTENT="# This file is auto-generated by scripts/setup-github-actions.sh
# Do not edit manually — use the script to update.
name: Claude - ${WORKFLOW_NAME}
${ON_SECTION}

jobs:
  run-workflow:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Claude Workflow
        run: |
          ${RUN_CMD}${ENV_SECTION}
"

# ── Write file ──────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
echo "$YAML_CONTENT" > "$OUTPUT_FILE"

info "Generated GitHub Actions workflow: ${OUTPUT_FILE}"
echo ""
echo "  Name:         Claude - ${WORKFLOW_NAME}"
echo "  Trigger:      ${TRIGGER_TYPE}"
if [[ "$TRIGGER_TYPE" == "schedule" ]]; then
    echo "  Schedule:     ${CRON_EXPR}"
fi
echo "  Output:       ${OUTPUT_FILE}"
echo ""
info "Next steps:"
echo "  1. Commit and push:"
echo "     git add ${OUTPUT_FILE}"
echo "     git commit -m \"Add GitHub Actions workflow for ${WORKFLOW_NAME}\""
echo "     git push"
if [[ "$SECRET_NAME" == "CLAUDE_API_KEY" ]]; then
    echo "  2. Add CLAUDE_API_KEY to GitHub repository secrets:"
    echo "     https://github.com/$(git config --get remote.origin.url 2>/dev/null | sed 's/.*github.com[:\/]\(.*\)\.git/\1/' || echo '<owner>/<repo>')/settings/secrets/actions"
fi
echo ""

if [[ ${#PARAMS[@]} -gt 0 ]]; then
    info "Parameters are configured via GitHub Actions Variables (vars):"
    for p in "${PARAMS[@]}"; do
        KEY="${p%%=*}"
        echo "  - \${ vars.${KEY} } — add this as a repository variable in GitHub UI"
    done
    echo ""
fi

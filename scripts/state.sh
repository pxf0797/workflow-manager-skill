#!/bin/bash
# Workflow state management script
# Usage: state.sh <command> <workflow-name> [args...]
#
# Commands:
#   init    <name> <yaml-path> [params_json]  — Initialize new workflow state
#   read    <name>                            — Read current state as JSON to stdout
#   update  <name> <phase-id> <field> <value> — Update a phase field
#   status  <name> <phase-id> <status>        — Set phase status
#   list                                       — List all active workflows
#   archive <name>                             — Archive completed/failed workflow
#   check-resumable                            — Detect in-progress workflows and classify as resumable/stale

set -euo pipefail

STATE_DIR="${HOME}/.claude/workflow-manager/states"
ARCHIVE_DIR="${HOME}/.claude/workflow-manager/states/archive"
mkdir -p "$STATE_DIR" "$ARCHIVE_DIR"

state_file() {
    echo "${STATE_DIR}/${1}.json"
}

cmd_init() {
    local name="$1" yaml_path="$2" params_json="${3}"
    [ -z "$params_json" ] && params_json="{}"
    local state_path
    state_path=$(state_file "$name")

    if [ -f "$state_path" ]; then
        echo "ERROR: Workflow '${name}' already exists. Use 'resume' or delete state first." >&2
        exit 1
    fi

    # Count phases from YAML
    local phase_count
    phase_count=$(python3 -c "
import yaml, json, sys
with open('${yaml_path}') as f:
    wf = yaml.safe_load(f)
print(len(wf.get('phases', [])))
" 2>/dev/null || echo "0")

    if [ "$phase_count" -eq 0 ]; then
        echo "ERROR: No phases found in ${yaml_path}" >&2
        exit 1
    fi

    # Generate workflow ID
    local wf_id="wf-$(date +%Y%m%d-%H%M%S)-$$"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%S+08:00)

    # Build initial state JSON (params_json via temp file to avoid shell escaping issues)
    local params_file
    params_file=$(mktemp)
    printf '%s' "${params_json}" > "$params_file"
    python3 -c "
import yaml, json, sys
with open('${yaml_path}') as f:
    wf = yaml.safe_load(f)
with open('${params_file}') as f:
    params = json.load(f)
state = {
    'workflow_id': '${wf_id}',
    'workflow_name': '${name}',
    'yaml_path': '${yaml_path}',
    'status': 'pending',
    'current_phase': None,
    'params': params,
    'created_at': '${now}',
    'updated_at': '${now}',
    'phases': {}
}
for p in wf.get('phases', []):
    state['phases'][p['id']] = {
        'status': 'pending',
        'orchestrator_id': None,
        'output_file': None,
        'summary': None,
        'started_at': None,
        'completed_at': None,
        'retry_count': 0,
        'error': None
    }
with open('${state_path}', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({'workflow_id': state['workflow_id'], 'phase_count': ${phase_count}}))
"
    rm -f "$params_file"
}

cmd_read() {
    local name="$1"
    local state_path
    state_path=$(state_file "$name")

    if [ ! -f "$state_path" ]; then
        echo '{"error": "Workflow not found"}' >&2
        exit 1
    fi
    cat "$state_path"
}

cmd_update() {
    local name="$1" phase_id="$2" field="$3" value="$4"
    local state_path
    state_path=$(state_file "$name")

    if [ ! -f "$state_path" ]; then
        echo "ERROR: Workflow '${name}' not found" >&2
        exit 1
    fi

    local val_file
    val_file=$(mktemp)
    printf '%s' "${value}" > "$val_file"
    python3 -c "
import json, sys
with open('${state_path}') as f:
    state = json.load(f)
if '${phase_id}' not in state['phases']:
    print(f'ERROR: Phase {phase_id} not found', file=sys.stderr)
    sys.exit(1)
with open('${val_file}') as f:
    raw = f.read().strip()
# Try JSON parse first, fall back to string
try:
    parsed = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    parsed = raw
state['phases']['${phase_id}']['${field}'] = parsed
state['updated_at'] = '$(date -u +%Y-%m-%dT%H:%M:%S+08:00)'
with open('${state_path}', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({'updated': '${phase_id}.${field}'}))
"
    rm -f "$val_file"
}

cmd_status() {
    local name="$1" phase_id="$2" new_status="$3"
    local state_path now
    state_path=$(state_file "$name")
    now=$(date -u +%Y-%m-%dT%H:%M:%S+08:00)

    if [ ! -f "$state_path" ]; then
        echo "ERROR: Workflow '${name}' not found" >&2
        exit 1
    fi

    python3 -c "
import json, sys
with open('${state_path}') as f:
    state = json.load(f)
if '${phase_id}' not in state['phases']:
    print(f'ERROR: Phase {phase_id} not found', file=sys.stderr)
    sys.exit(1)
state['phases']['${phase_id}']['status'] = '${new_status}'
if '${new_status}' == 'in_progress':
    state['phases']['${phase_id}']['started_at'] = '${now}'
    state['current_phase'] = '${phase_id}'
elif '${new_status}' in ('completed', 'failed'):
    state['phases']['${phase_id}']['completed_at'] = '${now}'
state['updated_at'] = '${now}'

# Update workflow-level status
all_statuses = [p['status'] for p in state['phases'].values()]
if all(s == 'completed' for s in all_statuses):
    state['status'] = 'completed'
elif any(s == 'failed' for s in all_statuses):
    state['status'] = 'failed'
elif any(s == 'in_progress' for s in all_statuses):
    state['status'] = 'in_progress'

with open('${state_path}', 'w') as f:
    json.dump(state, f, indent=2, ensure_ascii=False)
print(json.dumps({'phase': '${phase_id}', 'status': '${new_status}'}))
"
}

cmd_list() {
    echo "Active workflows:"
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .json)
        local status
        status=$(python3 -c "import json; print(json.load(open('$f'))['status'])" 2>/dev/null || echo "corrupt")
        echo "  ${name} — ${status}"
    done
}

cmd_check_resumable() {
    local now_epoch
    now_epoch=$(date +%s)
    local stale_threshold_seconds=$((30 * 60))  # 30 minutes

    # Build JSON output via Python for proper encoding
    python3 -c "
import json, os, sys, time

state_dir = os.path.expanduser('${STATE_DIR}')
now = ${now_epoch}
threshold = ${stale_threshold_seconds}

resumable_list = []
stale_list = []

if not os.path.isdir(state_dir):
    print(json.dumps({'resumable': [], 'stale': []}, indent=2, ensure_ascii=False))
    sys.exit(0)

for fname in os.listdir(state_dir):
    if not fname.endswith('.json'):
        continue
    fpath = os.path.join(state_dir, fname)
    try:
        with open(fpath) as f:
            state = json.load(f)
    except (json.JSONDecodeError, IOError):
        continue

    if state.get('status') != 'in_progress':
        continue

    name = fname[:-5]  # strip .json
    updated_at_str = state.get('updated_at', '')
    current_phase = state.get('current_phase') or 'unknown'

    # Count completed vs total phases
    phases = state.get('phases', {})
    total = len(phases)
    completed = sum(1 for p in phases.values() if p.get('status') == 'completed')
    progress = f'{completed}/{total}'

    # Parse updated_at timestamp
    idle_minutes = None
    if updated_at_str:
        try:
            import calendar, re
            # Normalize: strip timezone offset (state.sh uses date -u +08:00
            # which is UTC time with wrong suffix; treat as UTC always)
            clean = re.sub(r'[+-]\d{2}:\d{2}$', '', updated_at_str.replace('Z', ''))
            updated_epoch = calendar.timegm(time.strptime(clean, '%Y-%m-%dT%H:%M:%S'))
            idle_seconds = now - updated_epoch
            idle_minutes = int(idle_seconds / 60)
        except Exception:
            idle_minutes = None

    entry = {
        'name': name,
        'status': 'in_progress',
        'current_phase': current_phase,
        'progress': progress,
        'last_updated': updated_at_str,
        'idle_minutes': idle_minutes or 0,
    }

    if idle_minutes is not None and idle_minutes >= 30:
        entry['suggestion'] = '可能已废弃，建议 archive'
        stale_list.append(entry)
    else:
        resumable_list.append(entry)

output = {'resumable': resumable_list, 'stale': stale_list}
print(json.dumps(output, indent=2, ensure_ascii=False))
"
}

cmd_archive() {
    local name="$1"
    local state_path
    state_path=$(state_file "$name")

    if [ ! -f "$state_path" ]; then
        echo "ERROR: Workflow '${name}' not found" >&2
        exit 1
    fi
    mv "$state_path" "$ARCHIVE_DIR/"
    echo "Archived: ${name}"
}

# Main dispatch
case "${1:-}" in
    init)    shift; cmd_init "$@" ;;
    read)    shift; cmd_read "$@" ;;
    update)  shift; cmd_update "$@" ;;
    status)  shift; cmd_status "$@" ;;
    list)    cmd_list ;;
    archive) shift; cmd_archive "$@" ;;
    check-resumable) cmd_check_resumable ;;
    *)
        echo "Usage: state.sh {init|read|update|status|list|archive|check-resumable} <name> [args...]" >&2
        exit 1
        ;;
esac

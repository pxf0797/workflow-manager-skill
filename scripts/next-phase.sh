#!/bin/bash
# Determine next phase(s) to execute based on workflow YAML + state
# Usage: next-phase.sh <workflow-yaml-path> <workflow-name>
# Output: JSON array of phase IDs ready to execute

set -euo pipefail

YAML_PATH="${1:-}"
WORKFLOW_NAME="${2:-}"
STATE_DIR="${HOME}/.claude/workflow-manager/states"

if [ -z "$YAML_PATH" ] || [ -z "$WORKFLOW_NAME" ]; then
    echo '{"error": "Usage: next-phase.sh <yaml-path> <workflow-name>"}' >&2
    exit 1
fi

STATE_PATH="${STATE_DIR}/${WORKFLOW_NAME}.json"

python3 -c "
import yaml, json, sys, os

# Load workflow definition
try:
    with open('${YAML_PATH}') as f:
        wf = yaml.safe_load(f)
except FileNotFoundError:
    print(json.dumps({'error': 'YAML file not found: ${YAML_PATH}'}))
    sys.exit(1)

phases_def = {p['id']: p for p in wf.get('phases', [])}

# Load state (or return first phases if no state yet)
if os.path.exists('${STATE_PATH}'):
    with open('${STATE_PATH}') as f:
        state = json.load(f)
    phases_state = state.get('phases', {})
else:
    # No state yet — all phases with no dependencies are ready
    ready = [p['id'] for p in wf.get('phases', []) if not p.get('depends_on', [])]
    print(json.dumps({'ready': ready, 'workflow_status': 'new'}))
    sys.exit(0)

ready = []
blocked = []
in_progress = []

for phase_id, phase_def in phases_def.items():
    ps = phases_state.get(phase_id, {})
    status = ps.get('status', 'pending')

    if status in ('completed', 'failed'):
        continue
    if status == 'in_progress':
        in_progress.append(phase_id)
        continue

    # Check dependencies
    deps = phase_def.get('depends_on', [])
    deps_met = all(
        phases_state.get(d, {}).get('status') == 'completed'
        for d in deps
    )
    deps_failed = any(
        phases_state.get(d, {}).get('status') == 'failed'
        for d in deps
    )

    if deps_failed:
        blocked.append({'id': phase_id, 'reason': 'dependency_failed'})
    elif deps_met:
        ready.append(phase_id)
    else:
        blocked.append({'id': phase_id, 'reason': 'waiting_dependencies'})

# Don't exceed 4 concurrent phases
ready = ready[:4]

result = {
    'ready': ready,
    'in_progress': in_progress,
    'blocked': blocked,
    'total_phases': len(phases_def),
    'completed_phases': sum(1 for p in phases_state.values() if p.get('status') == 'completed'),
    'failed_phases': sum(1 for p in phases_state.values() if p.get('status') == 'failed'),
    'workflow_status': state.get('status', 'unknown')
}
print(json.dumps(result, ensure_ascii=False))
"

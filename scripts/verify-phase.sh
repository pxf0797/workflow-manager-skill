#!/bin/bash
# Phase output verification script
# Usage: verify-phase.sh <phase-output-file> <verify-level> [criteria...]
# verify-level: light | standard | strict
# Output: JSON verdict {pass, score, issues[], summary, signal}
#
# Design principle:
#   This script runs in a subprocess and CANNOT directly spawn LLM agents.
#   It performs structural checks inline (light), and for standard/strict levels
#   it emits a "signal" with a complete Verifier prompt for the Workflow Manager
#   (the parent LLM coordinator) to dispatch an agent automatically.
#
# The Workflow Manager is responsible for:
#   1. Running this script after phase completion
#   2. If signal == "needs_agent", spawning Verifier agent(s) with the emitted prompt
#   3. Collecting verdict(s) and making the pass/fail decision

set -euo pipefail

OUTPUT_FILE="${1:-}"
VERIFY_LEVEL="${2:-}"
shift 2 || true

# ---- Input validation ----
[ -z "$OUTPUT_FILE" ] && { echo '{"error": "Missing argument: phase-output-file"}' >&2; exit 1; }
[ -z "$VERIFY_LEVEL" ] && { echo '{"error": "Missing argument: verify-level"}' >&2; exit 1; }

case "$VERIFY_LEVEL" in
    light|standard|strict) ;;
    *) echo '{"error": "Invalid verify-level: must be light, standard, or strict"}' >&2; exit 1 ;;
esac

[ ! -f "$OUTPUT_FILE" ] && { echo "{\"error\": \"Output file not found: ${OUTPUT_FILE}\"}" >&2; exit 1; }
[ ! -s "$OUTPUT_FILE" ] && { echo "{\"error\": \"Output file is empty: ${OUTPUT_FILE}\"}" >&2; exit 1; }

# ---- Build criteria JSON ----
CRITERIA_JSON='[]'
if [ $# -gt 0 ]; then
    CRITERIA_JSON=$(printf '%s\n' "$@" | python3 -c "
import json, sys
items = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(items))
")
fi

# ---- Delegate to Python (all JSON construction) ----
# Pass args through env vars and as Python script arguments for safety
export PY_OUTPUT_FILE="$OUTPUT_FILE"
export PY_VERIFY_LEVEL="$VERIFY_LEVEL"
export PY_CRITERIA_JSON="$CRITERIA_JSON"

python3 << 'PYEOF'
import json, os, subprocess, sys

output_file = os.environ.get('PY_OUTPUT_FILE', '')
verify_level = os.environ.get('PY_VERIFY_LEVEL', '')
criteria = json.loads(os.environ.get('PY_CRITERIA_JSON', '[]'))

# ---- Schema checks ----
issues = []
score = 100

try:
    with open(output_file, 'r', errors='replace') as f:
        content = f.read()
except Exception as e:
    result = {'pass': False, 'score': 0, 'issues': [f'Cannot read file: {e}'], 'summary': 'File read error', 'signal': 'done', 'level': verify_level}
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

# 1. Markdown headers
if not any(line.startswith('#') for line in content.split('\n')):
    issues.append('Output has no markdown headers - may lack structure')

# 2. File size sanity
size = len(content.encode('utf-8'))
if size < 10:
    issues.append(f'Output file is too small ({size} bytes)')

# 3. Binary check
try:
    r = subprocess.run(['file', output_file], capture_output=True, text=True, timeout=5)
    if 'binary' in r.stdout.lower():
        issues.append('Output appears to be binary - expected text')
except Exception:
    pass

# 4. Error keywords
for kw in ['error', 'exception', 'traceback', 'failed']:
    if kw in content.lower():
        issues.append(f'Output contains "{kw}" keyword - may be incomplete')
        break

# Apply deductions
if issues:
    deduction = min(len(issues) * 20, 100)
    score = max(0, 100 - deduction)

# ---- Light: schema only ----
if verify_level == 'light':
    verdict_pass = len(issues) == 0 and score >= 60
    result = {
        'pass': verdict_pass,
        'score': score,
        'issues': issues,
        'summary': f'Schema check {"passed" if verdict_pass else "failed"}: {len(issues)} issue(s) found',
        'signal': 'done',
        'level': 'light'
    }
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

# ---- Standard / Strict: emit agent signal ----

# Output type
ext_map = {
    '.md': 'Markdown document', '.markdown': 'Markdown document',
    '.json': 'JSON data',
    '.yaml': 'YAML configuration', '.yml': 'YAML configuration',
    '.py': 'Source code (Python)', '.js': 'Source code (JavaScript)',
    '.ts': 'Source code (TypeScript)', '.go': 'Source code (Go)',
    '.rs': 'Source code (Rust)', '.java': 'Source code (Java)',
    '.rb': 'Source code (Ruby)', '.sh': 'Source code (Shell)',
    '.bash': 'Source code (Bash)', '.csv': 'Tabular data (CSV)',
    '.tsv': 'Tabular data (TSV)', '.html': 'HTML document',
    '.txt': 'Plain text'
}
_, ext = os.path.splitext(output_file)
output_type = ext_map.get(ext.lower(), f'Document ({ext})')

agent_count = 3 if verify_level == 'strict' else 1

# Truncate content for prompt
max_chars = 204800
truncated_content = content[:max_chars]
if len(content) > max_chars:
    truncated_content += '\n\n...[content truncated]...'

# Build criteria section
criteria_section = ''
if criteria:
    criteria_section = '## Custom Verification Criteria\n'
    for c in criteria:
        criteria_section += f'- {c}\n'

# Escape content for embedding in the prompt
# (Replace backticks that would break the code fence)
escaped_content = truncated_content.replace('```', '`​`​`')

agent_prompt_lines = []
agent_prompt_lines.append('[Role: Verifier]')
agent_prompt_lines.append('[Goal: 严格验证上游 Agent 的输出质量，给出通过/不通过判定及具体修正建议]')
agent_prompt_lines.append('[Backstory: 你是一名资深 QA 专家，擅长发现输出中的逻辑漏洞、格式问题和遗漏项。你的评判标准客观、具体、可操作。]')
agent_prompt_lines.append('[Skills: 结构化验证, Schema 校验, 需求对照, 边界检查, 逻辑一致性检查]')
agent_prompt_lines.append('[Output Format: JSON {"pass": true|false, "score": 0-100, "issues": [...], "summary": "..."}]')
agent_prompt_lines.append('[Constraints: 只评判质量不修改内容; 每个 issue 必须附具体位置和建议; score 必须有明确扣分理由; pass=false 时必须给出可操作的修正建议]')
agent_prompt_lines.append('')
agent_prompt_lines.append('---')
agent_prompt_lines.append('## Verification Task')
agent_prompt_lines.append('')
agent_prompt_lines.append('Verify the following phase output.')
agent_prompt_lines.append('')
agent_prompt_lines.append(f'**Output type:** {output_type}')
agent_prompt_lines.append(f'**File:** {output_file}')
agent_prompt_lines.append(f'**Verification level:** {verify_level}')
agent_prompt_lines.append(f'**Schema pre-check results:** {len(issues)} issue(s) found pre-flight')
agent_prompt_lines.append('')
if criteria_section:
    agent_prompt_lines.append(criteria_section.rstrip('\n'))
agent_prompt_lines.append('## Phase Output Content')
agent_prompt_lines.append('')
agent_prompt_lines.append('```')
agent_prompt_lines.append(escaped_content)
agent_prompt_lines.append('```')
agent_prompt_lines.append('')
agent_prompt_lines.append('## Instructions')
agent_prompt_lines.append('')
agent_prompt_lines.append('1. Read the output content above')
agent_prompt_lines.append('2. Assess quality against the criteria')
agent_prompt_lines.append('3. Produce your verdict as a JSON object with:')
agent_prompt_lines.append('   - pass (boolean): true if quality is acceptable, false otherwise')
agent_prompt_lines.append('   - score (0-100): quality score with justification')
agent_prompt_lines.append('   - issues (array): list of specific issues found, each with location and suggestion')
agent_prompt_lines.append('   - summary (string): one-paragraph verdict summary')
agent_prompt_lines.append('')
agent_prompt_lines.append('Be strict. Do not pass output that merely "looks okay" - verify every claim and check for omissions. If pass=false, provide actionable fix suggestions in each issue.')

agent_prompt = '\n'.join(agent_prompt_lines)

# Extra deduction for pre-check in agent mode
if issues:
    score = max(0, score - 20)

# Build verdict for pre-check + signal
pre_check_passed = len(issues) == 0
if pre_check_passed:
    summary = f'Schema pre-check passed, requiring {agent_count} Verifier agent(s) for {verify_level} verification'
else:
    summary = f'Schema pre-check found {len(issues)} issue(s), requiring {agent_count} Verifier agent(s) for {verify_level} verification'

result = {
    'pass': False,
    'score': score,
    'issues': issues,
    'summary': summary,
    'signal': 'needs_agent',
    'level': verify_level,
    'agent_count': agent_count,
    'agent_prompt': agent_prompt,
    'output_type': output_type,
    'pre_check_issues': issues
}
print(json.dumps(result, ensure_ascii=False))
PYEOF

---
name: workflow-manager
description: >
  Multi-phase workflow manager that chains multiple orchestrator runs.
  Use when user wants to execute multi-stage projects (research, design, implement, verify),
  set up recurring or scheduled task pipelines, define conditional or event-driven agent workflows,
  chain orchestrator runs with data passing between phases, or run continuous improvement loops.
  Triggers on keywords like 分阶段, 工作流, workflow, pipeline, 串行执行, 多个阶段, phase, 多步骤项目, 阶段性任务.
---

# Workflow Manager

Manage multi-phase agent workflows where each phase is an independent orchestrator run, chained with state passing and optional HITL approval gates.

## When to Use

Use when a task is too large for a single `/orchestrate` run and naturally decomposes into sequential phases with clear boundaries. Each phase internally uses the multi-agent-orchestrator for parallelism; Workflow Manager handles the chain across phases.

**Do NOT use for:** Single-phase tasks (use `/orchestrate` directly), simple sequential tasks without per-phase agent parallelism, or tasks without clear phase boundaries.

## Quick Start

### Define

Create a workflow YAML describing phases. Each phase = one orchestrator invocation:

```yaml
name: "project-research-to-implement"
phases:
  - id: research
    description: "技术调研"
    prompt: "深入研究 {{params.topic}} 的技术方案和竞品，出研究报告"

  - id: design
    description: "架构设计"
    prompt: "基于研究报告 {{phase.research.output_file}} 设计系统架构"
    depends_on: [research]
    approval: true  # pause for user review

  - id: implement
    description: "实现核心模块"
    prompt: "根据架构设计实现代码"
    depends_on: [design]
```

### Run

```
/workflow run project-research-to-implement --param topic="多Agent编排"
```

### Resume interrupted

```
/workflow resume
```

## Core Workflow

```
1. Parse YAML → validate phase DAG (no cycles)
2. Load/create state file → determine next ready phase(s)
3. For each ready phase (up to max_parallel=4):
   a. Expand {{placeholders}} with params + upstream phase outputs
   b. Invoke /orchestrate with phase prompt
   c. Wait for completion → capture output_file path + summary
   d. If phase has approval: true → pause, show results, wait for user
   e. Update state → mark phase completed
4. Repeat until all phases complete or failed
5. Deliver final summary with per-phase stats
```

## Commands

- **`/workflow run <name>`** — Start or resume a workflow. Pass `--param key=value` for template variables.
- **`/workflow status <name>`** — Show current phase progress, completed outputs, next phases.
- **`/workflow resume`** — Auto-detect and resume the most recent in-progress workflow.
- **`/workflow list`** — List all workflows and their status.
- **`/workflow archive <name>`** — Archive completed/failed workflow state.

## YAML Format

Full spec: [references/workflow-yaml-spec.md](references/workflow-yaml-spec.md)

### Phase fields (required: id, description, prompt)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique within workflow |
| `description` | string | Shown in progress display |
| `prompt` | string | Orchestrator prompt, supports `{{placeholder}}` |
| `depends_on` | list | Phase IDs that must complete first |
| `approval` | bool | Pause for user review after phase |
| `inputs` | map | `var: "{{phase_id.field}}"` for data passing |
| `timeout_minutes` | int | Default 60 |
| `retry` | int | Default 1 |
| `model` | string | Override: `opus`/`sonnet`/`haiku` |
| `verify` | string | `light`/`standard`/`strict` (default: standard) |

### Template variables

- `{{params.KEY}}` — Workflow invocation parameters
- `{{phase.PHASE_ID.output_file}}` — Previous phase's output file path
- `{{phase.PHASE_ID.summary}}` — Previous phase's summary text
- `{{workflow.name}}` / `{{workflow.id}}` — Current workflow metadata

## State Management

State persists at `~/.claude/workflow-manager/states/<name>.json`. Key operations:

```bash
# Initialize state from YAML
bash scripts/state.sh init <name> <yaml-path> '{"key":"value"}'

# Read current state
bash scripts/state.sh read <name>

# Update phase status
bash scripts/state.sh status <name> <phase-id> completed

# Determine next ready phases
bash scripts/next-phase.sh <yaml-path> <name>
```

## Scenario Templates

Pre-built YAML templates for 5 common scenarios. See [references/scenario-templates.md](references/scenario-templates.md):

| # | Scenario | Key Pattern | HITL Gates |
|---|----------|------------|------------|
| 1 | Multi-phase project | research→design→implement→verify | design, verify |
| 2 | Recurring briefing | collect→analyze→write→review | review |
| 3 | Event-driven pipeline | detect→investigate→fix→verify | fix |
| 4 | Data pipeline chain | extract→transform→validate→load | load |
| 5 | Continuous improvement | measure→analyze→improve→evaluate (loop) | per-iteration |

Use `assets/workflow-template.yaml` as a blank starting point.

## Failure Handling

- **E1 (timeout/error):** Auto-retry up to `retry` count, then pause for user
- **E2 (validation fail):** Re-run phase with validator feedback injected
- **E3 (consecutive failures):** Pause workflow, suggest replan
- **Interrupted workflow:** Resume from last completed phase via state file

## HITL Approval Flow

Phases with `approval: true` pause after completion:
1. Display phase results + output summary
2. Options: `[继续下一阶段] [重试当前阶段] [修改参数重试] [中止]`
3. On continue: advance to next phase
4. On retry: re-run same phase (preserves retry count)
5. On modify: prompt for new params, then re-run
6. On abort: mark workflow failed, archive state

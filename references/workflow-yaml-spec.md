# Workflow YAML Format Specification

## Top-Level Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | yes | string | Unique workflow identifier (kebab-case) |
| `description` | no | string | Human-readable description |
| `version` | no | string | Workflow version (default: "1.0") |
| `params` | no | map | Default parameter values |
| `phases` | yes | list | Ordered list of phase definitions |
| `on_failure` | no | string | Global failure policy: `pause` (default), `skip`, `abort` |
| `max_parallel` | no | int | Max concurrent phases (default: 10) |

## Phase Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `id` | yes | string | Unique phase identifier (kebab-case within workflow) |
| `description` | yes | string | Short description shown in progress display |
| `prompt` | yes | string | Orchestrator prompt with `{{placeholder}}` support |
| `depends_on` | no | list | Phase IDs that must complete before this phase |
| `approval` | no | bool | If true, pause for user review after phase completion |
| `approval_question` | no | string | Custom question for approval gate |
| `inputs` | no | map | `varname: "{{phase_id.output_field}}"` mappings |
| `timeout_minutes` | no | int | Max duration (default: 60) |
| `retry` | no | int | Max retries on failure (default: 1) |
| `model` | no | string | Override model for orchestrator: `opus`/`sonnet`/`haiku` |
| `verify` | no | string | Verification level: `light`/`standard`/`strict` (default: none) |
| `verify_criteria` | no | list | Custom verification dimensions (strings passed to Verifier agent) |
| `output_fields` | no | list | Fields to extract from orchestrator output for downstream phases |

## Template Variables

Placeholders `{{...}}` in `prompt` and `inputs` are expanded at phase start:

### Built-in Variables

| Variable | Description |
|----------|-------------|
| `{{params.<key>}}` | Workflow invocation parameter |
| `{{phase.<phase_id>.output_file}}` | File path of previous phase's output |
| `{{phase.<phase_id>.summary}}` | Summary text from previous phase |
| `{{phase.<phase_id>.orchestrator_id}}` | Orchestrator run ID |
| `{{workflow.name}}` | Current workflow name |
| `{{workflow.id}}` | Current workflow run ID |

### Custom Output Fields

Phases can define `output_fields` to extract specific values for downstream use:

```yaml
phases:
  - id: research
    prompt: "研究 {{params.topic}}"
    output_fields:
      - key_findings
      - tool_count
```

Downstream phases reference: `{{phase.research.key_findings}}`

## Examples

### Minimal 2-Phase Workflow

```yaml
name: "simple-research-to-report"
phases:
  - id: search
    description: "搜索信息"
    prompt: "搜索 {{params.topic}} 的最新信息"
  
  - id: report
    description: "生成报告"
    prompt: "根据搜索结果 {{phase.search.output_file}} 生成报告"
    depends_on: [search]
```

### Full 4-Phase Project with Approval Gates

```yaml
name: "full-project-lifecycle"
description: "完整的项目生命周期：研究→设计→实现→验证"
params:
  topic: ""
  repo_path: "."

phases:
  - id: research
    description: "技术调研"
    prompt: "深入研究 {{params.topic}} 的技术方案、竞品和最佳实践"
    timeout_minutes: 45
    retry: 2
    verify: light
    output_fields:
      - recommendation
      - risk_areas

  - id: design
    description: "架构设计"
    prompt: "根据研究报告 {{phase.research.output_file}} 设计系统架构"
    depends_on: [research]
    approval: true
    approval_question: "架构方案是否满足需求？"
    model: opus
    timeout_minutes: 60

  - id: implement
    description: "实现核心模块"
    prompt: "在 {{params.repo_path}} 中根据架构设计实现代码，重点关注: {{phase.research.risk_areas}}"
    depends_on: [design]
    verify: standard
    retry: 3

  - id: verify
    description: "集成验证"
    prompt: "对实现结果进行集成测试和代码审查"
    depends_on: [implement]
    verify: strict
    approval: true

on_failure: pause
max_parallel: 3
```

### Loop Workflow (Continuous Improvement)

```yaml
name: "continuous-improvement"
description: "持续改进循环"
params:
  target: ""
  max_iterations: 3
  improvement_threshold: 0.8

phases:
  - id: measure
    description: "度量当前状态"
    prompt: "分析 {{params.target}} 的当前质量/性能指标"

  - id: analyze
    description: "分析改进空间"
    prompt: "根据度量结果 {{phase.measure.output_file}} 识别改进机会"
    depends_on: [measure]

  - id: improve
    description: "实施改进"
    prompt: "实施分析中识别的改进项"
    depends_on: [analyze]
    verify: standard

  - id: evaluate
    description: "评估改进效果"
    prompt: "对比改进前后指标，判断是否达到 {{params.improvement_threshold}} 阈值"
    depends_on: [improve]
    approval: true
    approval_question: "改进效果是否满意？[继续下一轮] [结束循环]"

on_failure: pause
```

## Validation Rules

1. **Phase IDs must be unique** within a workflow
2. **No circular dependencies** — `depends_on` must form a DAG
3. **Template variables** referencing non-existent phases or params will cause an error at expansion time
4. **`output_fields`** defined but not extracted are silently ignored (non-blocking)
5. **Approval phases** cannot be inside a loop without user interaction

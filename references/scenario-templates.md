# Scenario Templates

Pre-built workflow templates for the 5 common multi-invocation scenarios identified in research.

## 1. Multi-Phase Project (`phase-project`)

**Use case:** Research → Design → Implement → Verify pipeline. Each phase is a full orchestrator run. Suitable for new feature development, system migration, architecture overhauls.

```yaml
name: "phase-project"
description: "多阶段项目：研究→设计→实现→验证"
params:
  topic: ""
  repo_path: "."
phases:
  - id: research
    description: "技术调研"
    prompt: "深入研究 {{params.topic}} 的现状、竞品方案、技术选型和最佳实践。输出研究报告。"
    timeout_minutes: 45
    verify: light

  - id: design
    description: "架构设计"
    prompt: "根据研究报告 {{phase.research.output_file}} 设计系统架构。明确模块划分、接口契约、数据流。"
    depends_on: [research]
    approval: true
    model: opus

  - id: implement
    description: "并行实现"
    prompt: "在 {{params.repo_path}} 中根据架构设计 {{phase.design.output_file}} 实现所有模块。使用 /orchestrate 内部并行。"
    depends_on: [design]
    verify: standard

  - id: verify
    description: "集成验证"
    prompt: "对 {{params.repo_path}} 中的实现进行集成测试和代码审查。验证接口契约一致性。"
    depends_on: [implement]
    verify: strict
    approval: true
```

**Real-world example:** User authentication system (research auth standards → design JWT+OAuth architecture → implement register/login/reset modules → integration test + security review).

## 2. Recurring Briefing (`recurring-briefing`)

**Use case:** Daily/weekly research reports, competitive monitoring, tech trend tracking. Triggered by OS cron + `claude -p`.

```yaml
name: "recurring-briefing"
description: "定期研报：收集→分析→撰写→审阅"
params:
  topic: ""
  period: "daily"
  output_dir: "./reports"
phases:
  - id: collect
    description: "信息收集"
    prompt: "收集过去{{params.period}}关于{{params.topic}}的最新动态、新闻、论文和产品发布。"
    verify: light

  - id: analyze
    description: "趋势分析"
    prompt: "根据收集的信息 {{phase.collect.output_file}} 分析趋势、识别信号、对比变化。"
    depends_on: [collect]

  - id: write
    description: "撰写简报"
    prompt: "将分析结果 {{phase.analyze.output_file}} 撰写为{{params.period}}简报，含TL;DR、核心发现、详细分析。输出到{{params.output_dir}}/{{params.topic}}-{{params.period}}-report.md"
    depends_on: [analyze]
    
  - id: review
    description: "质量审阅"
    prompt: "审阅简报 {{phase.write.output_file}}，检查事实准确性、逻辑一致性和可读性。"
    depends_on: [write]
    approval: true
```

**Cron setup:** `0 9 * * 1-5 cd /project && claude -p "/workflow run recurring-briefing --param topic=AI-agent-orchestration --param period=daily"`

## 3. Event-Driven Pipeline (`event-pipeline`)

**Use case:** Monitoring → Alert → Investigate → Fix → Verify. Triggered by webhook, git hook, or file watcher.

```yaml
name: "event-pipeline"
description: "事件驱动：检测→调查→修复→验证"
params:
  alert_source: ""
  severity: "medium"
phases:
  - id: detect
    description: "事件检测与分类"
    prompt: "分析告警来源 {{params.alert_source}}，分类严重级别，确定影响范围。"

  - id: investigate
    description: "根因分析"
    prompt: "对分类后的告警进行根因分析。读取相关日志、指标和近期变更。"
    depends_on: [detect]
    timeout_minutes: 30

  - id: fix
    description: "修复实施"
    prompt: "根据根因分析 {{phase.investigate.output_file}} 实施修复。如果是代码问题，直接修改代码。如果是配置问题，更新配置。"
    depends_on: [investigate]
    verify: standard
    approval: true
    approval_question: "修复方案是否安全？确认后执行。"

  - id: verify
    description: "修复验证"
    prompt: "验证修复效果：检查告警是否消除、运行回归测试、确认无新增问题。"
    depends_on: [fix]
    verify: strict
```

## 4. Data Pipeline Chain (`data-pipeline`)

**Use case:** Extract → Transform → Validate → Load. Each phase handles one stage of data processing with its own agent parallelism.

```yaml
name: "data-pipeline"
description: "数据处理流水线：提取→转换→验证→加载"
params:
  source: ""
  target: ""
  schema: ""
phases:
  - id: extract
    description: "数据提取"
    prompt: "从 {{params.source}} 提取数据。处理分页、限流、格式兼容。"

  - id: transform
    description: "数据转换"
    prompt: "将提取的数据 {{phase.extract.output_file}} 按照 schema {{params.schema}} 进行转换和清洗。"
    depends_on: [extract]
    verify: light

  - id: validate
    description: "数据验证"
    prompt: "验证转换后的数据 {{phase.transform.output_file}} 的质量、完整性和 schema 一致性。"
    depends_on: [transform]
    verify: standard

  - id: load
    description: "数据加载"
    prompt: "将验证通过的数据加载到 {{params.target}}。处理增量更新、去重、索引更新。"
    depends_on: [validate]
    approval: true
```

## 5. Continuous Improvement Loop (`improve-loop`)

**Use case:** Build → Measure → Learn → Rebuild. Quality improvement, performance optimization, refactoring cycles.

```yaml
name: "improve-loop"
description: "持续改进：度量→分析→改进→评估（循环）"
params:
  target: ""
  metric: ""
  target_value: ""
  max_iterations: 3
phases:
  - id: measure
    description: "度量基线"
    prompt: "测量 {{params.target}} 的 {{params.metric}} 当前值，建立基线。"

  - id: analyze
    description: "差距分析"
    prompt: "对比基线 {{phase.measure.output_file}} 与目标 {{params.target_value}}，识别改进机会和优先级。"
    depends_on: [measure]

  - id: improve
    description: "实施改进"
    prompt: "实施 {{phase.analyze.output_file}} 中优先级最高的改进项。每次迭代聚焦一个改进点。"
    depends_on: [analyze]
    verify: standard

  - id: evaluate
    description: "效果评估"
    prompt: "重新测量 {{params.metric}}，对比改进前后。判断是否达到 {{params.target_value}}。"
    depends_on: [improve]
    approval: true
    approval_question: "当前指标 vs 目标。继续下一轮改进还是结束？(已执行 N/{{params.max_iterations}} 轮)"
```

**Loop control:** The workflow manager tracks iteration count via state. After `evaluate` phase, if target not met and iterations < max, reset `measure`→`analyze`→`improve`→`evaluate` statuses and loop. Max `max_iterations` loops.

## Template Selection Guide

| Scenario | Trigger | HITL Density | Typical Duration | Token Cost |
|----------|---------|-------------|-----------------|------------|
| phase-project | Manual | 2 gates (design, verify) | 30-120 min | 200-800k |
| recurring-briefing | Cron | 1 gate (review) | 10-20 min | 100-300k |
| event-pipeline | Webhook/hook | 1 gate (fix) | 15-45 min | 150-500k |
| data-pipeline | Manual/schedule | 1 gate (load) | 20-60 min | 100-400k |
| improve-loop | Manual | Per-iteration gate | 30-90 min/iter | 150-500k/iter |

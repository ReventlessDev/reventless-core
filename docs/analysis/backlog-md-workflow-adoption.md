# Analysis: Adopting Backlog.md, BMAD, and Agency-Agents for Reventless Development

## 1. Context

### 1.1 Current Workflow

The Reventless project follows a disciplined analysis-then-plan-then-implement workflow:

1. **Analysis** (`docs/analysis/`): Research a feature or problem. Explore options, compare trade-offs, make recommendations. Pure exploration — no implementation steps.
2. **Refinement**: Iterate on the analysis across multiple conversations, adding depth, considering alternatives, incorporating feedback.
3. **Plan** (`docs/plans/`): Convert the analysis recommendation into a concrete implementation roadmap with numbered steps, file-level changes, and checkboxes. Plans reference their source analysis.
4. **Refinement**: Break large plans into sub-plans, adjust steps based on discoveries during implementation.
5. **Implementation**: Execute the plan step by step, checking off items as they complete.
6. **Completion**: Move the plan to `docs/plans/done/` with `git mv`.

The project currently has 75 completed plans, 4 active plans, 7 backlog plans, 25 active analysis documents, and 6 completed analyses — a mature track record that demonstrates the workflow's effectiveness.

### 1.2 What's Being Evaluated

Three tools/methodologies are being evaluated for how they could improve or complement this workflow:

- **Backlog.md**: A Git-native, markdown-based task management system with CLI, Kanban board, and MCP server integration for Claude Code
- **BMAD Method** (Breakthrough Method for Agile AI-Driven Development): A framework with 12+ specialized AI agent personas and 34+ structured workflows spanning analysis through implementation
- **Agency-Agents**: A collection of 61+ specialized AI agent definitions organized into professional divisions (engineering, design, product, QA, etc.)

## 2. Backlog.md Assessment

### 2.1 How Backlog.md Works

Backlog.md stores tasks as individual markdown files in a `backlog/` directory with YAML frontmatter metadata:

```
backlog/
  tasks/
    task-1 - Extract shared spec packages.md
    task-2 - Implement online-first state store.md
    task-1.1 - Move CatalogEvents to catalog-spec.md    (subtask)
  completed/
  drafts/
  config.json
```

Each task file contains:
- **Title, ID, Status** (To Do / In Progress / Done)
- **Description**: The "why" — purpose and context
- **Acceptance Criteria**: The "what" — measurable outcomes
- **Priority, Labels, Assignee, Dependencies**
- **Plan**: Added when work begins — the "how"
- **Notes**: Implementation observations added during/after work

CLI commands: `backlog task create`, `backlog task list`, `backlog board` (Kanban), `backlog browser` (web UI).

MCP server integration provides `task_list`, `task_create`, `task_edit`, and `task_search` tools accessible to Claude Code.

### 2.2 Fit with the Current Reventless Workflow

| Current Artifact | Backlog.md Equivalent | Fit |
|-----------------|----------------------|-----|
| Analysis document (`docs/analysis/*.md`) | No direct equivalent | **Gap** — backlog.md is task-oriented, not analysis-oriented |
| Plan document (`docs/plans/*.md`) | Task with "Plan" field | **Partial** — a plan maps to one or more tasks, but loses the narrative structure |
| Plan step / checkbox | Subtask (`task-N.M`) | **Good** — subtasks model individual steps well |
| Backlog plan (`docs/plans/Backlog/*.md`) | Task with "To Do" status | **Good** — natural fit |
| Completed plan (`docs/plans/done/*.md`) | Task in `completed/` | **Good** — natural fit |
| Cross-plan dependencies | `dependencies` field | **Good** — explicit dependency tracking |

**Key gap**: Backlog.md is designed for **task management**, not for **analysis and exploration**. The current workflow's strength is the separation between open-ended analysis (exploring the problem space) and structured planning (defining the solution steps). Backlog.md's task model — with its emphasis on acceptance criteria and atomic deliverables — is a poor fit for analysis documents, which are iterative, narrative, and often don't have a clear "done" until the recommendation crystallizes.

### 2.3 How the Workflow Would Look with Backlog.md

**Phase 1: Analysis (unchanged)**
Analysis documents remain as markdown files in `docs/analysis/`. Backlog.md is not involved here — analysis is exploratory, not task-shaped.

**Phase 2: Planning → Task Decomposition**
Instead of writing a monolithic plan document, the analysis recommendation is decomposed into backlog tasks:

```bash
# From the rescript-client-architecture analysis, create tasks:
backlog task create "Extract shared spec packages from catalog and ordering plugins" \
  -d "Move pure types and functions (events, commands, state, projections, decisions) from catalog/ and ordering/ into catalog-spec/ and ordering-spec/ so they can be consumed by both server and client." \
  --ac "catalog-spec contains all CatalogEventLog event types,All StateViewSlice project functions in catalog-spec,All StateChangeSlice decide/reduce/command types in catalog-spec,catalog-spec has no dependency on reventless-core or reventless-aws,npm run build succeeds from root" \
  -l shared-packages,client-architecture \
  --priority high

backlog task create "Implement online-first in-memory state store" \
  -d "Create the in-memory state store for the online-first strategy..." \
  --ac "StateStore module with get/put/remove/subscribe,applyAction executor wired to store,Unit tests pass" \
  -l client-library,online-first \
  --priority medium
```

**Phase 3: Implementation**
Each task is picked up individually. The `project-manager-backlog` agent decomposes large tasks into subtasks if needed. When a task moves to "In Progress", implementation notes are added to its "Plan" field.

**Phase 4: Tracking**
`backlog board` shows the Kanban view. Dependencies between tasks are explicit. Progress is visible without reading through plan documents.

### 2.4 Importing Existing Plans and Analysis

The existing 75+ completed plans and 25+ analysis documents represent significant institutional knowledge. Options for integration:

**Option A: Reference only (recommended for completed work)**
Keep existing `docs/plans/done/` and `docs/analysis/done/` as-is. They serve as a historical reference. New work uses backlog.md going forward. Tasks can reference analysis documents in their description:

```markdown
## Description
Implement the online-first strategy as analyzed in
[docs/analysis/rescript-client-architecture.md](../../docs/analysis/rescript-client-architecture.md), section 2.
```

**Option B: Import backlog plans as tasks**
The 7 existing backlog plans (`docs/plans/Backlog/*.md`) can be imported as backlog.md tasks, since they represent future work that hasn't started:

```bash
# For each file in docs/plans/Backlog/:
backlog task create "GraphQL Subscriptions Real-Time" \
  -d "Implement real-time event delivery via AppSync WebSocket subscriptions. See docs/plans/Backlog/graphql-subscriptions-realtime.md for the detailed plan." \
  --ac "..." \
  -l graphql,real-time
```

The original plan files remain as detailed implementation guides, referenced from the task description.

**Option C: Import active plans as in-progress tasks**
The 4 active plans can become "In Progress" tasks, with their checkboxes mapped to subtasks. This gives immediate Kanban visibility but requires manual transcription.

**Recommendation**: Start with Option A + B. Keep the existing `docs/` structure for analysis and detailed plans. Use backlog.md for task tracking, prioritization, and status visibility. The two systems complement each other — `docs/analysis/` for depth, `backlog/tasks/` for breadth and status.

### 2.5 Advantages of Backlog.md

1. **Kanban visibility**: `backlog board` gives an at-a-glance view of what's in progress, blocked, and upcoming — something the current file-based system lacks
2. **Dependency tracking**: Explicit `dependencies` field surfaces blockers automatically
3. **AI integration**: MCP server lets Claude Code create, query, and update tasks directly during conversations
4. **Atomic task discipline**: Forces decomposition into independently completable units, reducing the risk of large plans stalling
5. **Git-native**: All task state lives in the repo, version-controlled alongside code
6. **Priority and label filtering**: `backlog task list --label client-library --status "To Do"` surfaces relevant work quickly

### 2.6 Consequences and Trade-offs

1. **Loss of narrative structure**: A plan document tells a story — why these steps, in this order, with these dependencies. A flat task list loses that narrative. Mitigation: keep plan documents as "epic" references, linked from tasks.
2. **Duplication risk**: If both `docs/plans/` and `backlog/tasks/` describe the same work, they can drift apart. Mitigation: one is the source of truth (backlog for status, docs for detail).
3. **Analysis doesn't fit**: Analysis documents are iterative explorations, not tasks. Forcing them into backlog.md's task model would lose their open-ended nature. Keep analysis in `docs/analysis/`.
4. **Migration effort**: Importing existing work takes time and may not add value for completed items.
5. **Tool dependency**: Backlog.md is an external tool. If it's abandoned, the markdown files remain readable but the CLI/Kanban/MCP features are lost.

## 3. BMAD Method Assessment

### 3.1 How BMAD Works

BMAD (Breakthrough Method for Agile AI-Driven Development) provides structured workflows across four development phases:

1. **Analysis**: Research, requirements gathering, feasibility studies
2. **Planning**: Architecture design, task decomposition, sprint planning
3. **Solutioning**: Detailed technical design, API contracts, data models
4. **Implementation**: Coding, testing, deployment

BMAD defines 12+ specialized AI agent personas (Product Manager, Architect, Developer, UX Designer, Scrum Master, etc.) that can be activated within conversations. Each persona comes with specific workflows, deliverables, and interaction patterns.

### 3.2 Fit with the Current Reventless Workflow

| BMAD Phase | Current Reventless Phase | Alignment |
|-----------|-------------------------|-----------|
| Analysis | `docs/analysis/*.md` | **Strong** — same purpose, BMAD adds structured prompts |
| Planning | `docs/plans/*.md` | **Strong** — BMAD's planning workflows could generate plan documents |
| Solutioning | Plan refinement + code design | **Moderate** — Reventless merges solutioning into planning |
| Implementation | Step-by-step plan execution | **Strong** — BMAD's Developer agent aligns with current approach |

BMAD's agent personas map to roles that the current workflow distributes across conversations:

| BMAD Agent | Current Equivalent | Value Add |
|-----------|-------------------|-----------|
| **Product Manager** | User (Martin) defining requirements | Could help formalize requirements before analysis |
| **Architect** | Analysis phase (Claude exploring options) | Structured architectural review workflows |
| **Developer** | Implementation phase (Claude writing code) | Already the default mode |
| **Scrum Master** | Manual plan tracking | Task decomposition, sprint planning workflows |
| **QA/Tester** | Test writing during implementation | Structured test strategy generation |

### 3.3 How BMAD Would Enhance the Workflow

**Analysis phase**: BMAD's analysis workflows provide structured prompts for exploring a problem space. Instead of free-form analysis, a BMAD-guided session would follow a template:
1. Problem statement formalization
2. Stakeholder identification
3. Requirements gathering (functional, non-functional)
4. Feasibility assessment
5. Options analysis with trade-off matrix
6. Recommendation with rationale

This aligns with how the Reventless analyses are already structured (e.g., the client architecture analysis has comparison tables, option analysis, and recommendations) — but BMAD makes the structure explicit and repeatable.

**Planning phase**: BMAD's Scrum Master persona could drive task decomposition from an analysis document, generating backlog.md tasks with proper acceptance criteria, priorities, and dependencies. This bridges the gap between analysis (narrative) and backlog (tasks).

**Implementation phase**: BMAD's Developer persona workflows include code review checklists, PR templates, and implementation patterns. These could complement the current "execute plan step by step" approach with more structured quality gates.

### 3.4 Advantages of BMAD

1. **Structured workflows**: Repeatable processes for each phase reduce the chance of skipping important steps
2. **Role-based thinking**: Activating an "Architect" persona encourages different thinking than a "Developer" persona, even within the same Claude conversation
3. **Scale-adaptive**: BMAD adjusts complexity based on project scope — a small bug fix doesn't need the full ceremony
4. **Deliverable templates**: Each workflow produces specific deliverables (requirements doc, architecture decision record, test plan) that map to existing `docs/` artifacts

### 3.5 Consequences and Trade-offs

1. **Ceremony overhead**: For small features, BMAD's full workflow may be heavier than the current "write analysis, write plan, implement" approach. The current workflow is already lean.
2. **Persona switching**: Activating different BMAD personas requires context — loading agent definitions, switching mental models. In the current workflow, Claude naturally shifts between analyst and implementer modes without explicit persona activation.
3. **Framework adoption cost**: Learning BMAD's 34+ workflows and knowing when to apply which one is a significant investment. The current workflow is simple and well-understood.
4. **Overlap with existing conventions**: BMAD's analysis templates overlap with the existing `docs/analysis/` format. Adopting BMAD means either migrating to its templates or maintaining two parallel structures.

## 4. Agency-Agents Assessment

### 4.1 How Agency-Agents Works

Agency-Agents provides 61+ AI agent definitions organized across 9 professional divisions. Each agent is a detailed markdown file that gives Claude a specific identity, expertise, workflow, and deliverables. Agents are loaded as Claude Code custom agents (`.claude/agents/`) or used as system prompts.

Divisions include: Engineering, Design, Marketing, Product & Project Management, Testing & QA, Game Development, Spatial Computing, and Support Functions.

### 4.2 Fit with the Reventless Workflow

For a backend framework project like Reventless, the most relevant agency-agents divisions are:

| Agent | Relevance | Use Case |
|-------|-----------|----------|
| **Backend Architect** | High | Architecture analysis, API design, system design reviews |
| **Frontend Wizard** | Medium | Client library design (React hooks, state management) |
| **DevOps Specialist** | Medium | CI/CD pipeline, Lambda deployment, infrastructure |
| **Security Engineer** | Medium | Auth, IAM policies, input validation review |
| **QA / Test Architect** | High | Test strategy, coverage analysis, test plan generation |
| **Product Manager** | Medium | Feature prioritization, requirements clarification |
| **Sprint Prioritizer** | Medium | Backlog grooming, task decomposition |

### 4.3 How Agency-Agents Would Enhance the Workflow

**Analysis phase**: Load the Backend Architect agent for architecture analysis. Its predefined expertise and workflow prompts would produce more structured architectural evaluations than a generic Claude conversation.

**Planning phase**: Load the Sprint Prioritizer agent to decompose an analysis into tasks. Combined with backlog.md, this creates a structured pipeline: analysis -> architect review -> task decomposition -> backlog.

**Implementation phase**: Load the relevant engineering agent for the specific work (Backend for server code, Frontend for client library). Each agent comes with domain-specific best practices and code review checklists.

**Quality phase**: Load the QA agent to review test coverage, generate test plans, and identify gaps. This is currently done ad-hoc during implementation.

### 4.4 Relationship to BMAD

Agency-Agents and BMAD serve overlapping but distinct purposes:

| Aspect | BMAD | Agency-Agents |
|--------|------|---------------|
| Focus | Workflows and processes | Agent personas and expertise |
| Structure | 34+ named workflows across 4 phases | 61+ agent definitions across 9 divisions |
| Granularity | Phase-level (analysis, planning, solutioning, implementation) | Role-level (architect, developer, QA, PM) |
| Integration | Framework with its own lifecycle model | Collection of agents, composable with any workflow |
| Overlap | Includes agent personas as part of workflows | Includes workflows as part of agent definitions |

They can be used together: BMAD provides the workflow structure (what to do when), and agency-agents provides the specialized expertise (who does it). Or either can be used standalone.

### 4.5 Consequences and Trade-offs

1. **Agent overload**: 61+ agents is too many to keep in mind. Only a handful are relevant to Reventless at any given time.
2. **Context cost**: Loading an agent definition into a Claude conversation uses context window space. Each agent is a detailed markdown file.
3. **Maintenance**: Agent definitions may drift from the project's actual conventions. Custom agents (like the existing `project-manager-backlog.md`) tuned to Reventless would be more effective than generic ones.
4. **Value concentration**: For Reventless specifically, 3-4 agents would cover 90% of needs (Backend Architect, QA, Sprint Prioritizer, and a custom Reventless Framework agent). The other 57+ agents are noise.

## 5. Recommended Approach: Integrated Workflow

### 5.1 Combining the Tools

Rather than adopting any single tool wholesale, combine the strengths of each:

```
                    Analysis                    Planning                Implementation
                    --------                    --------                --------------
Current:     docs/analysis/*.md  ──────>  docs/plans/*.md  ──────>  Code + tests
                                                                         |
Proposed:    docs/analysis/*.md  ──────>  backlog tasks    ──────>  Code + tests
             (with optional BMAD           (backlog.md)          (agency-agents for
              analysis workflow)           (sprint prioritizer    specialized review)
                                           agent for decomp)
```

**Analysis**: Keep `docs/analysis/` as the home for exploration documents. Optionally use BMAD's analysis workflow templates or an Architecture agent from agency-agents for structured reviews. The output remains a markdown document with recommendations.

**Task decomposition**: Use backlog.md to decompose the analysis recommendation into atomic tasks. The `project-manager-backlog` agent (already configured) or a Sprint Prioritizer agent drives the decomposition. Each task references the source analysis document.

**Detailed planning**: For complex tasks that need step-by-step instructions, keep plan documents in `docs/plans/` and link them from the backlog task. Simple tasks that don't need a separate plan document can use the task's built-in "Plan" field.

**Implementation**: Execute tasks from the backlog. Use agency-agents for specialized review (QA agent for test plans, Security agent for auth review) when appropriate.

**Tracking**: `backlog board` provides the Kanban view. Completed tasks move to `backlog/completed/`. Plan documents move to `docs/plans/done/`.

### 5.2 Proposed Workflow in Detail

```
1. EXPLORE
   - Create analysis document in docs/analysis/
   - Iterate across conversations (current approach)
   - Optional: use Architecture agent for structured review
   - Output: docs/analysis/feature-name.md

2. DECOMPOSE
   - Use project-manager-backlog agent to create tasks from analysis
   - Each task: atomic, testable, with acceptance criteria
   - Dependencies between tasks are explicit
   - Tasks reference the analysis document
   - Output: backlog/tasks/task-N - *.md (multiple tasks)

3. PLAN (if needed)
   - For complex tasks, write a detailed plan in docs/plans/
   - Link the plan from the task description
   - Simple tasks skip this step — acceptance criteria suffice
   - Output: docs/plans/feature-step-plan.md (optional)

4. IMPLEMENT
   - Pick task from backlog, move to "In Progress"
   - Follow plan (if exists) or task acceptance criteria
   - Optional: use specialized agent for review (QA, Security)
   - Add implementation notes to task
   - Output: Code + tests

5. COMPLETE
   - Mark task as Done
   - If all tasks from an analysis are done, move analysis to docs/analysis/done/
   - If plan exists, move to docs/plans/done/
```

### 5.3 Directory Structure

```
reventless-core/
  docs/
    analysis/              <- Unchanged: exploration and research documents
      done/
      postponed/
      rejected/
    plans/                 <- Unchanged: detailed implementation plans (complex tasks only)
      done/
      Backlog/             <- Phase out: migrate remaining items to backlog tasks
  backlog/                 <- NEW: task tracking via backlog.md
    tasks/
    completed/
    drafts/
    config.json
  .claude/
    agents/
      project-manager-backlog.md   <- Existing: task creation agent
      backend-architect.md         <- NEW: from agency-agents, customized for Reventless
      qa-reviewer.md               <- NEW: from agency-agents, customized for Reventless
```

### 5.4 Migration Path

**Phase 1: Initialize backlog.md**
- Run `backlog init` in the repo
- Configure labels, statuses, and priorities
- Add `backlog/` to git

**Phase 2: Import backlog plans**
- Convert the 7 files in `docs/plans/Backlog/` to backlog.md tasks
- Keep the plan files as detailed references, linked from tasks
- Optionally archive `docs/plans/Backlog/` once all items are imported

**Phase 3: New work uses backlog.md**
- Future analyses produce backlog tasks (not plan documents) for simple work
- Complex work still gets plan documents, but tracked as backlog tasks
- Kanban board becomes the primary status view

**Phase 4: Add specialized agents (optional)**
- Create 2-3 custom agents from agency-agents templates, tuned to Reventless conventions
- Use them for architectural review, QA, and task decomposition as needed

## 6. Usage for Reventless Application Developers

Backlog.md is not just useful for framework development — it could also serve as a planning tool for application developers building on Reventless.

### 6.1 Application Development Workflow

An application developer using Reventless follows a similar lifecycle:

1. **Domain analysis**: Model the domain events, commands, and read models using event modeling or event storming
2. **Plugin design**: Design plugins, extension points, and cross-plugin communication
3. **Implementation**: Create spec packages, plugin packages, platform assembly
4. **Deployment**: Configure AWS infrastructure, deploy via Pulumi

Backlog.md can structure this as a task-driven workflow:

```bash
# Domain modeling tasks
backlog task create "Model Catalog domain events" \
  --ac "Event types defined: ProductAdded, ProductPriceChanged, CategoryAdded,All events have @schema annotations,Events compile with sury-ppx"

backlog task create "Design Catalog StateChangeSlices" \
  --ac "AddProduct decide/reduce implemented,ChangeProductPrice decide/reduce implemented,All slices pass unit tests with in-memory backend"

backlog task create "Design ProductsView StateViewSlice" \
  --ac "project function handles all Catalog events,State type has @schema annotation,Round-trip encode/decode test passes"

# Integration tasks
backlog task create "Wire Catalog plugin" \
  --ac "CatalogPlugin.Make functor compiles,All slices registered in DcbSpec,GraphQL mutations and queries generated"

# Deployment tasks
backlog task create "Deploy to AWS" \
  --ac "Pulumi up succeeds,GraphQL API accessible,E2E test passes against deployed stack"
```

### 6.2 Project Templates

Backlog.md could ship with Reventless-specific task templates:

```bash
# Template: New DCB Plugin
backlog task create "Define {PluginName} event types" --template dcb-events
backlog task create "Implement {Entity} StateChangeSlices" --template dcb-state-change
backlog task create "Implement {Entity} StateViewSlices" --template dcb-state-view
backlog task create "Wire {PluginName} plugin" --template dcb-plugin
backlog task create "Add {PluginName} E2E tests" --template dcb-tests
```

This could be provided as a `reventless-templates` package or as a section in the Reventless documentation, giving application developers a structured starting point.

### 6.3 Combined with BMAD/Agency-Agents for Application Developers

Application developers could use the same toolchain:
- **Architecture agent**: Review their domain model and plugin design before implementation
- **BMAD analysis workflow**: Structure their domain exploration (event storming results, bounded context identification)
- **Backlog.md**: Track implementation progress through the standard Reventless plugin development lifecycle
- **QA agent**: Generate test plans for their specific domain logic

## 7. Comparison Matrix

| Aspect | Current Workflow | + Backlog.md | + BMAD | + Agency-Agents |
|--------|-----------------|--------------|--------|-----------------|
| Task visibility | Read individual plan files | Kanban board, filtered lists | Unchanged | Unchanged |
| Analysis structure | Free-form markdown | Unchanged | Structured templates | Architecture agent review |
| Task decomposition | Manual in plan documents | CLI-driven, atomic tasks | Scrum Master workflow | Sprint Prioritizer agent |
| Dependency tracking | Implicit (reading plan text) | Explicit `dependencies` field | Unchanged | Unchanged |
| Status tracking | File location (plans/ vs done/) | Task status field + board | Unchanged | Unchanged |
| Quality gates | Ad-hoc during implementation | Acceptance criteria per task | Phase-specific checklists | Specialized review agents |
| AI integration | Claude reads/writes plan files | MCP server for task CRUD | Agent persona activation | Agent loading for expertise |
| Onboarding (app devs) | Read docs, follow examples | Task templates + board | Guided workflows | Specialized guidance |
| Overhead | Low (just markdown files) | Low (CLI + markdown files) | Medium (workflow learning) | Low (load agent when needed) |
| Git integration | Native (files in repo) | Native (files in repo) | N/A (workflow guidance) | Native (agent files in repo) |

## 8. Recommendation

**Adopt backlog.md as the primary task tracking layer.** It fills the biggest gap in the current workflow — visibility and status tracking — without replacing what works well (analysis documents, detailed plan documents).

**Selectively adopt agency-agents.** Create 2-3 custom agents tuned to Reventless (Backend Architect, QA Reviewer, Task Decomposer). Don't adopt the full 61-agent collection — most are irrelevant.

**Defer BMAD adoption.** The current analysis/plan workflow is already effective and well-established. BMAD's structured workflows add value for teams that lack a process, but Reventless already has one. Individual BMAD workflow templates (like its analysis checklist) can be borrowed without adopting the full framework.

**Provide backlog.md templates for application developers.** This extends the toolchain beyond framework development to the application development lifecycle, giving Reventless users a structured path from domain modeling to deployment.

### Priority Order

1. **backlog init** + import existing backlog plans (immediate value, low effort)
2. **Custom Backend Architect agent** for analysis review (moderate value, low effort)
3. **Task templates for app developers** (high value for ecosystem, moderate effort)
4. **Custom QA agent** for test plan generation (moderate value, low effort)
5. **BMAD workflow templates** for analysis structure (low value given existing process, moderate effort)

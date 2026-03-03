# Event Modeling vs Reventless: Analysis and Comparison

## 1. What is Event Modeling?

Event Modeling is an information system design methodology created by **Adam Dymitruk** at **Adaptech Group**. It describes systems through a timeline of events — how information changes over time — producing a visual blueprint understandable by both business stakeholders and developers.

### Core Principles

- **Time as the core axis**: Systems are described through a chronological timeline of events, not entity relationships or state diagrams
- **Specification by example**: Every step uses concrete example data, extending "specification by example" into system design
- **Information completeness**: Example data enables auditing — you can trace every piece of displayed data back to an event or command, exposing missing requirements
- **Only 4 patterns**: All information systems reduce to 4 predictable patterns (see Section 3)
- **Implementation-agnostic**: Describes *what* the system does, not *how* it is implemented
- **Parallel development**: Each slice is an independent unit of work that can be assigned to separate developers/teams

### Lineage

Event Modeling builds on:
- **Event Storming** (Alberto Brandolini) — discovery-focused workshop technique
- **CQRS** (Greg Young) — command/query separation
- **Event Sourcing** — storing state as a sequence of immutable events
- **Domain-Driven Design** (Eric Evans) — strategic and tactical design patterns
- **BDD** — Given/When/Then specification format

---

## 2. Event Modeling Building Blocks

| Color | Element | Description |
|-------|---------|-------------|
| **White** | Trigger / UI Wireframe | What initiates a use case — a user via UI, external API call, or automated process |
| **Blue** | Command | The intent to change state. Imperative mood (e.g., "Create Order") |
| **Orange** | Event | An immutable fact that happened. Past tense (e.g., "OrderCreated") |
| **Green** | View / Read Model | A projection of events into queryable state for a specific UI or process |

### Organizational Concepts

- **Timeline**: Horizontal axis along which all events are arranged chronologically
- **Swimlane**: Horizontal lane representing a persona, system, or bounded context
- **Stream**: Sequence of events for a specific aggregate/entity instance
- **Slice**: The smallest implementable unit of work — a vertical cut through the model
- **Example Data**: Concrete data values in commands, events, and views ensuring information completeness

---

## 3. The 4 Slice Types (Patterns)

### 3.1 Command Slice (State Change)

```
UI/Trigger (white) → Command (blue) → Event(s) (orange)
```

A trigger sends a command which — after validation against business rules — produces events. Specified as:
- **Given**: Prior events (state built from previous events)
- **When**: The command is issued
- **Then**: New event(s) are produced (or the command is rejected)

### 3.2 View Slice (State View)

```
Event(s) (orange) → Read Model (green) → UI/Screen (white)
```

Events feed into a read model/projection, producing a queryable view consumed by the UI. Specified as:
- **Given**: A set of prior events
- **When**: The view is queried
- **Then**: The expected data is returned

### 3.3 Automation Slice (Processor / TODO List Pattern)

```
Event(s) (orange) → TODO List (green) → Processor → Command (blue) → Event(s) (orange)
```

Events build up a "TODO list" read model. A processor monitors this list and issues commands for each pending item. When the command produces an event, the TODO list marks the item completed. This ensures idempotency and prevents double-processing.

### 3.4 Translation Slice (External System Integration)

```
Event(s) (orange) → Translator → External System
External System → Translator → Event(s) (orange)
```

Transfers knowledge between internal and external systems (anti-corruption layer). Inbound translations convert external data into domain events; outbound translations communicate internal events to external systems.

---

## 4. Event Modeling Tools Landscape

### Purpose-Built Tools

| Tool | Visual Design | Collaboration | Code Generation | Key Feature |
|------|:---:|:---:|:---:|-------------|
| **Evident Design** (Bobby Calderwood) | Yes | Real-time | Planned | Constrained canvas purpose-built for event modeling; data model enabling code gen and project management artifacts |
| **Prooph Board** | Yes | Real-time (paid) | Yes (Cody bot) | Integrated coding bot that translates visual models into event-sourced code; derives stories/tasks from model |
| **Qlerify** | Yes | Yes | Yes (AI-powered) | AI-powered generation of event models and code from natural language descriptions |
| **Modellution** | Yes | Yes | Unknown | Focus on development team velocity |
| **Miro + Plugin** | Yes | Real-time | No | Event Modeling toolkit app in marketplace; integrates with existing Miro workflows |

### What These Tools Provide

1. **Visual design canvas** — drag-and-drop building blocks onto a timeline
2. **Collaboration** — real-time multi-user editing
3. **Specification** — Given/When/Then test cases from the model
4. **Code generation** — Prooph Board's Cody bot generates event-sourced code; Qlerify uses AI
5. **Project management** — slices become backlog items; tools derive user stories and tasks
6. **Information completeness auditing** — tracing data lineage through the model

---

## 5. Terminology Comparison

| Event Modeling Term | Reventless Term | Notes |
|---|---|---|
| **Command** (blue box) | `Aggregate.command` / `StateChangeSlice.command` | Same concept. Imperative intent to change state. |
| **Event** (orange box) | `Aggregate.event` / `DcbEventLog.event` | Same concept. Immutable fact that happened. |
| **Read Model / View** (green box) | `ReadModel` + `QueryDb` / `StateViewSlice` | Same concept. Reventless splits the projection (ReadModel) from storage (QueryDb). |
| **Trigger / Wireframe** (white box) | `CommandGenerator` / `Api` | Partial mapping. Reventless has GraphQL API + mutation resolvers but no wireframe concept. |
| **Aggregate** | `Aggregate` | Same concept. Decision-making boundary handling commands within a single stream. |
| **Stream** | `EventLog` | Same concept. Sequence of events for an aggregate. In DCB mode: shared `DcbEventLog` with tag filtering. |
| **Projection** | `ReadModel.Projection.action` algebra | Same concept. Rich mutation algebra: Create, Update, Set, Delete, UpdateWithDefault, etc. |
| **Command Slice (State Change)** | `StateChangeSlice` | Direct mapping. Reventless names its DCB write-side component after the Event Modeling pattern. |
| **View Slice (State View)** | `StateViewSlice` | Direct mapping. Reventless names its DCB read-side component after the Event Modeling pattern. |
| **Automation / Processor** | `EventMapper` + `Counter` | Partial mapping. EventMapper routes events to commands. Counter provides threshold-based triggering. But no explicit TODO List pattern. |
| **Translation Slice** | `SideEffectHandler` + `Task` | Partial mapping. Outbound: SideEffectHandler calls external systems. Inbound: no dedicated anti-corruption layer component. |
| **TODO List Pattern** | No direct equivalent | Missing. Reventless has no built-in TODO list read model pattern for automation. |
| **Policy** | `EventMapper.map` function | Partial. Business rules in the map function determine when/how to route events to commands. |
| **Swimlane** | `Plugin` | Approximate mapping. A Plugin is a bounded context containing aggregates and read models. |
| **Blueprint / Model** | No equivalent | Missing. No visual design or specification tool. |
| **Example Data** | Test fixtures | Partial. Reventless has test fixtures but no specification-by-example tooling. |
| **Information Completeness** | No equivalent | Missing. No data lineage auditing capability. |
| **Slice** (as work unit) | No equivalent | Missing. No concept of vertical slicing for project management. |
| **Given/When/Then** | Test patterns | Partial. Tests follow GWT convention but it's not formalized in the framework. |
| **Scheduler** | `Scheduler` + `Heartbeat` | Reventless has scheduling that Event Modeling lacks as a distinct pattern (time-based triggers). |
| **Extension Point / Extension** | `ExtensionPoint` + `Extension` | Reventless-specific. Cross-plugin communication protocol not present in Event Modeling. |
| **Decision Model** (DCB) | `StateChangeSlice.decisionModel` | Reventless-specific. Ephemeral state built from filtered events for command validation. |

---

## 6. What Reventless Already Supports

### Fully Supported Event Modeling Patterns

| Pattern | Reventless Implementation | How It Works |
|---------|--------------------------|--------------|
| **Command Slice (State Change)** | `Aggregate` or `StateChangeSlice` | Commands validated against state (replay or decision model), producing events appended to EventLog/DcbEventLog |
| **View Slice (State View)** | `ReadModel` + `EventCollector` + `QueryDb`, or `StateViewSlice` | Events fan out via EventTopic → EventCollector → ReadModel projection → QueryDb. StateViewSlice combines these in DCB mode. |
| **Automation Slice** (partial) | `EventMapper` + `Counter` | EventMapper maps events to commands for cross-aggregate choreography. Counter provides dedup and threshold triggering. |
| **Translation Slice** (outbound only) | `SideEffectHandler` | Listens to events and calls external systems. Read-only access to QueryEngine for context. |

### Additional Reventless Capabilities Beyond Event Modeling

| Capability | Component | Description |
|-----------|-----------|-------------|
| **Infrastructure-as-Code** | `Pulumi` integration | All components are both design-time (infrastructure) and runtime (handlers) |
| **Cross-plugin communication** | `ExtensionPoint` + `Extension` | Bidirectional protocol with version negotiation for plugin composition |
| **GraphQL API generation** | `Api` + `CommandGenerator` | Auto-generated query resolvers from read models + mutation-to-command bridge |
| **Scheduled commands** | `Scheduler` + `Heartbeat` | Time-based triggers (cron, one-time, intervals) — not a standard Event Modeling pattern |
| **Background tasks** | `Task` | S3-triggered or scheduled work outside the command/event paradigm |
| **Deduplication counting** | `Counter` | Named counters with threshold targets for conditional command generation |
| **DCB (Distributed Consistency Boundary)** | `DcbEventLog` + `StateChangeSlice` | Shared event log with tag-based filtering and optimistic concurrency — more advanced than basic Event Modeling aggregates |
| **Multi-provider abstraction** | `Platform.T` | AWS, in-memory, and potentially other providers via abstract factory |
| **Type-safe message serialization** | `sury-ppx` | Automatic JSON codec generation with schema validation |
| **In-memory testing platform** | `reventless-in-memory` | Full framework running in-process for local dev and testing |

---

## 7. What Is Still Missing in Reventless

### High Priority — Core Event Modeling Gaps

#### 7.1 TODO List Pattern for Automations
**Event Modeling**: Automations use a dedicated TODO list read model that accumulates pending work items. A processor works through them, issues commands, and marks items done. This ensures idempotency and prevents double-processing.

**Reventless today**: `EventMapper` maps events directly to commands in a stateless function. There is no built-in mechanism for:
- Accumulating pending work items in a queryable list
- Tracking completion status of automated work
- Resuming from where processing left off after failures
- Ensuring idempotent processing of each TODO item exactly once

**Gap**: Need a `TodoListProcessor` or `AutomationSlice` component that combines a read model (the TODO list) with a processor that monitors it and issues commands.

#### 7.2 Inbound Translation Slice
**Event Modeling**: External systems push data inward, which a translator converts into domain events via an anti-corruption layer.

**Reventless today**: `SideEffectHandler` only supports outbound (events → external system). `Task` can receive S3 triggers but there is no dedicated inbound translation component that:
- Receives external data (webhook, API call, message queue)
- Validates and transforms it through an anti-corruption layer
- Produces domain commands or events

**Gap**: Need an `InboundTranslator` or `ExternalEventAdapter` component for ingesting external data as domain commands.

#### 7.3 Visual Event Model / Blueprint Tool
**Event Modeling**: The methodology centers on a visual blueprint — a shared artifact that business and technical stakeholders collaborate on.

**Reventless today**: No visual design tool. Component structure is defined in code (ReScript specs). While the Docusaurus documentation site has D2 diagrams, there is no:
- Interactive visual canvas for designing event models
- Drag-and-drop building blocks (commands, events, views)
- Real-time collaborative editing
- Visual timeline representation

**Gap**: This is a tooling gap rather than a framework gap. Options: (a) build a visual modeler that generates Reventless specs, (b) integrate with existing tools like Prooph Board or Evident Design, (c) create import/export between event modeling tools and Reventless component definitions.

#### 7.4 Specification by Example / Given-When-Then Formalization
**Event Modeling**: Every slice is specified with concrete example data in Given/When/Then format. This serves as both specification and test case.

**Reventless today**: Tests follow GWT patterns by convention but there is no:
- Formal specification format for slice behavior
- Auto-generation of test cases from specifications
- Specification documents that serve as living documentation
- Contract testing between slices

**Gap**: Need a specification DSL or format that:
- Defines slice behavior with concrete example data
- Generates test cases automatically
- Validates implementations against specifications
- Produces human-readable documentation

#### 7.5 Information Completeness Auditing
**Event Modeling**: The model enables auditing whether all data shown in views can be traced back to events/commands. If data appears in a view but no prior event carries it, requirements are missing.

**Reventless today**: No data lineage capability. Type safety helps (ReScript ensures events contain declared fields), but there is no:
- Automated check that read model fields trace to event fields
- Static analysis of data flow from commands → events → projections
- Detection of "phantom data" in views that has no source event

**Gap**: Could be implemented as a build-time analysis tool that traces field-level data flow through specs.

### Medium Priority — Workflow and Project Management Gaps

#### 7.6 Vertical Slicing as Work Units
**Event Modeling**: Slices are the smallest independent units of work. They can be assigned to developers/teams and developed in parallel.

**Reventless today**: Components are the unit of work, but there is no:
- Formal slice definition that groups related components
- Work item generation from slices
- Progress tracking per slice
- Dependency analysis between slices

**Gap**: Need a way to define and track slices as first-class work units, possibly through metadata or a project management integration.

#### 7.7 Automation Slice with Completion Tracking
**Event Modeling**: The TODO list pattern provides built-in idempotency and progress visibility. You can always see what has been processed and what is pending.

**Reventless today**: `EventMapper` processes events fire-and-forget. `Counter` tracks counts but not individual item completion. There is no:
- Per-item processing status (pending/in-progress/completed/failed)
- Retry with backoff for individual items
- Dashboard showing automation progress
- Dead letter handling for individual TODO items

**Gap**: Extends gap 7.1 — the TODO list pattern needs completion tracking, retry semantics, and observability.

### Lower Priority — Nice-to-Have Features

#### 7.8 Multi-System Event Model
**Event Modeling**: A single blueprint can span multiple systems, showing translation slices between them.

**Reventless today**: `Plugin` + `ExtensionPoint` + `Extension` support cross-plugin communication, but the mental model is "plugins extending a host" rather than "systems exchanging knowledge." No multi-system blueprint concept.

#### 7.9 Event Model Import/Export
**Gap**: No way to import an event model from tools like Prooph Board, Evident Design, or Miro and generate Reventless component scaffolding. No way to export Reventless component definitions as a visual event model.

#### 7.10 Saga / Long-Running Process Support
**Event Modeling**: Complex automations spanning multiple steps across time are represented as sequences of automation slices.

**Reventless today**: No explicit saga or long-running process manager. Complex multi-step automations must be composed manually from EventMappers, Counters, and Schedulers. There is no:
- Saga state machine definition
- Compensation/rollback logic
- Timeout handling for multi-step processes
- Visual representation of saga flow

---

## 8. Summary: Feature Support Matrix

| Event Modeling Feature | Reventless Support | Component(s) |
|---|---|---|
| Commands | Fully supported | `Aggregate`, `StateChangeSlice`, `CommandTopic` |
| Events | Fully supported | `EventLog`, `DcbEventLog`, `EventTopic` |
| Read Models / Views | Fully supported | `ReadModel`, `QueryDb`, `StateViewSlice` |
| Command Slice (State Change) | Fully supported | `Aggregate` or `StateChangeSlice` |
| View Slice (State View) | Fully supported | `ReadModel` + `QueryDb` or `StateViewSlice` |
| Automation Slice | Partially supported | `EventMapper` + `Counter` (no TODO list pattern) |
| Translation Slice (outbound) | Partially supported | `SideEffectHandler` |
| Translation Slice (inbound) | Not supported | No anti-corruption layer component |
| TODO List Pattern | Not supported | No built-in processor with completion tracking |
| Swimlanes / Bounded Contexts | Supported | `Plugin` |
| Streams | Supported | `EventLog`, `DcbEventLog` |
| Given/When/Then specification | Convention only | Test patterns, not formalized |
| Visual Blueprint / Model | Not supported | No visual tooling |
| Specification by Example | Not supported | No formal specification format |
| Information Completeness | Not supported | No data lineage auditing |
| Vertical Slicing (work units) | Not supported | No slice-as-work-unit concept |
| Saga / Long-Running Process | Not supported | Must compose manually |
| Event Model Import/Export | Not supported | No integration with modeling tools |
| Scheduling (time-based) | Fully supported | `Scheduler`, `Heartbeat` (beyond Event Modeling) |
| Cross-plugin protocols | Fully supported | `ExtensionPoint`, `Extension` (beyond Event Modeling) |
| Infrastructure-as-Code | Fully supported | Pulumi integration (beyond Event Modeling) |
| GraphQL API generation | Fully supported | `Api`, `CommandGenerator` (beyond Event Modeling) |
| DCB / Optimistic Concurrency | Fully supported | `DcbEventLog`, `StateChangeSlice` (beyond Event Modeling) |

---

## 9. Recommended Priorities

1. **TODO List Pattern / Automation Slice component** — Highest impact. Enables the most common Event Modeling automation pattern and provides idempotent processing with visibility.
2. **Inbound Translation component** — Needed for any system that receives data from external sources (webhooks, partner APIs, message queues).
3. **Given/When/Then specification format** — Would enable auto-generated tests, living documentation, and potential integration with visual modeling tools.
4. **Event Model import/export** — Bridge between visual design tools and Reventless code, enabling round-trip engineering.
5. **Information completeness analysis** — Build-time static analysis tracing data flow through component specs.
6. **Saga support** — For complex multi-step business processes spanning time and multiple aggregates.

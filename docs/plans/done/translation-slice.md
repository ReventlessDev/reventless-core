# Plan: TranslationSlice Component

Implements the Event Modeling **Translation Slice** as a first-class Reventless component.
See `docs/analysis/event-modeling-comparison.md` Section 7.2.

## Motivation

Event Modeling's translation pattern handles communication between a system and external services:

```
Inbound:  External System → Translator → Command → Event(s)
Outbound: Event(s) → Translator → External System
```

Reventless today has partial coverage:

| Direction | Current Support | Gap |
|-----------|----------------|-----|
| **Outbound** | `SideEffectHandler` — listens to events, calls external APIs | Fire-and-forget. No TODO list, no retry tracking, no completion status. |
| **Inbound** | `Task` — receives S3 triggers | No webhook/API/message-queue ingestion. No anti-corruption layer for translating external data into domain commands. |

The TranslationSlice provides a unified component for both directions with proper tracking,
retry semantics, and anti-corruption layer support.

## Design

### Two Sub-Patterns

Rather than a single monolithic component, the TranslationSlice comes in two variants
matching the two directions:

1. **OutboundTranslationSlice** — Events → TODO List → Translator → External System
2. **InboundTranslationSlice** — External System → Translator → Command → Events

Both share the TODO list pattern from AutomationSlice (see `docs/plans/automation-slice.md`)
but differ in their I/O boundaries.

### Why Two Variants Instead of One?

The two directions have fundamentally different triggers and wiring:

- **Outbound**: triggered by internal events (EventCollector subscription), produces external
  API calls. Wires into DcbEventLog EventTopic.
- **Inbound**: triggered by external inputs (webhook, queue, API call), produces internal
  commands. Wires into CommandTopic. Has no EventCollector subscription.

Combining them into one component would create a confusing spec with half the fields unused
in each direction. Two focused components are clearer.

---

## Part A: OutboundTranslationSlice

### Conceptual Model

```
DcbEventLog events
    ↓ (subscribe via EventTopic)
OutboundTranslationSlice TODO List (QueryDb)
    ↓ (processor reads pending items)
Translator (user-defined async function)
    ↓ (calls external API/webhook/email)
External System
    ↓ (response)
Ok(Some((targetId, command))) → publish command via publishJsons
Ok(None) → fire-and-forget, no command
Error(msg) → retry
    ↓
TODO item marked completed
```

### Difference from SideEffectHandler

| Aspect | SideEffectHandler | OutboundTranslationSlice |
|--------|-------------------|--------------------------|
| State tracking | None — fire-and-forget | TODO list with status variant (Pending/Processing/Completed/Failed) |
| Retry | Relies on EventCollector retry (entire batch) | Per-item retry with configurable backoff |
| Idempotency | None — replays cause duplicate calls | Deduplication key prevents double-processing |
| Visibility | No observability | QueryDb stores full processing history |
| Completion | Assumed after execute returns | Explicit status tracking with timestamps |
| Command emission | Never | Optional — can publish commands back (e.g., store confirmation) |

### Spec Definition

```rescript
// reventless/reventless-spec/src/components/OutboundTranslationSlice.res

module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec

  /** The work item state — what data to send to the external system. */
  @schema type outboundItem

  /**
  The command type to publish back into the domain after a successful translation.
  Use `unit` if no command is needed (fire-and-forget). Published to the shared DCB
  CommandTopic; routing to the correct StateChangeSlice happens automatically via
  command variant type names.
  */
  @schema type inboundCommand

  /**
  Collect: map an incoming event to zero or more outbound work items.
  Each item has an `id` (deduplication key) and the `outboundItem` payload.
  */
  let collect: DcbEventLogSpec.event => array<(string, outboundItem)>

  /**
  Translate: send an outbound item to the external system.
  This is the anti-corruption layer — the user implements the actual API call,
  webhook, email send, etc.

  Returns:
  - `Ok(Some((targetId, command)))` — success, publish command back into domain
  - `Ok(None)` — success, fire-and-forget (no command needed)
  - `Error(string)` — failure, item will be retried according to retry policy
  */
  let translate: (string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>

  /** Maximum number of retries for a failed translation. Default: 3. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. Default: 60. */
  let heartbeatInterval: int
}
```

### Component Structure

```
reventless/reventless-spec/src/components/
  └── OutboundTranslationSlice.res         # Spec module type

reventless/reventless-core/src/components/OutboundTranslationSlice/
  ├── OutboundTranslationSlice.res         # Type definitions
  ├── OutboundTranslationSlice_Builder.res # Factory: EventCollector + QueryDb + Processor
  └── OutboundTranslationSlice_Callback.res # Runtime handler
```

### Type Definitions

```rescript
// reventless/reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice.res

let componentType = ComponentType.OutboundTranslationSlice

type t
type outputs = {
  resources: array<ReventlessInfra.Adapter.resource>,
  queryDb: QueryDb.outputs,
}

type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  /** Manually trigger translate sweep (useful in tests and for the Heartbeat handler). */
  translatePending: unit => promise<unit>,
}

type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.OutboundTranslationSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### Builder

Follows the StateViewSlice pattern with added scheduled processing (same dual-trigger
approach as AutomationSlice):

1. Creates a **QueryDb** for outbound TODO list storage
2. Creates an **EventCollector** subscribed to the DcbEventLog's EventTopic
3. Receives `~publishJsons` for optional command-back publishing
4. Wires an **event handler** that runs Phase 1 (collect) + Phase 2 (translate)
5. Wires a **Heartbeat handler** that periodically runs Phase 2 only (sweep for
   pending/failed items that need translation or retry)

### Callback (Runtime Handler)

Two entry points sharing Phase 2 logic (same pattern as AutomationSlice):

#### Entry Point A — Event Handler (triggered by EventCollector)

```
Phase 1 — Collect (for each event in batch):
  for each (id, item) in Spec.collect(event):
    if not exists in QueryDb:
      insert {id, item, status: Pending, retryCount: 0, ...}
```

Then runs Phase 2.

#### Phase 2 — Translate (shared logic, also called by Heartbeat)

```
read items where status in [Pending, Failed] and retryCount < maxRetries
for each item:
  update status to Processing
  match await Spec.translate(item.id, item.outboundItem):
    Ok(Some((targetId, command))) →
      publish command via publishJsons(targetId, meta, commandJson)
      update status to Completed, set completedAt
    Ok(None) →
      update status to Completed, set completedAt
    Error(msg) →
      update status to Failed, increment retryCount, record error
```

#### Entry Point B — Heartbeat Handler (triggered by Scheduler/Heartbeat)

Runs Phase 2 only. Catches:
- Failed items eligible for retry
- Items stuck in `Processing` beyond a timeout (reset to `Pending`)

The heartbeat interval is configurable via `Spec.heartbeatInterval`.

---

## Part B: InboundTranslationSlice

### Conceptual Model

```
External System (webhook / API call / message queue)
    ↓
InboundTranslationSlice endpoint
    ↓ (anti-corruption layer: validate + transform)
Translator (user-defined function)
    ↓ (produces domain command)
CommandTopic → StateChangeSlice → DcbEventLog
```

### Difference from Task

| Aspect | Task | InboundTranslationSlice |
|--------|------|--------------------------|
| Trigger | S3 object / schedule | HTTP webhook / API / message queue |
| Input validation | None — raw JSON | Anti-corruption layer with schema validation |
| Translation | Ad-hoc | Structured translate function with typed input/output |
| Error handling | Lambda error | Structured error response to caller |
| Observability | CloudWatch only | QueryDb audit log of all translations |

### Spec Definition

```rescript
// reventless/reventless-spec/src/components/InboundTranslationSlice.res

module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec

  /** The external input type — what the external system sends. */
  @schema type externalInput

  /** The command type to produce after translation. Published to the shared DCB CommandTopic;
      routing to the correct StateChangeSlice happens automatically via command variant type names. */
  @schema type command

  /**
  Translate: validate and transform external input into a domain command.
  This is the anti-corruption layer. Returns `Ok((targetId, command))` on success,
  or `Error(string)` with a human-readable error message on validation failure.
  */
  let translate: externalInput => result<(string, command), string>
}
```

### Component Structure

```
reventless/reventless-spec/src/components/
  └── InboundTranslationSlice.res          # Spec module type

reventless/reventless-core/src/components/InboundTranslationSlice/
  ├── InboundTranslationSlice.res          # Type definitions
  ├── InboundTranslationSlice_Builder.res  # Factory: endpoint + CommandTopic wiring
  └── InboundTranslationSlice_Callback.res # Runtime handler
```

### Type Definitions

```rescript
// reventless/reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice.res

let componentType = ComponentType.InboundTranslationSlice

type t
type outputs = {
  resources: array<ReventlessInfra.Adapter.resource>,
  queryDb: QueryDb.outputs,    // Audit log of all translations
}

type operations = {
  /** Accept external input, translate, and publish command. */
  receive: JSON.t => promise<result<string, string>>,
}

type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.InboundTranslationSlice.Spec
  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
```

### Builder

1. Creates a **QueryDb** for audit log storage (records all inbound translations)
2. Wires the `receive` operation:
   - Parses input JSON against `Spec.externalInput` schema
   - Calls `Spec.translate` → anti-corruption layer
   - On success: publishes command via `publishJsons`, records success in audit log
   - On failure: records failure in audit log, returns error

### Callback (Runtime Handler)

```
receive(inputJson):
  // 1. Parse external input
  match S.parseJson(inputJson, Spec.externalInputSchema):
    Error(_) → return Error("Invalid input format")
    Ok(input) →
      // 2. Translate (anti-corruption layer)
      match Spec.translate(input):
        Error(msg) →
          insert audit row {status: "rejected", error: msg, ...}
          return Error(msg)
        Ok((targetId, command)) →
          // 3. Publish command
          publishJsons(Spec.targetName, meta, commandJson)
          insert audit row {status: "accepted", targetId, ...}
          return Ok(targetId)
```

### Integration: API Endpoint

The InboundTranslationSlice needs an HTTP endpoint. Options:

**Option A — GraphQL Mutation** (preferred, consistent with existing Api component):
Register a GraphQL mutation in the Api schema fragment. The mutation resolver calls
`operations.receive(inputJson)`.

**Option B — Direct Lambda URL / API Gateway**:
For webhooks that need a stable URL independent of GraphQL (e.g., payment provider callbacks).
The AWS adapter creates a Lambda Function URL or API Gateway endpoint.

Both options can coexist — the component exposes `operations.receive` and the adapter
decides the transport.

---

## Integration into Plugin & Platform

### Plugin.DcbSpec Extension

Add both slice types to DcbSpec (combined with AutomationSlice changes):

```rescript
module type DcbSpec = {
  @schema type event

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
  let automationSlices: array<module(AutomationSlice.T with type dcbEvent = event)>
  let outboundTranslationSlices: array<module(OutboundTranslationSlice.T with type dcbEvent = event)>
  let inboundTranslationSlices: array<module(InboundTranslationSlice.T with type dcbEvent = event)>
}
```

### Platform.T Extension

```rescript
module OutboundTranslationSlice: {
  module Make: (Spec: Reventless.OutboundTranslationSlice.Spec) => OutboundTranslationSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec
}

module InboundTranslationSlice: {
  module Make: (Spec: Reventless.InboundTranslationSlice.Spec) => InboundTranslationSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
}
```

---

## Implementation Steps

### Step 1: Add ComponentTypes [DONE]

Add `OutboundTranslationSlice` and `InboundTranslationSlice` to the `ComponentType` enum.

### Step 2: Create Specs [DONE]

Create both spec files in `reventless-spec/src/components/`:
- `OutboundTranslationSlice.res`
- `InboundTranslationSlice.res`

### Step 3: Create OutboundTranslationSlice Core Component [DONE]

Create files under `reventless-core/src/components/OutboundTranslationSlice/`:
- `OutboundTranslationSlice.res` — type definitions
- `OutboundTranslationSlice_Builder.res` — factory (EventCollector + QueryDb)
- `OutboundTranslationSlice_Callback.res` — collect + translate handler

### Step 4: Create InboundTranslationSlice Core Component [DONE]

Create files under `reventless-core/src/components/InboundTranslationSlice/`:
- `InboundTranslationSlice.res` — type definitions
- `InboundTranslationSlice_Builder.res` — factory (QueryDb audit log + publishJsons)
- `InboundTranslationSlice_Callback.res` — receive + translate handler

### Step 5: Extend DcbSpec [DONE]

Add `outboundTranslationSlices` and `inboundTranslationSlices` fields to `Plugin.DcbSpec`.
This is a **breaking change** — existing DcbSpec definitions need empty arrays added.
Coordinate with AutomationSlice plan to make all DcbSpec changes together.

### Step 6: Extend Plugin_Builder [DONE]

Wire both TranslationSlice types in `Plugin_Builder.res` DCB handling block:
- OutboundTranslationSlice: connect to DcbEventLog EventTopic (same as StateViewSlice)
  + pass shared CommandTopic `publishJsons` for optional command-back publishing
- InboundTranslationSlice: connect to shared CommandTopic publishJsons

### Step 7: Extend Platform.T [DONE]

Add both factory modules to `Platform.T` module type.

### Step 8: Implement In-Memory Platform [DONE]

Add both to `reventless-in-memory/src/Platform.res`:
- OutboundTranslationSlice: uses in-memory QueryDb + EventCollector
- InboundTranslationSlice: uses in-memory QueryDb, exposes `receive` operation directly

### Step 9: Implement AWS Platform [DONE]

Add both to `reventless-aws/src/Platform.res`:
- OutboundTranslationSlice: DynamoDB QueryDb + SQS EventCollector
- InboundTranslationSlice: DynamoDB audit QueryDb + Lambda endpoint (Function URL or
  API Gateway for webhooks, GraphQL mutation for API-driven ingestion)

### Step 10: Update Example Plugins [DONE]

Add empty arrays to existing DcbSpec definitions:
```rescript
let outboundTranslationSlices = []
let inboundTranslationSlices = []
```

### Step 11: Create E2E Tests [DONE]

**OutboundTranslationSlice callback tests (11 tests):**
- Phase 1 collect: creates pending items, idempotent dedup, multiple events, irrelevant events
- Phase 2 translate (fire-and-forget): Ok(None) marks Completed, no command published
- Phase 2 translate (command-back): Ok(Some) publishes command, Error increments retryCount,
  retry within maxRetries, stop after maxRetries, individual item failure isolation

**InboundTranslationSlice callback tests (4 tests):**
- Valid input with successful translate publishes command and returns Ok
- Translate returns Error: no command published, audit logged
- Invalid JSON input: returns Error, audit logged
- publishJsons failure: returns Error, audit logged

### Step 12: Documentation [DONE]

Add to Docusaurus site:
- `docs/reventless-components/outbound-translation-slice.md`
- `docs/reventless-components/inbound-translation-slice.md`
- Update component overview diagram
- Add examples for common integration patterns (webhook, email, payment gateway)

---

## Dependency on AutomationSlice Plan

Both plans modify `Plugin.DcbSpec`. To avoid two breaking changes:

1. Implement **Step 5** (DcbSpec extension) from both plans in a single commit
2. Add all new fields at once: `automationSlices`, `outboundTranslationSlices`,
   `inboundTranslationSlices`
3. Update all existing DcbSpec definitions in one pass

### Recommended Implementation Order

1. AutomationSlice (Steps 1-4) — establishes the TODO list pattern
2. OutboundTranslationSlice (Steps 1-4) — reuses the TODO list pattern from AutomationSlice
3. Combined DcbSpec + Plugin_Builder + Platform.T changes (Steps 5-9 from both plans)
4. InboundTranslationSlice (Steps 1-4) — independent from TODO list
5. Example updates + E2E tests + docs (Steps 10-12 from both plans)

This ordering minimizes rework and allows the TODO list infrastructure (QueryDb-based
status tracking) to be shared between AutomationSlice and OutboundTranslationSlice.

# Plan: AutomationSlice Component

Implements the Event Modeling **Automation Slice** (TODO List Pattern) as a first-class
Reventless component. See `docs/analysis/event-modeling-comparison.md` Section 7.1.

## Motivation

Event Modeling's automation pattern:
```
Event(s) → TODO List (read model) → Processor → Command → Event(s)
```

Reventless today has `EventMapper` which is a **stateless** event-to-command bridge — it maps
each incoming event directly to commands without tracking what has been processed. This means:

- No idempotency guarantee (replays cause duplicate commands)
- No visibility into what is pending vs completed
- No retry semantics for individual work items
- No completion tracking across restarts

The AutomationSlice introduces a **stateful** TODO list that accumulates pending work items
from events, and a processor that works through them exactly once, issuing commands and marking
items done.

## Design

### Conceptual Model

```
DcbEventLog events
    ↓ (subscribe via EventTopic)
AutomationSlice TODO List (QueryDb)
    ↓ (processor reads pending items)
Processor (user-defined logic)
    ↓ (issues commands)
CommandTopic (target aggregate)
    ↓ (command produces events)
DcbEventLog events
    ↓ (completion event marks TODO item done)
AutomationSlice TODO List (item removed/completed)
```

### Architecture Decision: DCB-Based vs Aggregate-Based

The AutomationSlice operates on DCB events (shared `DcbEventLog`), following the same pattern
as `StateChangeSlice` and `StateViewSlice`. This is the natural fit because:

1. Automations react to the same events that StateChangeSlices produce
2. The TODO list state can be derived from events in the shared log
3. Completion events go back into the same log, closing the loop
4. The Plugin's `DcbSpec` already groups all slice types together

### Spec Definition

The AutomationSlice combines aspects of both StateViewSlice (event projection into TODO list)
and StateChangeSlice (command emission). The spec defines:

1. **What to collect** — which events create TODO items (`collect` function)
2. **What to do** — what command to issue for each TODO item (`process` function)
3. **What completes it** — which events mark a TODO item as done (`resolve` function)

```rescript
// reventless/reventless-spec/src/components/AutomationSlice.res

module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec

  /** The TODO item state — what data is accumulated for each pending work item. */
  @schema type todoItem

  /** The command type produced by the processor. Published to the shared DCB CommandTopic;
      routing to the correct StateChangeSlice happens automatically via command variant type names. */
  @schema type command

  /**
  Collect: map an incoming event to zero or more new TODO items.
  Each item has an `id` (deduplication key) and the `todoItem` payload.
  Returns empty array if this event is not relevant.
  */
  let collect: DcbEventLogSpec.event => array<(string, todoItem)>

  /**
  Resolve: check if an incoming event completes a pending TODO item.
  Returns `Some(todoItemId)` if the event marks the item as done, `None` otherwise.
  */
  let resolve: DcbEventLogSpec.event => option<string>

  /**
  Process: given a pending TODO item, produce a command.
  The processor calls this for each pending item. Returns the target ID and command.
  May return `None` to skip processing (e.g., wait for more data).
  */
  let process: (string, todoItem) => option<(string, command)>

  /** Maximum number of retries for a failed processing attempt. Default: 3. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. Default: 60. */
  let heartbeatInterval: int
}
```

### TODO List Storage

The TODO list is stored in a **QueryDb** (same pattern as StateViewSlice). Each row represents
a pending work item:

```rescript
type todoStatus =
  | Pending
  | Processing
  | Completed
  | Failed

type todoRow = {
  id: string,             // Deduplication key (from collect)
  item: JSON.t,           // Serialized todoItem
  status: todoStatus,
  createdAt: string,      // ISO timestamp
  processedAt?: string,   // When processing started
  completedAt?: string,   // When resolved
  retryCount: int,        // Number of processing attempts
}
```

### Component Structure

Following the established Reventless component pattern:

```
reventless/reventless-spec/src/components/
  └── AutomationSlice.res              # Spec module type

reventless/reventless-core/src/components/AutomationSlice/
  ├── AutomationSlice.res              # Type definitions (componentType, outputs, operations)
  ├── AutomationSlice_Builder.res      # Factory: wires EventCollector + QueryDb + Processor
  └── AutomationSlice_Callback.res     # Runtime: collect/resolve/process logic

reventless/reventless-in-memory/src/adapter/AutomationSlice/
  └── (uses existing QueryDb + EventCollector in-memory adapters)

reventless/reventless-aws/src/components/
  └── (uses existing QueryDb + EventCollector AWS adapters)
```

### Type Definitions

```rescript
// reventless/reventless-core/src/components/AutomationSlice/AutomationSlice.res

let componentType = ComponentType.AutomationSlice

type t
type outputs = {
  resources: array<ReventlessInfra.Adapter.resource>,
  queryDb: QueryDb.outputs,
}

type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  /** Manually trigger Phase 2 (useful in tests and for the Heartbeat handler). */
  processPending: unit => promise<unit>,
}

type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.AutomationSlice.Spec
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

The builder follows StateViewSlice's pattern but adds command publishing and scheduled
processing:

1. Creates a **QueryDb** for TODO list storage
2. Creates an **EventCollector** subscribed to the DcbEventLog's EventTopic
3. Wires an **event handler** that runs Phase 1 (collect/resolve) + Phase 2 (process)
4. Wires a **Heartbeat handler** that periodically runs Phase 2 only (sweep for
   pending/failed items that need processing or retry)
5. Sets operations (enqueueEvent + processPending for testing)
6. Sets outputs (resources + queryDb)

### Callback (Runtime Handler)

The callback has two entry points that share Phase 2 logic:

#### Entry Point A — Event Handler (triggered by EventCollector)

Runs Phase 1 then Phase 2:

**Phase 1 — Update TODO list** (for each event in the batch):
```
for each event:
  for each (id, item) in Spec.collect(event):
    if not exists in QueryDb:
      insert {id, item, status: Pending, ...}
  match Spec.resolve(event):
    Some(id) → update status to Completed, set completedAt
    None → skip
```

**Phase 2 — Process pending items** (shared logic):
```
read all rows where status = Pending
  OR (status = Failed AND retryCount < maxRetries)
for each row:
  update status to Processing
  match Spec.process(row.id, row.item):
    Some(targetId, command) →
      publish command to CommandTopic via publishJsons
      // Item stays Processing until resolve event arrives
    None → revert status to Pending
```

#### Entry Point B — Heartbeat Handler (triggered by Scheduler/Heartbeat)

Runs Phase 2 only. This catches:
- Items collected in a previous batch that were skipped by `process` (returned `None`)
- Failed items eligible for retry (`retryCount < maxRetries`)
- Items stuck in `Processing` beyond a timeout (reset to `Pending` for reprocessing)

The heartbeat interval is configurable in the spec (default: 60 seconds).

### Integration into Plugin & Platform

#### Plugin.DcbSpec Extension

Add `automationSlices` to the DcbSpec:

```rescript
// reventless/reventless-core/src/components/Plugin/Plugin.res
module type DcbSpec = {
  @schema type event

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
  let automationSlices: array<module(AutomationSlice.T with type dcbEvent = event)>
}
```

#### Platform.T Extension

Add AutomationSlice factory:

```rescript
// reventless/reventless-infra/src/types/Platform.res
module AutomationSlice: {
  module Make: (Spec: Reventless.AutomationSlice.Spec) => AutomationSlice.T
    with type dcbEvent = Spec.DcbEventLogSpec.event
    and module Spec = Spec
}
```

#### Plugin_Builder Changes

Wire AutomationSlice components in the same block as StateChangeSlice and StateViewSlice:

```rescript
// In the dcbSpec handling block, after stateViewSlices:
let automationSlicesOutputs =
  DcbSpec.automationSlices
  ->Array.map((module(AS: AutomationSlice.T with type dcbEvent = DcbSpec.event)) => {
    let as_ = AS.make(~dcbEventLog, ~publishJsons, ~opts)
    (AS.Spec.name, as_->Component.outputs)
  })
  ->Dict.fromArray
```

---

## Implementation Steps

### Step 1: Add ComponentType ✅

Add `AutomationSlice` to the `ComponentType` enum in `reventless-core`.

### Step 2: Create Spec ✅

Create `reventless/reventless-spec/src/components/AutomationSlice.res` with the `Spec` module
type as designed above.

### Step 3: Create Core Component ✅

Create the files under `reventless-core/src/components/AutomationSlice/`:
- `AutomationSlice.res` — type definitions
- `AutomationSlice_Builder.res` — factory following StateViewSlice pattern + publishJsons
- `AutomationSlice_Callback.res` — runtime handler with collect/resolve/process phases

Plus infra-level types:
- `reventless-infra/src/components/AutomationSlice.res` — outputs/operations/T types

### Step 4: Extend DcbSpec ✅

Add `automationSlices` field to `Plugin.DcbSpec` module type (both infra and core). This is a
**breaking change** for all existing DcbSpec definitions — they need to add
`let automationSlices = []`.

### Step 5: Extend Plugin_Builder ✅

Wire AutomationSlice components in `Plugin_Builder.res` DCB handling block, connecting them to
the shared DcbEventLog and CommandTopic.

### Step 6: Extend Platform.T ✅

Add `module AutomationSlice` factory to `Platform.T` module type.

### Step 7: Implement In-Memory Platform ✅

Add AutomationSlice to `reventless-in-memory/src/Platform.res` using existing in-memory
QueryDb and EventCollector adapters.
- Created `reventless-in-memory/src/components/AutomationSlice_Builder.res`

### Step 8: Implement AWS Platform ✅

Add AutomationSlice to `reventless-aws/src/Platform.res` using existing AWS adapters.
- Created `reventless-aws/src/components/AutomationSlice_Builder.res`

### Step 9: Update Example Plugins ✅

Add `let automationSlices = []` to existing DcbSpec definitions in `examples/dcb/`:
- `examples/dcb/catalog/src/Plugin/CatalogPlugin.res`
- `examples/dcb/ordering/src/Plugin/OrderingPlugin.res`

### Step 10: Create E2E Test ✅

Created unit tests in `reventless-in-memory/tests/components/automationslice/`:
- `AutomationSliceFixtures.res` — test specs (ShipOrder, SkipProcess)
- `AutomationSliceCallbackTest.res` — 13 tests covering all phases

Verifies:
- TODO items are created from events (idempotent — duplicates are skipped)
- Commands are published for pending items
- Items are marked completed when resolve events arrive
- Items where process returns None are skipped
- Publishing failures mark items as Failed with retry support
- Full lifecycle: collect → process → resolve

### Step 11: Documentation ✅

Added `packages/doc/docs-app/components/automationslice.md` to the Docusaurus site covering:
- Event Modeling automation pattern
- TODO List Pattern explanation
- AutomationSlice spec API reference (collect/resolve/process)
- Example usage with ShipOrder code
- Comparison with EventMapper (when to use which)
- Runtime behavior with two-phase processing sequence diagram
- TODO item lifecycle diagram
- Error handling and retry semantics

Also updated:
- `packages/doc/docs-app/component-overview.md` — added AutomationSlice section + updated DCB diagram with automation row
- `packages/doc/sidebars-app.js` — added `components/automationslice` entry
- `packages/doc/d2/reventless.d2` — added `automation-slice` and `automation-slices-area` D2 classes

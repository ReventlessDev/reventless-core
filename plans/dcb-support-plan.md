# Plan: DCB (Dynamic Consistency Boundary) Support for Reventless

## Implementation Status

### Part 1: Generic Components — COMPLETED

| Step | Status | Notes |
|------|--------|-------|
| ComponentType additions | Done | Added `DcbEventLog` and `CommandHandler` to `ComponentType.res` |
| DcbTag module | Done | Tag types, sury metadata, `extractTags` utility |
| DcbEventLog component (4 files) | Done | Types, Adapter, Operations, Builder |
| CommandHandler component (3 files) | Done | Types, Callback, Builder |
| Build verification | Done | All 196 modules compile |
| Regression tests | Done | All 49 existing tests pass |

### Part 2: DynamoDB Adapter — NOT STARTED

| Step | Status | Notes |
|------|--------|-------|
| DcbEventLogStorage_DynamoDb.res | Pending | Deploy-time: DynamoDB table + GSI |
| DcbEventLogStorage_DynamoDb_Runtime.res | Pending | Runtime: read + conditional append |

### Verification Tests — NOT STARTED

| Step | Status | Notes |
|------|--------|-------|
| DcbTag.extractTags unit tests | Pending | |
| DcbEventLog operations unit tests | Pending | |
| CommandHandler_Callback unit tests | Pending | |
| Integration test (in-memory adapter) | Pending | |

---

## Deviations from Original Plan

1. **ComponentType location**: The plan referenced `packages/reventless-spec/src/adapter/Adapter.res` for ComponentType, but it actually lives in `packages/reventless/src/ComponentType.res`. No spec-level change was needed.

2. **`rescript.json` unchanged**: The existing `"dir": "src", "subdirs": true` config automatically picks up new subdirectories. No modification needed.

3. **`toUnknownSchema` cast**: `DcbTag.extractTags` uses `external toUnknownSchema: S.t<'a> => S.t<unknown> = "%identity"` to cast schemas for pattern matching on sury's private variant types. The plan's `(schema :> S.t<unknown>)` coercion doesn't work with private variants.

4. **CommandHandler Builder takes `~dcbEventLog` component instance**: The plan described `CommandTopicPublisher: CommandTopic_Adapter.Publisher` as a functor parameter, but the codebase uses `CommandTopic_Adapter.Channel` for CommandTopics. The Builder now takes:
   ```rescript
   module Make = (
     Spec: CommandHandler.Spec,
     DcbEventLog: DcbEventLog.T with module Spec = Spec.DcbEventLog,
     CommandTopicChannel: CommandTopic_Adapter.Channel,
   )
   ```
   And `make` takes `~dcbEventLog: DcbEventLog.component` as a value parameter so the DcbEventLog is truly shared across CommandHandlers.

5. **CommandHandler.T includes `DcbEventLogModule`**: The module type exposes the DcbEventLog module for typing the `~dcbEventLog` parameter:
   ```rescript
   module type T = {
     module Spec: Spec
     module DcbEventLogModule: DcbEventLog.T with module Spec = Spec.DcbEventLog
     let make: (~dcbEventLog: DcbEventLogModule.component, ~opts: ...) => component
   }
   ```

6. **Module sealing removed for Spec modules**: `CommandTopicSpec` and `EventTopicSpec` created inside builders are NOT sealed with `: CommandTopic.Spec` / `: EventTopic.Spec` to keep Id types transparent and unifiable across module boundaries.

---

## Context

The current EventLog uses a **stream-per-aggregate** model: events are partitioned by aggregate ID, with optimistic concurrency via sequence numbers. This works well for single-aggregate consistency but cannot enforce invariants that span multiple aggregates or require dynamic boundaries.

**DCB** (https://dcb.events/specification) replaces rigid aggregate boundaries with a query-based approach: events carry **tags** (key-value labels), consistency is enforced via **conditional appends** (fail if events matching a query exist after a known position), and boundaries are determined dynamically at query time.

**Goal**: Add DCB support as **new components alongside** the existing Aggregate + EventLog (which remain unchanged). Two new components:
1. **DcbEventLog** — a typed event store per bounded context, storing all events with tags and global sequence positions
2. **CommandHandler** — the DCB counterpart to Aggregate, using reducers + deciders instead of init/apply/execute

---

## Architecture: Current vs DCB (Side-by-Side)

```
CURRENT (unchanged)                     NEW (DCB)
─────────────────────                   ──────────────────────
EventLog (per aggregate type)           DcbEventLog (per bounded context)
  - typed, per-aggregate event type       - typed, union of ALL event types
  - partitioned by aggregate ID           - single stream, events tagged
  - replay(id) → events                  - read(query) → sequenced events
  - append(seqNr, id, events)            - append(events, ~condition?)
  - Operations encode/decode JSON         - Operations encode/decode JSON

Aggregate                               CommandHandler
  - Behavior: init/apply/execute          - Spec: reduce/decide
  - one EventLog per aggregate            - shared DcbEventLog
  - concurrency via sequenceNr            - concurrency via conditional append
```

---

## Part 1: Generic Components (`packages/reventless`)

### 1.1 DcbTag Module (new)

**File**: `packages/reventless/src/components/DcbTag.res`

Core tag types and sury-based tag extraction utility.

```rescript
// --- Tag types ---
type tag = {key: string, value: string}

type queryItem = {
  eventTypes?: array<string>,  // match if event type is one of these
  tags?: array<tag>,           // match if ALL these tags present
}

type query = array<queryItem>  // OR of queryItems

type sequencePosition = string // global, monotonically increasing, store-assigned

type appendCondition = {
  query: query,
  after?: sequencePosition,   // if omitted, check entire history
}

// --- Sury metadata for tag annotation ---
// Uses sury's public S.Metadata API (S.resi line 491-500)

let dcbTagId: S.Metadata.Id.t<bool> =
  S.Metadata.Id.make(~namespace="dcb", ~name="tag")

// Tagged schema helpers — used with @s.matches in event/command types
let string: S.t<string>   // S.string with dcbTag metadata set
let int: S.t<int>         // S.int with dcbTag metadata set
// (extend as needed for other tag value types)

// --- Tag extraction from sury schemas ---
let extractTags: (S.t<'a>, 'a) => array<tag>
```

**How `extractTags` works at runtime**:
1. Convert value to JSON via `S.reverseConvertToJsonOrThrow(schema)`
2. Pattern-match schema: `Union({anyOf})` → find matching variant; `Object({properties})` → direct
3. For each field in `properties: dict<t<unknown>>`, check `S.Metadata.get(fieldSchema, ~id=dcbTagId)`
4. For tagged fields, extract value from JSON dict → `{key: fieldName, value: stringValue}`

### 1.2 DcbEventLog Component (new)

Following the existing component structure pattern. **The DcbEventLog is typed** — it receives domain events and handles JSON serialization internally (same pattern as current EventLog).

#### `DcbEventLog.res` — Types and Spec

**File**: `packages/reventless/src/components/DcbEventLog/DcbEventLog.res`

```rescript
let componentType = ComponentType.DcbEventLog

type outputs = {resources: array<resource>, eventTopic: EventTopic.outputs}
type t
type component<'operations> = Component.t<t, outputs, 'operations>

// Sequenced event (returned from read, with store-assigned position)
type sequencedEvent<'event> = {
  position: DcbTag.sequencePosition,
  event: 'event,
  tags: array<DcbTag.tag>,
}

type readResult<'event> = {
  events: array<sequencedEvent<'event>>,
  headPosition?: DcbTag.sequencePosition,
}

// Typed operations (domain-level)
type read<'event> = (
  ~query: DcbTag.query,
  ~after: DcbTag.sequencePosition=?,
) => promise<readResult<'event>>

type append<'event> = (
  array<'event>,
  ~condition: DcbTag.appendCondition=?,
) => promise<result<DcbTag.sequencePosition, string>>

// Spec — typed with event union for the bounded context
module type Spec = {
  let name: string
  @schema type event   // union of ALL event types in bounded context
}

module type T = {
  module Spec: Spec
  type operations = {
    read: read<Spec.event>,
    append: append<Spec.event>,
  }
  type component = component<operations>
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
```

**Key design**: The `Spec.event` is a union of ALL event types in the bounded context. Example:

```rescript
module MyBoundedContextEvents: DcbEventLog.Spec = {
  let name = "enrollment"

  @schema
  type event =
    | StudentEnrolled({
        courseId: @s.matches(DcbTag.string) string,
        studentId: @s.matches(DcbTag.string) string,
      })
    | CourseCreated({
        courseId: @s.matches(DcbTag.string) string,
        capacity: int,
      })
    | InstructorAssigned({
        courseId: @s.matches(DcbTag.string) string,
        instructorId: @s.matches(DcbTag.string) string,
      })
}
```

#### `DcbEventLog_Adapter.res` — Storage interface (JSON level)

**File**: `packages/reventless/src/components/DcbEventLog/DcbEventLog_Adapter.res`

```rescript
// Raw types for adapter (untyped — JSON level)
type rawStoredEvent = {
  eventType: string,
  data: JSON.t,
  tags: array<DcbTag.tag>,
}

type rawSequencedEvent = {
  position: DcbTag.sequencePosition,
  eventType: string,
  data: JSON.t,
  tags: array<DcbTag.tag>,
}

type rawReadResult = {
  events: array<rawSequencedEvent>,
  headPosition?: DcbTag.sequencePosition,
}

type operations = {
  read: (
    ~query: DcbTag.query,
    ~after: DcbTag.sequencePosition=?,
  ) => promise<rawReadResult>,
  append: (
    array<rawStoredEvent>,
    ~condition: DcbTag.appendCondition=?,
  ) => promise<result<DcbTag.sequencePosition, string>>,
}

type storage = {
  resources: array<ReventlessSpec.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}

type storageMaker = (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage

module type Storage = {
  let make: storageMaker
}
```

#### `DcbEventLog_Operations.res` — Runtime logic (encode/decode)

**File**: `packages/reventless/src/components/DcbEventLog/DcbEventLog_Operations.res`

Mirrors `EventLog_Operations.res` pattern:

- **`append`**: Takes typed `Spec.event` array →
  1. Encode each event to JSON via `Spec.eventSchema`
  2. Extract event type name (TAG field from sury variant encoding, reuse `Message.splitMessage`)
  3. Extract tags via `DcbTag.extractTags(Spec.eventSchema, event)`
  4. Build `rawStoredEvent` records
  5. Pass to storage adapter with condition
  6. On success, publish to EventTopic

- **`read`**: Takes query →
  1. Delegate to storage adapter → `rawReadResult`
  2. Decode each `rawSequencedEvent` JSON back to `Spec.event` (reuse `Message.combineMessage` + `S.parseJsonOrThrow`)
  3. Return typed `readResult<Spec.event>`

#### `DcbEventLog_Builder.res` — Factory

**File**: `packages/reventless/src/components/DcbEventLog/DcbEventLog_Builder.res`

Same pattern as `EventLog_Builder.res`:

```rescript
module Make = (
  Spec: DcbEventLog.Spec,
  Storage: DcbEventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
): (DcbEventLog.T with module Spec = Spec)
```

Creates storage + EventTopic, wires up operations.

### 1.3 CommandHandler Component (new)

The DCB counterpart to Aggregate. Uses **reducers** (build decision model from events) and **deciders** (produce events from decision model + command).

#### `CommandHandler.res` — Types and Spec

**File**: `packages/reventless/src/components/CommandHandler/CommandHandler.res`

```rescript
let componentType = ComponentType.CommandHandler

module type Spec = {
  let name: string

  // Reference to the shared DcbEventLog's Spec
  module DcbEventLog: DcbEventLog.Spec

  // Command type (received from CommandTopic)
  @schema type command

  // Error type
  @schema type error

  // Decision model — built by reducing queried events
  type decisionModel
  let initialDecisionModel: decisionModel

  // Reducer: fold events into the decision model
  // Uses DcbEventLog.event (the full bounded context event union)
  // — handle relevant variants, ignore others
  let reduce: (decisionModel, DcbEventLog.event) => decisionModel

  // Decider: given decision model + command, produce events or error
  let decide: (decisionModel, command) => result<array<DcbEventLog.event>, error>

  // Which event types to include in the query (variant names)
  let queryEventTypes: array<string>
}
```

**Tag extraction is automatic**: The CommandHandler uses `DcbTag.extractTags` with sury schemas to derive tags from commands and events. No manual `tagsOf` function needed.

**Query event types**: Specified as `array<string>` matching variant names (e.g., `["StudentEnrolled", "CourseCreated"]`). These filter the DCB query to only relevant events.

#### `CommandHandler_Callback.res` — Core DCB logic

**File**: `packages/reventless/src/components/CommandHandler/CommandHandler_Callback.res`

```
Flow per command:

1. Extract tags from command:
   tags = DcbTag.extractTags(Spec.commandSchema, command)

2. Build query:
   query = [{eventTypes: Spec.queryEventTypes, tags}]

3. Read from DcbEventLog:
   {events, headPosition} = dcbEventLog.read(~query)

4. Build decision model:
   decisionModel = events
     |> Array.map(se => se.event)
     |> Array.reduce(Spec.initialDecisionModel, Spec.reduce)

5. Decide:
   result = Spec.decide(decisionModel, command)

6. On Ok(newEvents):
   a. Conditional append:
      dcbEventLog.append(newEvents, ~condition={query, after: headPosition})
   b. On conflict (Error): retry from step 3 (up to 3 retries)

7. On Error(error): log and handle error
```

Note: Tags for new events are extracted automatically by DcbEventLog_Operations during append (step 6a) — the CommandHandler just passes typed events.

#### `CommandHandler_Builder.res` — Factory

**File**: `packages/reventless/src/components/CommandHandler/CommandHandler_Builder.res`

```rescript
module Make = (
  Spec: CommandHandler.Spec,
  DcbEventLog: DcbEventLog.T with module Spec = Spec.DcbEventLog,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
): CommandHandler.T
```

**Key**: The DcbEventLog is **passed in** (shared across CommandHandlers), not created by the CommandHandler. The CommandHandler creates its own CommandTopic for receiving commands.

---

## Part 2: DynamoDB Adapter (`packages/reventless-aws`) — Separate Step

Included here as a sketch for the adapter interface designed in Part 1. Detailed design planned separately.

### Storage Model (Sketch)

**Events Table**:
- Partition key: `pk` (string) — bounded context name or partition strategy
- Sort key: `position` (string) — global sequence position (auto-assigned)
- Attributes: `eventType`, `data` (JSON), `tags` (list of maps)

**Tags GSI** (Global Secondary Index for querying by tag):
- Partition key: `tagKey#tagValue` (composite string, e.g., `courseId#c123`)
- Sort key: `position`
- Enables efficient query: "all events with tag courseId=c123 after position X"

**Conditional Append**:
- Use DynamoDB transactions or conditional writes
- Check that no events matching the query exist after the specified position

### Files (Sketch)

```
packages/reventless-aws/src/adapter/DcbEventLog/
  DcbEventLogStorage_DynamoDb.res          # Deploy-time: DynamoDB table + GSI
  DcbEventLogStorage_DynamoDb_Runtime.res  # Runtime: read + conditional append
```

---

## Tag Annotation Proposal

### Current Approach: `@s.matches` + `S.Metadata` (works with sury 11.0.0-alpha.4)

sury's public `S.Metadata` API (`S.resi` line 491-500) allows custom metadata on schemas:

```rescript
// In DcbTag.res:
let dcbTagId = S.Metadata.Id.make(~namespace="dcb", ~name="tag")
let string = S.string->S.Metadata.set(~id=dcbTagId, true)
let int = S.int->S.Metadata.set(~id=dcbTagId, true)
```

Domain developers annotate tag fields using `@s.matches`:

```rescript
@schema
type event =
  | StudentEnrolled({
      courseId: @s.matches(DcbTag.string) string,
      studentId: @s.matches(DcbTag.string) string,
      enrollmentDate: string,
    })

@schema
type command =
  | EnrollStudent({
      courseId: @s.matches(DcbTag.string) string,
      studentId: @s.matches(DcbTag.string) string,
  })
```

At runtime, `DcbTag.extractTags` introspects the schema:
1. `Union({anyOf})` → iterate variant schemas to find the matching one
2. `Object({properties})` → iterate `properties: dict<t<unknown>>`
3. For each property: `S.Metadata.get(fieldSchema, ~id=dcbTagId)` → `Some(true)` if tagged
4. Extract tagged field values from JSON representation → `{key: fieldName, value: fieldValue}`

### Future Enhancement: `@s.tag` PPX (requires sury-ppx extension)

Propose adding a `@s.tag` PPX annotation to sury that auto-marks fields with DCB metadata:

```rescript
@schema
type event =
  | StudentEnrolled({
      @s.tag courseId: string,
      @s.tag studentId: string,
      enrollmentDate: string,
    })
```

---

## Files Summary

### New files in `packages/reventless/src/components/`:

| File | Purpose |
|------|---------|
| `DcbTag.res` | Tag types, sury metadata ID, `extractTags` utility |
| `DcbEventLog/DcbEventLog.res` | Typed DCB EventLog: types, Spec, module types |
| `DcbEventLog/DcbEventLog_Adapter.res` | Storage adapter interface (JSON level) |
| `DcbEventLog/DcbEventLog_Operations.res` | Runtime: encode/decode events, delegate to adapter, publish to EventTopic |
| `DcbEventLog/DcbEventLog_Builder.res` | Factory: creates storage + EventTopic, wires operations |
| `CommandHandler/CommandHandler.res` | CommandHandler types, Spec (reduce/decide), module types |
| `CommandHandler/CommandHandler_Callback.res` | Core DCB flow: extract tags → read → reduce → decide → conditional append |
| `CommandHandler/CommandHandler_Builder.res` | Factory: takes shared DcbEventLog, creates CommandTopic |

### New files in `packages/reventless-aws/src/adapter/` (Part 2, later):

| File | Purpose |
|------|---------|
| `DcbEventLog/DcbEventLogStorage_DynamoDb.res` | Deploy-time: DynamoDB table + GSI creation |
| `DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` | Runtime: read (query by tags) + conditional append |

### Existing files modified:

| File | Change |
|------|--------|
| `packages/reventless/src/ComponentType.res` | Added `DcbEventLog` and `CommandHandler` variants |

### Existing code reused:

| What | Where |
|------|-------|
| `Component.t`, `Component.make` | `packages/reventless/src/components/Component.res` |
| `CommandTopic`, `CommandTopic_Adapter` | `packages/reventless/src/components/CommandTopic/` |
| `EventTopic`, `EventTopic_Builder` | `packages/reventless/src/components/EventTopic/` |
| `Message.splitMessage`, `Message.combineMessage` | `packages/reventless/src/Message.res` — for event type extraction and JSON encoding |
| `Message.meta`, `Message.generateMeta` | `packages/reventless/src/Message.res` — event metadata |
| `S.Metadata.Id.make`, `S.Metadata.set`, `S.Metadata.get` | sury public API — tag annotation |

---

## Verification

1. **Unit tests for `DcbTag.extractTags`**: Create test events with `@s.matches(DcbTag.string)` fields, verify tags are correctly extracted from both simple records and variant types
2. **Unit tests for DcbEventLog operations**: Mock storage adapter, test read/append/conditional-append encode/decode round-trip
3. **Unit tests for CommandHandler_Callback**: Mock DcbEventLog, verify full flow (extract tags → query → reduce → decide → conditional append with retry on conflict)
4. **Integration test**: Wire up CommandHandler + DcbEventLog with an in-memory adapter, process commands end-to-end
5. **Build**: `npm run build` from repo root — all packages compile without errors
6. **Existing tests pass**: `npm run test` — no regressions in existing Aggregate/EventLog

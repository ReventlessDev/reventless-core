# StateViewSlice In-Memory Implementation Plan

## Status: DONE

## Goal

Fully implement `StateViewSlice` in `reventless-in-memory` with E2E tests. StateViewSlice is a DCB read-side projection component that:
- Subscribes to a `DcbEventLog`'s event topic
- Projects each event into a `QueryDb` via `Spec.project`
- Exposes `{enqueueEvent}` as its operations

## Current State

All files are placeholders:
- **Core** `StateViewSlice_Builder.Make(Spec)` — sets empty `queryDb` outputs and no operations; no EventCollector or QueryDb wiring
- **In-memory** `StateViewSlice_Builder.Make(Spec)` — simply delegates to core (which does nothing)
- **Core** `StateViewSlice_Callback` — exists but has wrong event handler signature (`Message.event'` wrapper) and is unused
- No E2E tests exist

## Architecture Decision

Full implementation goes into the **in-memory builder** only (not core):
- AWS uses a different mechanism (Lambda + DynamoDB Streams / SNS), handled at the Plugin_Builder level — out of scope
- In-memory can directly subscribe to Bus event topics via EventCollectorChannel
- Keeps changes scoped to `reventless-in-memory`

## Key Technical Context

### DcbEventLog event publish format
`DcbEventLog_Operations.publishToEventTopic` publishes **raw event JSON** (NOT `{id, meta, event}` wrapped):
```json
{"TAG": "ItemAdded", "id": "item-1", "name": "Widget"}
```
To decode: `json->S.parseJson(Spec.DcbEventLogSpec.eventSchema)`.

### QueryDb naming
`QueryDbStorage_InMemory` registers with key: `${Spec.name}QueryDB`.
Access in tests: `Bus.getQueryDb("${Spec.name}QueryDB")`.

### beforeAllAsync — two resolves required (same as ReadModel E2E)
```
1. sv operations chain → triggers queryDb.operations.apply → creates EventCollector → calls forEventCollector
2. DcbEventLog eventTopic resource.name → triggers EventCollectorChannel.connect → registers Bus.subscribeToEvents
```

### SvQueryDbSpec — bridge from StateViewSlice.Spec to ReadModel.Spec
```rescript
module SvQueryDbSpec = {
  module Id = ReventlessSpec.Id.String
  let name = Spec.name
  type state = Spec.state
  let stateSchema = Spec.stateSchema   // bring generated schema from Spec
  let config = Reventless.ReadModel.config()
  let subIdConfig: option<ReventlessSpec.ReadModel.subIdConfig<state>> = None
}
```

### toProjectionOps — converts QueryDb<Id.String.t, state> → QueryDb<string, state>
`SpecificQueryDb.operations` is typed `QueryDb.operations<Id.String.t, state>` but `Projection.handleActions` expects `QueryDb.operations<string, state>`. Requires the same conversion as `ReadModel_Builder.toProjectionOperations`:
```rescript
let toProjectionOps = (ops: SpecificQueryDb.operations): Reventless.QueryDb.operations<string, Spec.state> => {
  load: id => ops.load(id->ReventlessSpec.Id.String.makeFromString),
  save: (id, s, sm, ttl) => ops.save(id->ReventlessSpec.Id.String.makeFromString, s, sm, ttl),
  saveBatch: batch => ops.saveBatch(batch->Array.map(((id, s, ttl)) => (id->ReventlessSpec.Id.String.makeFromString, s, ttl))),
  count: (id, f, n) => ops.count(id->ReventlessSpec.Id.String.makeFromString, f, n),
  delete: (id, sub) => ops.delete(id->ReventlessSpec.Id.String.makeFromString, sub),
  deleteBatch: ids => ops.deleteBatch(ids->Array.map(((id, sort)) => (id->ReventlessSpec.Id.String.makeFromString, sort))),
}
```

## Steps

### Step 1: Fix StateViewSlice_Callback.res (core correctness fix)

**File**: `reventless/reventless/src/components/StateViewSlice/StateViewSlice_Callback.res`

**Problem**: `eventsHandler` takes `array<Message.event'<Id.String.t, DcbEventLogSpec.event>>` but DcbEventLog publishes raw event JSON (not the `{id, meta, event}` wrapper). The `id` and `meta` fields are never used — only `event.event`.

**Fix**: Simplify to take `array<DcbEventLogSpec.event>` directly.

```rescript
module type T = {
  module Spec: ReventlessSpec.StateViewSlice.Spec
  type queryDbOperations

  let eventsHandler: (
    queryDbOperations,
    array<Spec.DcbEventLogSpec.event>,   // ← was: array<Message.event'<...>>
  ) => promise<unit>
}

module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec
  type queryDbOperations = QueryDb.operations<string, Spec.state>

  let eventsHandler = async (
    queryDbOps: queryDbOperations,
    events: array<Spec.DcbEventLogSpec.event>,   // ← simplified
  ) => {
    let actions = events->Array.flatMap(event => Spec.project(None, event))
    await Projection.handleActions(actions, queryDbOps, None)
  }
}
```

**Status**: [x] Done — simplified to `array<Spec.DcbEventLogSpec.event>` directly

---

### Step 2: Implement in-memory StateViewSlice_Builder

**File**: `reventless/reventless-in-memory/src/components/StateViewSlice_Builder.res`

Replace the thin delegation with a full `Make(Bus).Make(Spec)` implementation following the ReadModel pattern.

**Structure**:
```rescript
module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(Bus, EventCollectorChannel)
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
    Reventless.StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
  ) => {
    type dcbEvent = Spec.DcbEventLogSpec.event
    module Spec = Spec
    type dcbEventLogComponent = Reventless.DcbEventLog.component<Reventless.DcbEventLog.operations<dcbEvent>>
    type component = Reventless.StateViewSlice.component

    // Bridge: StateViewSlice.Spec → ReadModel.Spec (for QueryDb_Builder)
    module SvQueryDbSpec = { ... }  // see Key Technical Context above

    module SpecificQueryDb = Reventless.QueryDb_Builder.Make(SvQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = Reventless.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel)

    let construct = (~dcbEventLog: dcbEventLogComponent, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Reventless.Component.toPulumiResource}

      // 1. Create QueryDb for projected state
      let queryDb = SpecificQueryDb.make(~api=(), ~apiRole=(), ~opts)

      // 2. Get DcbEventLog's event topic (where events are published)
      let dcbEventTopicOutputs: Reventless.EventTopic.outputs =
        (dcbEventLog->Reventless.Component.outputs).eventTopic
      let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])

      // 3. Create EventCollector inside queryDb.operations.apply (needs the ops)
      let eventCollector =
        queryDb
        ->Reventless.Component.operations
        ->Pulumi.Output.apply(queryDbOps => {
          let projectionOps = toProjectionOps(queryDbOps)  // see Key Technical Context

          let ec = SpecificEventCollector.make(~name=Spec.name, ~eventTopics=allEventTopics, ~opts)

          // 4. JSON handler: decode raw DcbEventLog event JSON, apply projection
          let jsonEventsHandler: Reventless.EventCollector.jsonEventsHandler = async jsons => {
            let events = jsons->Array.filterMap(json =>
              switch json->S.parseJson(Spec.DcbEventLogSpec.eventSchema) {
              | Ok(event) => Some(event)
              | Error(err) =>
                Console.log2("StateViewSlice: Failed to decode event:", err)
                None
              }
            )
            let actions = events->Array.flatMap(event => Spec.project(None, event))
            await Reventless.Projection.handleActions(actions, projectionOps, None)
          }

          let handler = SpecificEventCollector.makeHandler(~eventCollector=ec, ~eventsHandler=jsonEventsHandler)
          let resources = (queryDb->Reventless.Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(~handler, ~eventTopics=allEventTopics, ~resources)
          ec
        })

      // 5. Set operations: enqueueEvent from EventCollector
      self->Reventless.Component.setOperations(
        eventCollector
        ->Pulumi.Output.flatMap(ec => ec->Reventless.Component.operations)
        ->Pulumi.Output.apply(({enqueueEvent}) => {
          let ops: Reventless.StateViewSlice.operations = {enqueueEvent}
          ops
        }),
      )

      // 6. Set outputs: DcbEventLog topic resources + QueryDb
      let outputs: Reventless.StateViewSlice.outputs = {
        resources: dcbEventTopicOutputs.resources,
        queryDb: queryDb->Reventless.Component.outputs,
      }
      self->Reventless.Component.setOutputs(outputs)
    }

    let make = (~dcbEventLog, ~opts=?): component =>
      Reventless.Component.make(
        ~componentType=Reventless.StateViewSlice.componentType->Reventless.ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ...),
        ~opts,
      )

    // Expose operations for test resolution
    let operations: component => Pulumi.Output.t<Reventless.StateViewSlice.operations> =
      Reventless.Component.operations
  }
}
```

**Status**: [x] Done — full Make(Bus).Make(Spec) implementation; no module type constraint on inner Make so `operations` is accessible for tests; Platform.res updated to use StateViewSliceMaker.Make(Spec)

---

### Step 3: Add E2E Test Fixtures

**New file**: `reventless/reventless-in-memory/tests/E2E/stateviewslice/StateViewSliceE2EFixtures.res`

```rescript
// DcbEventLog spec with Add/Rename events
module ItemEventLog = {
  @schema
  type event =
    | ItemAdded({id: @s.matches(ReventlessSpec.DcbTag.string) string, name: string})
    | ItemRenamed({id: @s.matches(ReventlessSpec.DcbTag.string) string, name: string})
    | ItemRemoved({id: @s.matches(ReventlessSpec.DcbTag.string) string})
}

// StateViewSlice spec: project to {id, name} state
module ItemsViewSpec = {
  let name = "ItemsView"
  module DcbEventLogSpec = ItemEventLog
  @schema type event = ItemEventLog.event
  @schema type state = {id: string, name: string}

  let project = (_, event) =>
    switch event {
    | ItemEventLog.ItemAdded({id, name}) => [ReventlessSpec.Projection.Set(id, {id, name})]
    | ItemEventLog.ItemRenamed({id, name}) => [Update(id, s => {...s, name})]
    | ItemEventLog.ItemRemoved({id}) => [Delete(id)]
    }
}

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// Build DcbEventLog
module DcbEventLogMaker = DcbEventLog_Builder.Make(Bus)
module ItemEventLogMaker = DcbEventLogMaker.Make(ItemEventLog)
let eventLog = ItemEventLogMaker.make(~name="ItemEventLog")

// Build StateViewSlice
module SVMaker = StateViewSlice_Builder.Make(Bus)
module ItemsViewMaker = SVMaker.Make(ItemsViewSpec)
let sv = ItemsViewMaker.make(~dcbEventLog=eventLog)

// DcbEventLog eventTopic resource (needed for 2nd beforeAllAsync resolve)
let dcbEventTopicResource = (eventLog->ItemEventLogMaker.outputs).eventTopic.resources->Array.getUnsafe(0)

// Helper: append events to DcbEventLog
let appendEvent = async event => {
  let ops = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
  let _ = await ops.append([event])
}

// Helper: load projected state from QueryDb
// QueryDb registered as "ItemsViewQueryDB"
let loadState = async id => {
  switch Bus.getQueryDb("ItemsViewQueryDB") {
  | None => []
  | Some(ops) =>
    switch await ops.load(id) {
    | Error(_) => []
    | Ok(states) =>
      states->Array.map(json => json->S.parseJsonOrThrow(ItemsViewSpec.stateSchema))
    }
  }
}
```

**Status**: [x] Done

---

### Step 4: Add E2E Tests

**New file**: `reventless/reventless-in-memory/tests/E2E/stateviewslice/StateViewSliceE2ETest.res`

```rescript
open AsyncTest
open AsyncTest.Expect
open StateViewSliceE2EFixtures

describe("StateViewSlice E2E", () => {
  // TWO resolves needed (same pattern as ReadModel E2E):
  // 1. sv operations → triggers queryDb.operations.apply → creates EventCollector → forEventCollector
  // 2. dcbEventTopicResource.name → triggers EventCollectorChannel.connect → Bus.subscribeToEvents
  let _ = beforeAllAsync(async () => {
    let _ = await sv->ItemsViewMaker.operations->TestRunner.resolve
    let _ = await dcbEventTopicResource.name->TestRunner.resolve
  })

  testPromise("ItemAdded event projects to QueryDb state", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-1", name: "Widget"}))
    let states = await loadState("item-1")
    expect(states->Array.length)->toBe(1)
    let s = states->Array.getUnsafe(0)
    expect(s.name)->toBe("Widget")
  })

  testPromise("ItemRenamed event updates existing state", async () => {
    // item-1 already exists from previous test (shared state across tests in this describe)
    let _ = await appendEvent(ItemEventLog.ItemRenamed({id: "item-1", name: "SuperWidget"}))
    let states = await loadState("item-1")
    expect(states->Array.length)->toBe(1)
    let s = states->Array.getUnsafe(0)
    expect(s.name)->toBe("SuperWidget")
  })

  testPromise("multiple items projected independently", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-2", name: "Gadget"}))
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-3", name: "Doohickey"}))
    let states2 = await loadState("item-2")
    let states3 = await loadState("item-3")
    expect(states2->Array.length)->toBe(1)
    expect(states3->Array.length)->toBe(1)
    let s2 = states2->Array.getUnsafe(0)
    let s3 = states3->Array.getUnsafe(0)
    expect(s2.name)->toBe("Gadget")
    expect(s3.name)->toBe("Doohickey")
  })

  testPromise("ItemRemoved event deletes state from QueryDb", async () => {
    let _ = await appendEvent(ItemEventLog.ItemAdded({id: "item-4", name: "Temp"}))
    let _ = await appendEvent(ItemEventLog.ItemRemoved({id: "item-4"}))
    let states = await loadState("item-4")
    expect(states->Array.length)->toBe(0)
  })

  testPromise("query for unknown ID returns empty", async () => {
    let states = await loadState("no-such-item")
    expect(states->Array.length)->toBe(0)
  })
})
```

**Status**: [x] Done — 5 tests passing

---

### Step 5: Build and Test

```bash
cd reventless/reventless-in-memory
npm run build
npm test
```

**Status**: [x] Done — 102/102 tests pass (5 new StateViewSlice E2E tests included)

---

## Notes

### rescript.json update
The new test files live in `tests/E2E/stateviewslice/`. The existing `rescript.json` for reventless-in-memory already includes `tests/**` sources recursively, so no change needed.

### Open pattern in tests
Use `open AsyncTest`, `open AsyncTest.Expect`, `open ReventlessSpec.Projection` — same as other E2E tests. No `open Jest`.

### Module sealing note
Do NOT annotate `ItemsViewSpec` with `: StateViewSlice.Spec`. Leave it unannotated — the functor checks structural compatibility at call site.

### ItemEventLogMaker.outputs
`ItemEventLogMaker` uses `include Reventless.DcbEventLog_Builder.Make(...)`. This brings in `make`, `operations`, but may not explicitly expose `outputs`. Use `Reventless.Component.outputs(eventLog)` directly if needed, or add `let outputs = Reventless.Component.outputs` to the DcbEventLog builder module.

### AWS builder
`reventless-aws/src/components/StateViewSlice_Builder.res` still compiles since the core `StateViewSlice_Builder.Make(Spec)` signature is unchanged (we're not touching it). AWS implementation is out of scope.

## Out of Scope

- AWS Lambda + DynamoDB Streams integration for StateViewSlice
- Plugin_Builder wiring for StateViewSlice in production deployments
- Core `StateViewSlice_Builder.Make` refactoring to accept adapters (future work)

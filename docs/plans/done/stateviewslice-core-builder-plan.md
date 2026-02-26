# StateViewSlice Core Builder Plan

## Status: ✅ IMPLEMENTED

## Goal

Move the StateViewSlice implementation to the `reventless` core package using the same
adapter-parametrized pattern as `ReadModel_Builder`, then simplify the in-memory builder
to a thin delegation — the same relationship `ReadModel_Builder_InMemory` has to
`ReadModel_Builder`.

## Current State

| Package | File | State |
|---------|------|-------|
| `reventless` (core) | `StateViewSlice_Builder.res` | Placeholder — sets outputs only, no QueryDb/EventCollector wiring |
| `reventless-in-memory` | `StateViewSlice_Builder.res` | Full implementation — hardcoded to in-memory adapters |
| `reventless-aws` | `StateViewSlice_Builder.res` | Delegates to core placeholder (no-op) |

The in-memory builder contains what the core should have, but with in-memory adapters
baked in instead of being passed as parameters.

## Target State

| Package | File | State |
|---------|------|-------|
| `reventless` (core) | `StateViewSlice_Builder.res` | Full adapter-parametrized implementation |
| `reventless-in-memory` | `StateViewSlice_Builder.res` | Thin delegation, wires in-memory adapters |
| `reventless-aws` | `StateViewSlice_Builder.res` | Standalone placeholder (no longer delegates to core) |

## Design Decisions

### api/apiRole — bundle in outer functor, not in make()

`ReadModel_Builder` exposes `api`/`role` in `ReadModel.T` and passes them through
`make(~api, ~apiRole, ...)`. StateViewSlice deliberately does NOT follow this pattern:

- `StateViewSlice.T.make` currently takes only `(~dcbEventLog, ~opts=?)` — simpler API
- `Platform.T.StateViewSlice` is unaware of api/role — application code stays clean
- Within a single Platform instance all QueryDbs share the same api/apiRole anyway

The api/apiRole values are instead bundled into the outer functor as an `Api` module
parameter (like `Counter_Builder.Make(ApiValues)`). This keeps `StateViewSlice.T`,
`Platform.T`, and all call sites unchanged.

### No Mappings parameter

`ReadModel_Builder` takes a `Mappings` module because a read model can subscribe to
multiple event sources and needs to route each one. StateViewSlice subscribes to exactly
one DcbEventLog and uses `Spec.project` directly — no routing needed.

### AWS remains a placeholder

The AWS mechanism for StateViewSlice (DynamoDB Streams / Lambda / SNS) is out of scope.
The AWS builder becomes a standalone no-op placeholder so it no longer depends on
the old core placeholder that is being replaced.

---

## Steps

### Step 1: Implement core StateViewSlice_Builder

**File**: `reventless/reventless/src/components/StateViewSlice/StateViewSlice_Builder.res`

Replace the placeholder with a fully parametrized builder. The `Api` module bundles the
api/apiRole values so they're closed over at Platform.Make time rather than per-make call.

```rescript
module Make = (
  RuntimeEnvironment: Runtime.Environment,
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api
    and type role = QueryDbStorage.role,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
  Api: {
    let api: QueryDbStorage.api
    let apiRole: QueryDbStorage.role
  },
) => {
  module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
    StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
  ) => {
    type dcbEvent = Spec.DcbEventLogSpec.event
    module Spec = Spec
    type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
    type component = StateViewSlice.component

    module SvQueryDbSpec = {
      module Id = ReventlessSpec.Id.String
      let name = Spec.name
      type state = Spec.state
      let stateSchema = Spec.stateSchema
      let config = ReventlessSpec.ReadModel.config()
      let subIdConfig: option<ReventlessSpec.ReadModel.subIdConfig<state>> = None
    }

    module SpecificQueryDb = QueryDb_Builder.Make(SvQueryDbSpec, QueryDbStorage, QueryDbResolvers)
    module SpecificEventCollector = EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel)

    let toProjectionOps = (ops: SpecificQueryDb.operations): QueryDb.operations<string, Spec.state> => {
      load: id => ops.load(id->ReventlessSpec.Id.String.makeFromString),
      save: (id, s, sm, ttl) => ops.save(id->ReventlessSpec.Id.String.makeFromString, s, sm, ttl),
      saveBatch: batch => ops.saveBatch(
        batch->Array.map(((id, s, ttl)) => (id->ReventlessSpec.Id.String.makeFromString, s, ttl))
      ),
      count: (id, f, n) => ops.count(id->ReventlessSpec.Id.String.makeFromString, f, n),
      delete: (id, sub) => ops.delete(id->ReventlessSpec.Id.String.makeFromString, sub),
      deleteBatch: ids => ops.deleteBatch(
        ids->Array.map(((id, sort)) => (id->ReventlessSpec.Id.String.makeFromString, sort))
      ),
    }

    let construct = (~dcbEventLog: dcbEventLogComponent, self, _name) => {
      let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

      let queryDb = SpecificQueryDb.make(~api=Api.api, ~apiRole=Api.apiRole, ~opts)

      let dcbEventTopicOutputs: EventTopic.outputs = (dcbEventLog->Component.outputs).eventTopic
      let allEventTopics = Dict.fromArray([(Spec.name, dcbEventTopicOutputs)])

      let eventCollector =
        queryDb
        ->Component.operations
        ->Pulumi.Output.apply(queryDbOps => {
          let projectionOps = toProjectionOps(queryDbOps)
          let ec = SpecificEventCollector.make(~name=Spec.name, ~eventTopics=allEventTopics, ~opts)

          let jsonEventsHandler: EventCollector.jsonEventsHandler = async jsons => {
            let events = jsons->Array.filterMap(json =>
              try Some(json->S.parseJsonOrThrow(Spec.DcbEventLogSpec.eventSchema))
              catch {
              | exn =>
                Console.log2("StateViewSlice: Failed to decode event:", exn)
                None
              }
            )
            let actions = events->Array.flatMap(event => Spec.project(None, event))
            await Projection.handleActions(actions, projectionOps, None)
          }

          let handler = SpecificEventCollector.makeHandler(~eventCollector=ec, ~eventsHandler=jsonEventsHandler)
          let resources = (queryDb->Component.outputs).resources
          ec->EventCollectorRuntimeBuilder.forEventCollector(~handler, ~eventTopics=allEventTopics, ~resources)
          ec
        })

      self->Component.setOperations(
        eventCollector
        ->Pulumi.Output.flatMap(ec => ec->Component.operations)
        ->Pulumi.Output.apply(({enqueueEvent}) => {
          let ops: StateViewSlice.operations = {enqueueEvent: enqueueEvent}
          ops
        }),
      )

      let outputs: StateViewSlice.outputs = {
        resources: dcbEventTopicOutputs.resources,
        queryDb: queryDb->Component.outputs,
      }
      self->Component.setOutputs(outputs)
    }

    let make = (~dcbEventLog, ~opts=?): StateViewSlice.component =>
      Component.make(
        ~componentType=StateViewSlice.componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~dcbEventLog, ...),
        ~opts,
      )
  }
}
```

**Note**: The logic is moved verbatim from the in-memory builder, just replacing the
hardcoded in-memory adapter modules with the functor parameters and `Api.api`/`Api.apiRole`.

**Status**: ✅ Done

---

### Step 2: Simplify in-memory StateViewSlice_Builder

**File**: `reventless/reventless-in-memory/src/components/StateViewSlice_Builder.res`

Replace the full implementation with a thin wrapper that instantiates the in-memory
adapters and delegates to the core builder — same pattern as `ReadModel_Builder.res`
in-memory.

```rescript
// In-memory StateViewSlice builder.
// Wires in-memory adapters and delegates to the core Reventless.StateViewSlice_Builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  // InMemory api/apiRole are both unit
  module InMemoryApi = {
    let api = ()
    let apiRole = ()
  }

  module CoreMaker = Reventless.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    InMemoryApi,
  )

  module Make = (Spec: ReventlessSpec.StateViewSlice.Spec) => {
    include CoreMaker.Make(Spec)
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<Reventless.StateViewSlice.operations> =
      Reventless.Component.operations
  }
}
```

**Status**: ✅ Done

---

### Step 3: Update AWS StateViewSlice_Builder

**File**: `reventless/reventless-aws/src/components/StateViewSlice_Builder.res`

The AWS builder currently delegates to `Reventless.StateViewSlice_Builder.Make(Spec)`.
After Step 1, that functor signature changes (it now requires adapter parameters), so
this delegation breaks.

Since the AWS implementation is out of scope, turn the AWS builder into a standalone
no-op placeholder with a clear TODO comment. This preserves the same no-op behaviour
as today without depending on the core builder at all.

```rescript
// StateViewSlice_Builder (AWS) — placeholder pending AWS adapter implementation.
// TODO: wire AWS adapters (DynamoDB Streams / Lambda / SNS) once designed.
//
// For now produces a no-op component that satisfies the type but does nothing at runtime.

module Make = (Spec: ReventlessSpec.StateViewSlice.Spec): (
  Reventless.StateViewSlice.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec
) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec
  type dcbEventLogComponent = Reventless.DcbEventLog.component<
    Reventless.DcbEventLog.operations<dcbEvent>,
  >
  type component = Reventless.StateViewSlice.component

  let make = (~dcbEventLog, ~opts=?): component =>
    Reventless.Component.make(
      ~componentType=Reventless.StateViewSlice.componentType->Reventless.ComponentType.toString,
      ~name=Spec.name,
      ~construct=(self, _name) => {
        let outputs: Reventless.StateViewSlice.outputs = {
          resources: (dcbEventLog->Reventless.Component.outputs).resources,
          queryDb: {resources: [], resolversMaker: _ => []},
        }
        self->Reventless.Component.setOutputs(outputs)
      },
      ~opts,
    )
}
```

**Status**: ✅ Done

---

### Step 4: Build and Test

```bash
npm run build
cd reventless/reventless-in-memory && npm test
```

All 5 StateViewSlice E2E tests should still pass — the behaviour is identical,
only the code organisation changed.

**Status**: ✅ Done

---

## No-change files

The following files do **not** need updating:

- `ReventlessSpec.StateViewSlice` — `T`, `Spec`, `outputs`, `operations` types unchanged
- `ReventlessSpec.Platform.T` — `StateViewSlice.Make` signature unchanged
- `reventless-in-memory/src/Platform.res` — `StateViewSliceMaker.Make(Spec)` call unchanged
- `reventless-aws/src/Platform.res` — `StateViewSlice_Builder.Make(Spec)` call unchanged
- All E2E test files — `make(~dcbEventLog)` call site unchanged

## Comparison with ReadModel

| Aspect | ReadModel | StateViewSlice |
|--------|-----------|---------------|
| Core builder parametrized over adapters | Yes (`ReadModel_Builder`) | Yes (after this plan) |
| In-memory delegates to core | Yes | Yes (after this plan) |
| AWS delegates to core | Yes (`ReadModel_Builder_Single`) | Not yet (AWS implementation TBD) |
| api/apiRole in `make()` signature | Yes — passed per call | No — bundled in outer functor |
| `Mappings` parameter | Yes — routes multiple sources | No — uses `Spec.project` directly |

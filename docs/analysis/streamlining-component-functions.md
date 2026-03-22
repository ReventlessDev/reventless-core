# Streamlining Component Functions: Unified Naming and the Two-Function Pattern

## Motivation

The Reventless framework has four component types that define user-facing business logic functions with **inconsistent naming conventions**. The [Decide-Evolve-Repeat](https://docs.eventsourcingdb.io/blog/2026/03/19/decide-evolve-repeat/) blog post proposes a clean three-element pattern — `decide`, `evolve`, `initialState` — that reduces event-sourced components to their essence.

This analysis compares all four Reventless component specs, examines naming inconsistencies, and proposes a unified approach.

---

## Current State: Four Components, Four Vocabularies

### Side-by-Side Comparison

| Aspect | Aggregate Behavior | ReadModel Projection | StateChangeSlice | StateViewSlice |
|---|---|---|---|---|
| **State type name** | `state` | `state` (in Target) | `decisionModel` | `state` |
| **Initial value** | `init: event => state` | *(implicit — Create action)* | `initialDecisionModel: decisionModel` | *(implicit — None)* |
| **Fold function** | `apply: (state, event) => state` | `map: event' => action` | `reduce: (decisionModel, event) => decisionModel` | `project: (option<state>, event) => array<action>` |
| **Command handler** | `create` + `execute` | *(none — read-side)* | `decide: (decisionModel, command) => result<array<event>, error>` | *(none — read-side)* |
| **Functions count** | 4 (`init`, `apply`, `create`, `execute`) | 1 (`map`) | 2 (`reduce`, `decide`) | 1 (`project`) |

### Detailed Signatures

**Aggregate Behavior** (4 functions):
```rescript
let init: event => state
let apply: (state, event) => state
let create: (command, context, errorHandler) => array<event>
let execute: (state, command, context, errorHandler) => array<event>
```

**ReadModel Projection Mapping** (1 function):
```rescript
let map: event'<string, sourceEvent> => action<string, targetState>
```

**StateChangeSlice** (2 functions + initial value):
```rescript
type decisionModel
let initialDecisionModel: decisionModel
let reduce: (decisionModel, event) => decisionModel
let decide: (decisionModel, command) => result<array<event>, error>
```

**StateViewSlice** (1 function):
```rescript
let project: (option<state>, event) => array<action<string, state>>
```

---

## Naming Analysis

### The "State" Problem

Three different names are used for essentially the same concept — the accumulated result of folding over events:

| Name | Used By | Semantics |
|---|---|---|
| `state` | Behavior, StateViewSlice | The reconstructed aggregate/view state |
| `decisionModel` | StateChangeSlice | Ephemeral state built for one decision |
| `state` (in Target) | ReadModel Projection | The persisted read model row |

**Key distinction**: In Aggregate Behavior and StateChangeSlice, the state/decisionModel is ephemeral — rebuilt from events on every command. In ReadModel and StateViewSlice, the state is persisted in a query database.

**Recommendation**: Use `state` universally. The term "decision model" is DCB-specific jargon that doesn't appear in the broader event-sourcing literature. The EventSourcingDB blog uses `State` throughout. Whether the state is ephemeral or persisted is an infrastructure concern, not a domain modeling concern. The component type already communicates the distinction (write-side vs read-side).

### The "Fold Function" Problem

Four different names for folding an event into state:

| Name | Used By | Signature |
|---|---|---|
| `init` + `apply` | Behavior | `event => state` + `(state, event) => state` |
| `map` | ReadModel Projection | `event' => action` |
| `reduce` | StateChangeSlice | `(decisionModel, event) => decisionModel` |
| `project` | StateViewSlice | `(option<state>, event) => array<action>` |

**Analysis**:
- `reduce` is the standard FP term for a fold, but it's only used in StateChangeSlice
- `apply` is the Behavior term, but "apply" is overloaded (Pulumi.Output.apply, function application)
- `map` is misleading — it doesn't transform the event, it maps it to an action
- `project` is accurate for read-side (projection), but inconsistent with write-side naming
- The EventSourcingDB blog uses **`evolve`** — a domain-specific term that avoids all overloading

**Recommendation**: Use **`evolve`** for write-side components (Aggregate, StateChangeSlice). It's clear, domain-specific, and matches the industry pattern. For read-side components (ReadModel, StateViewSlice), `project` is appropriate as it describes the concept accurately (event projection into a read model). However, if full unification is preferred, `evolve` works everywhere.

### The "Command Handler" Problem

| Name | Used By | Signature |
|---|---|---|
| `create` + `execute` | Behavior | Split on whether state exists |
| `decide` | StateChangeSlice | Unified, uses `result` return type |

The Behavior pattern splits command handling into two functions based on whether the aggregate already exists:
- `create: (command, context, errorHandler) => array<event>` — no state parameter
- `execute: (state, command, context, errorHandler) => array<event>` — has state

The StateChangeSlice pattern uses a single `decide` function with `initialDecisionModel` providing the starting state:
- `decide: (decisionModel, command) => result<array<event>, error>`

The EventSourcingDB blog uses a single `decide: (command, state) => array<event>`.

---

## The Two-Function Proposal

### From Four Functions to Two

The Aggregate Behavior's four functions can be reduced to two by:

1. **Merging `init` + `apply` → `evolve`** using `option<state>` as the state parameter
2. **Merging `create` + `execute` → `decide`** using `option<state>` as the state parameter

### Option A: Optional State Parameter (like StateViewSlice)

```rescript
// Unified Behavior Spec
type state
let initialState: state  // or: no initialState, use option<state>

let evolve: (option<state>, event) => state
let decide: (option<state>, command, context, errorHandler) => array<event>
```

**Pros**:
- Two functions instead of four — simpler spec
- Existence check is explicit in the function body via pattern matching
- Consistent with StateViewSlice's `project: (option<state>, event) => ...`

**Cons**:
- Every `evolve` call must handle `None` even though only the first event ever sees it
- Adds ceremony to `decide` — most command handlers need to unwrap the option first
- Loses the semantic clarity of "this is a creation command" vs "this is a mutation command"

### Option B: Initial State (like EventSourcingDB / StateChangeSlice)

```rescript
// Unified Behavior Spec
type state
let initialState: state

let evolve: (state, event) => state
let decide: (state, command, context, errorHandler) => array<event>
```

**Pros**:
- Clean two-function pattern matching the EventSourcingDB proposal exactly
- `evolve` signature is a standard fold: `(state, event) => state`
- `decide` always receives a concrete state — no unwrapping needed
- `initialState` is a simple value, not a function
- Framework reconstructs state as `events->Array.reduce(initialState, evolve)` — no special first-event handling
- Already proven in StateChangeSlice (which uses `initialDecisionModel` + `reduce` + `decide`)

**Cons**:
- Some aggregates have no meaningful "empty" state (e.g., a Category that doesn't exist yet has no name). Requires an explicit "not yet created" variant in the state type.
- Loses the ability to distinguish "aggregate doesn't exist yet" at the type level in `decide` — the caller must encode it in the state itself (e.g., `NotCreated | Active({name}) | Archived`)

### Recommendation: Option B (Initial State)

Option B is the clear winner:

1. **It's the industry standard** — the Decider pattern (Chassaing), EventSourcingDB, and Axon all use `initialState` + `evolve` + `decide`
2. **It's already in Reventless** — StateChangeSlice uses exactly this pattern (just with different names)
3. **The "no meaningful empty state" objection is actually a feature** — making the "not created" state explicit improves domain modeling. `NotCreated | Active({name}) | Archived` is clearer than the implicit absence of state
4. **Simpler framework internals** — no need for special-casing the first event

---

## Unified Naming Proposal

### Write-Side Components

**Aggregate Behavior** (renamed from 4 functions to 2 + initialState):

```rescript
module type T = {
  module Spec: { ... }
  type state
  let initialState: state
  let evolve: (state, Spec.event) => state
  let decide: (state, Spec.command, Message.context, Handler.errorHandler<...>) => array<Spec.event>
  let resolverConfig: resolverConfig<Spec.command>
  let moduleUrl: string
}
```

**StateChangeSlice** (renamed for consistency):

```rescript
module type Spec = {
  ...
  type state          // was: decisionModel
  let initialState: state  // was: initialDecisionModel
  let evolve: (state, DcbEventLogSpec.event) => state  // was: reduce
  let decide: (state, command) => result<array<DcbEventLogSpec.event>, error>  // unchanged
  ...
}
```

### Read-Side Components

**ReadModel Projection Mapping** — keep `map` or rename to `project`:

The ReadModel Projection has a fundamentally different shape — it transforms events into CRUD actions rather than folding into state. Two options:

1. **Keep `map`**: It's a 1:1 transformation from event to action. Short, conventional.
2. **Rename to `project`**: Aligns with StateViewSlice. More domain-specific.

Recommendation: Rename to **`project`** for consistency with StateViewSlice. Both are read-side projections.

```rescript
// ReadModel Projection Mapping
let project: event'<string, sourceEvent> => action<string, targetState>
```

**StateViewSlice** — keep `project`, rename state parameter approach:

Current: `let project: (option<state>, event) => array<action<string, state>>`

The `option<state>` parameter is useful here because the projection needs to know whether the read model row exists to choose between `Create` and `Update`. However, the current implementation in `StateViewSlice_Builder.res` always passes `None` — the actual state lookup happens inside the `Projection.handleAction` function. So the `option<state>` parameter is **not actually used at runtime** in the current implementation.

Two options:
1. **Keep `option<state>`**: Enables stateful projections where the action depends on current read model state
2. **Drop to just `event`**: Simpler, matches current actual usage

Recommendation: **Simplify to match current usage** — if stateful projections are needed, they can be added later. For now:

```rescript
let project: DcbEventLogSpec.event => array<action<string, state>>
```

Or if we want to preserve the capability for future use, keep `option<state>`.

---

## Summary: Proposed Unified Naming

### Write-Side (Command Processing)

| Element | Aggregate Behavior | StateChangeSlice |
|---|---|---|
| State type | `state` | `state` |
| Initial value | `initialState: state` | `initialState: state` |
| Fold function | `evolve: (state, event) => state` | `evolve: (state, event) => state` |
| Command handler | `decide: (state, command, ctx, onError) => array<event>` | `decide: (state, command) => result<array<event>, error>` |

Note: The `decide` signatures differ slightly — Aggregate Behavior uses `errorHandler` callback (for synchronous error recovery), while StateChangeSlice uses `result` (for async error reporting). This is an intentional difference driven by different error handling needs, not a naming inconsistency.

### Read-Side (Event Projection)

| Element | ReadModel Projection | StateViewSlice |
|---|---|---|
| State type | `targetState` (in Mapping) | `state` |
| Projection function | `project: event' => action` | `project: event => array<action>` |

Note: ReadModel Projection receives the full event envelope (`event'` with id and meta), while StateViewSlice receives just the event. ReadModel returns a single action (or `Ignore`), while StateViewSlice returns an array. These are structural differences worth examining for further harmonization.

### Naming Changes Required

| Component | Current Name | Proposed Name |
|---|---|---|
| Behavior | `init` | *(removed — replaced by `initialState`)* |
| Behavior | `apply` | `evolve` |
| Behavior | `create` | *(removed — merged into `decide`)* |
| Behavior | `execute` | `decide` |
| StateChangeSlice | `decisionModel` | `state` |
| StateChangeSlice | `initialDecisionModel` | `initialState` |
| StateChangeSlice | `reduce` | `evolve` |
| ReadModel Mapping | `map` | `project` |

---

## Migration Impact

### Breaking Changes

This is a **major breaking change** affecting all user-facing Behavior and StateChangeSlice implementations. Every aggregate behavior and every DCB slice in application code must be updated.

### Migration Path

1. **Phase 1**: Add the new names as aliases alongside the old ones (deprecated)
2. **Phase 2**: Update all examples and documentation
3. **Phase 3**: Remove old names in the next major version

Alternatively, since Reventless is pre-1.0, a single breaking release may be acceptable.

### Files Affected

- `reventless-spec/src/types/Behavior.res` — module type T
- `reventless-core/src/Behavior.res` — type aliases
- `reventless-core/src/components/Aggregate/Aggregate_Callback.res` — uses init/apply/create/execute
- `reventless-spec/src/components/StateChangeSlice.res` — module type Spec
- `reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res` — uses reduce/decide
- `reventless-spec/src/types/Projection.res` — Mapping module type (`map` → `project`)
- All example applications (online-shop-aggregates, online-shop-dcb, online-shop-hybrid)
- All Behavior implementations (PluginBehavior, CategoryBehavior, etc.)
- All StateChangeSlice specs (AddCategory, etc.)
- All Projection Mapping implementations
- Documentation in `packages/doc/`

---

## Open Questions

1. **Should `decide` in Aggregate Behavior return `result` instead of using `errorHandler`?** The `errorHandler` callback pattern enables synchronous error recovery (returning compensating events), which `result` doesn't support. But in practice, most error handlers just rethrow. If we standardize on `result`, the framework can handle error reporting uniformly.

2. **Should ReadModel Projection's `project` receive just the event or the full envelope?** Currently `map` receives `event'<string, sourceEvent>` (envelope with id and meta). StateViewSlice's `project` receives just `DcbEventLogSpec.event`. The envelope is often needed (e.g., to use the aggregate ID as the read model row key). Standardizing on envelope-based projection would be more capable.

3. **Should StateViewSlice's `project` return a single action or an array?** ReadModel Mapping returns one action; StateViewSlice returns an array. An array is more flexible (one event can affect multiple rows), but adds complexity. Consider standardizing on array for both.

4. **Should we align the state type name in ReadModel Projection?** Currently the Mapping module uses `targetState` as the type name (because it needs to distinguish source and target). This is a structural necessity, not a naming inconsistency.

---

## Effect Integration: Context and Error Handling

### Current Situation

The `decide` function in Aggregate Behavior currently takes two infrastructure parameters alongside the domain parameters:

```rescript
// Current Aggregate Behavior
let create: (command, Message.context, Handler.errorHandler<error, command, event>) => array<event>
let execute: (state, command, Message.context, Handler.errorHandler<error, command, event>) => array<event>
```

These are **framework plumbing leaked into the domain function signature**:

1. **`Message.context`** — carries `{id: string, meta: meta}` where `meta` contains `service`, `time`, `ip`, `user`, `msgId`, `correlationId`. In practice, most Behavior implementations prefix it with `_` — it's unused in 90%+ of cases. The examples (CategoryBehavior, CustomerBehavior, ProductBehavior) all use `_context` and only pass it through to `errorHandler`.

2. **`Handler.errorHandler`** — a callback `(error, command, context) => array<event>` injected by the framework's `Aggregate_Callback`. The framework-provided implementation logs the error and returns `[]` (empty events). User Behaviors call it as a function: `errorHandler(CategoryAlreadyExists, command, context)`. The user never defines the errorHandler — they only *call* it.

Meanwhile, **StateChangeSlice's `decide`** has neither parameter:

```rescript
// Current StateChangeSlice
let decide: (decisionModel, command) => result<array<event>, error>
```

This is already cleaner — errors are expressed as `result`, and context is absent.

### Problems with Current Approach

#### 1. errorHandler is misnamed and misused

The `errorHandler` is not really an error *handler* from the user's perspective — it's an error *reporter*. The user calls it when a business rule is violated:

```rescript
| (Active(_), Add(_)) => errorHandler(CategoryAlreadyExists, command, context)
| (Archived, Rename(_)) => errorHandler(CategoryAlreadyArchived, command, context)
```

What actually happens inside `errorHandler` (in `Aggregate_Callback`):
```rescript
let errorHandler = (error, command, context: Message.context) => {
  let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
  let commandJsonStr = command->Message.encode(Spec.commandSchema)->JSON.stringify
  Effect.logError(`Behavior error ${errorJson} in ${serviceName}(${id}): Command: ${commandJsonStr}`)
    ->Effect.runSync
  []  // Always returns empty array — no events generated
}
```

The callback pattern creates the illusion that the user controls error recovery, but the framework always returns `[]`. The `command` and `context` parameters are only used for logging — the user is threading values through their function just so the framework can log them.

#### 2. context threading is pure ceremony

In every example Behavior:
- `create` receives `_context` and passes it to `errorHandler`
- `execute` receives `context` and passes it to `errorHandler`
- No Behavior implementation reads `context.id` or `context.meta` for business logic

The context is framework infrastructure needed for logging — it should not be in the domain function signature.

#### 3. Inconsistency between components

| Component | Error mechanism | Context parameter |
|---|---|---|
| Aggregate Behavior | `errorHandler` callback | `Message.context` |
| StateChangeSlice | `result<array<event>, error>` | None |
| ReadModel Projection | N/A (no commands) | N/A |
| StateViewSlice | N/A (no commands) | N/A |

StateChangeSlice already demonstrates the clean pattern.

### Proposal: Use `result` and Effect Services

#### Step 1: Replace `errorHandler` with `result` return type

Align Aggregate Behavior's `decide` with StateChangeSlice's pattern:

```rescript
// Proposed Aggregate Behavior
let decide: (state, command) => result<array<event>, error>
```

User code becomes:

```rescript
// Before (4 functions, errorHandler + context)
let create = (command, _context, errorHandler) =>
  switch command {
  | Add({name}) => [Added({name})]
  | Rename(_) | Archive => errorHandler(CategoryNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  | (Active(_), Add(_)) => errorHandler(CategoryAlreadyExists, command, context)
  | (Active(_), Rename({name})) => Ok([Renamed({name})])
  | (Active(_), Archive) => Ok([Archived])
  | (Archived, _) => errorHandler(CategoryAlreadyArchived, command, context)
  }

// After (1 function, result return)
let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name})) => Ok([Added({name})])
  | (NotCreated, _) => Error(CategoryNotFound)
  | (Active(_), Add(_)) => Error(CategoryAlreadyExists)
  | (Active(_), Rename({name})) => Ok([Renamed({name})])
  | (Active(_), Archive) => Ok([Archived])
  | (Archived, _) => Error(CategoryAlreadyArchived)
  }
```

**Benefits**:
- Pure function — no callbacks, no context, no framework dependency
- Same pattern as StateChangeSlice — **unified across all write-side components**
- Testable with simple `expect(decide(state, cmd))->toEqual(Ok([event]))`
- Error logging moves to the framework layer (where it belongs)

#### Step 2: Move error logging into the framework callback

The framework's `Aggregate_Callback` already has access to the command, context, and error — it doesn't need the user to thread these values back:

```rescript
// Aggregate_Callback (framework layer)
let processCommand = (state, command') => {
  let context = {id: command'.id->Spec.Id.toString, meta: command'.meta}
  switch Behavior.decide(state, command'.command) {
  | Ok(events) => Ok(events)
  | Error(error) =>
    // Framework handles logging — user never sees this
    let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
    Effect.logError(`Behavior error ${errorJson} in ${serviceName}(${context.id})`)
    ->Effect.runSync
    Ok([])  // Same behavior as current errorHandler
  }
}
```

The framework already has `command'` (which contains `id` and `meta`). It already encodes the error for logging. **Nothing is lost by removing these from the user function.**

#### Step 3: Use Effect services for cross-cutting concerns

For the rare cases where domain logic genuinely needs request context (e.g., audit trails, tenant-specific rules), Effect services provide a clean injection mechanism without polluting function signatures.

**Current** (context as parameter):
```rescript
let execute = (state, command, context, _errorHandler) =>
  switch (state, command) {
  | (Active(_), SensitiveAction({...})) =>
    if context.meta.user == "admin" { Ok([ActionPerformed(...)]) }
    else { Error(Unauthorized) }
  }
```

**Proposed** (Effect service for the exceptional case):
```rescript
// For the 99% of behaviors that don't need context:
let decide = (state, command) =>
  switch (state, command) {
  | (Active(_), Rename({name})) => Ok([Renamed({name})])
  | ...
  }

// For the rare behavior that needs request context:
// Option A: Effect return type
let decide: (state, command) => Effect.t<result<array<event>, error>, never, RequestContext>

// Option B: Explicit context parameter (opt-in)
module type T = {
  type context  // user-defined, defaults to unit
  let decide: (state, command, context) => result<array<event>, error>
}
```

Option B is simpler and doesn't require Effect in the user's domain code. The framework provides a way to inject context when the Behavior declares it needs one:

```rescript
// Default: no context needed
module CategoryBehavior: Behavior.T with type context = unit = {
  let decide = (state, command, ()) => ...
}

// Opt-in: needs request context
module AuditBehavior: Behavior.T with type context = Message.context = {
  let decide = (state, command, context) =>
    switch ... {
    | ... => Ok([ActionPerformed({...user: context.meta.user})])
    }
}
```

However, this adds a type parameter. A simpler approach: **just don't provide context at all in the Behavior signature**, and handle audit/tenant concerns at a different layer (e.g., event enrichment in the callback, or a separate audit side-effect).

### Unified `decide` Signatures After Effect Integration

| Component | Proposed `decide` Signature |
|---|---|
| Aggregate Behavior | `(state, command) => result<array<event>, error>` |
| StateChangeSlice | `(state, command) => result<array<event>, error>` |

**They are now identical.** The only difference is in the infrastructure layer:
- Aggregate Behavior operates on a per-aggregate event stream (one stream per aggregate ID)
- StateChangeSlice operates on a shared DCB event log (filtered by tags)

This infrastructure difference is handled by the Builder, not the user's domain functions.

### Effect in `evolve`

The `evolve` function is and should remain a **pure synchronous function**:

```rescript
let evolve: (state, event) => state
```

No Effect, no context, no error handling. This function is called during event replay (potentially thousands of times) and must be fast and deterministic. Effect wrapping would add unnecessary overhead and complexity.

The same applies to `initialState` — it's a simple value, not an effectful computation.

### Effect in `project` (Read-Side)

The `project` function should also remain pure:

```rescript
// ReadModel Projection
let project: event'<string, sourceEvent> => array<action<string, targetState>>

// StateViewSlice
let project: event => array<action<string, state>>
```

Projection functions transform events into CRUD actions. They don't need error handling (an event that can't be projected is a bug, not a business rule violation) and don't need context (the event envelope already carries all metadata). Effect wrapping would add complexity without benefit.

If a projection encounters an event it can't handle, returning `[]` (ignore) is the correct response, already supported.

### Where Effect *Should* Be Used

Effect is valuable at the **framework callback layer**, not in user domain functions:

| Concern | Where | How |
|---|---|---|
| Error logging | `Aggregate_Callback`, `StateChangeSlice_Callback` | `Effect.logError` after `decide` returns `Error(...)` |
| Retry on conflict | `Aggregate_Callback`, `StateChangeSlice_Callback` | `Effect.retry` with `Schedule.exponential` |
| Request context | `Aggregate_Callback` (if needed) | `Effect.serviceWith(RequestContextTag, ...)` |
| Metrics | All callbacks | `Effect.serviceWith(MetricsTag, m => m.increment(...))` |
| Structured logging | All callbacks | `Effect.logInfo` with span annotations |
| Stream processing | All callbacks | `Stream.mapEffect`, `Stream.runFold`, etc. |

This is already the current architecture — Effect is used in callbacks, not in user code. The proposal reinforces this by removing the last framework-level parameters (`context`, `errorHandler`) from the user's `decide` signature.

### Impact on `Aggregate_Callback`

The current `Aggregate_Callback.processCommand` function (lines 72-115) handles the `create`/`execute` split and `errorHandler` injection. With the unified `decide`:

```rescript
// Before (current)
let processCommand = (acc, command') =>
  switch acc {
  | Ok((stateO, events)) =>
    let runBehavior = () =>
      switch stateO {
      | Some(state) =>
        let generatedEvents = try Behavior.execute(state, command'.command,
          {id: command'.id->Spec.Id.toString, meta: command'.meta}, errorHandler
        ) catch { ... }
        Ok((updateState(stateO, generatedEvents), ...))
      | None =>
        let generatedEvents = Behavior.create(command'.command,
          {id: command'.id->Spec.Id.toString, meta: command'.meta}, errorHandler
        )
        Ok((updateState(None, generatedEvents), ...))
      }
    Effect.succeed(runBehavior())
  | Error(_) as error => Effect.succeed(error)
  }

// After (proposed)
let processCommand = (acc, command') =>
  switch acc {
  | Ok((state, events)) =>
    switch Behavior.decide(state, command'.command) {
    | Ok(newEvents) =>
      let newState = newEvents->Array.reduce(state, Behavior.evolve)
      Effect.succeed(Ok((newState, Array.concat(events, [(newEvents, command'->updateMeta)]))))
    | Error(error) =>
      let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
      Effect.logError(
        `Behavior error ${errorJson} in ${Spec.name}(${command'.id->Spec.Id.toString})`
      )->Effect.map(_ => Ok((state, events)))  // No events generated, continue with next command
    }
  | Error(_) as error => Effect.succeed(error)
  }
```

The callback becomes simpler:
- No `apply'` helper to handle `option<state>` — state is always concrete (starts at `initialState`)
- No `errorHandler` definition — errors are handled inline via `result` pattern matching
- No `Message.context` construction — only needed for logging, which uses `command'.id` directly
- Error logging uses Effect natively instead of `Effect.runSync` inside a synchronous callback

### Summary: Effect Integration Recommendations

| Function | Effect integration | Rationale |
|---|---|---|
| `evolve` | **None** — keep pure | Hot path (replay), must be fast and deterministic |
| `decide` | **Remove `context` and `errorHandler`**, return `result` | Aligns with StateChangeSlice, simplifies user code, moves logging to framework |
| `project` | **None** — keep pure | Stateless transformation, no error handling needed |
| `initialState` | **None** — keep as value | Simple starting point, no computation needed |
| Callbacks | **Already using Effect** — continue and expand | Error logging, retry, metrics, stream processing |

### Complete Proposed Signatures (All Components)

**Aggregate Behavior**:
```rescript
module type T = {
  module Spec: {
    @schema type command
    @schema type event
    @schema type error
  }
  type state
  let initialState: state
  let evolve: (state, Spec.event) => state
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>
  let resolverConfig: resolverConfig<Spec.command>
  let moduleUrl: string
}
```

**StateChangeSlice**:
```rescript
module type Spec = {
  let name: string
  let moduleUrl: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema type command
  @schema type error
  type state
  let initialState: state
  let evolve: (state, DcbEventLogSpec.event) => state
  let decide: (state, command) => result<array<DcbEventLogSpec.event>, error>
  let commandSchema: S.t<command>
}
```

**ReadModel Projection Mapping**:
```rescript
module type Mapping = {
  module SourceId: Id.T
  @schema type sourceEvent
  @schema type targetState
  let project: Message.event'<string, sourceEvent> => array<action<string, targetState>>
  let sourceEventSchema: S.t<sourceEvent>
  let sourceName: string
  let subIdConfig: option<ReadModel.subIdConfig<targetState>>
  let targetStateSchema: S.t<targetState>
}
```

**StateViewSlice**:
```rescript
module type Spec = {
  let name: string
  let moduleUrl: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema type event
  @schema type state
  let stateSchema: S.t<state>
  let project: DcbEventLogSpec.event => array<Projection.action<string, state>>
}
```

All four components now share a consistent vocabulary:
- **Write-side**: `state` + `initialState` + `evolve` + `decide` (returns `result`)
- **Read-side**: `state` + `project` (returns `array<action>`)
- **No framework parameters in user functions** — context and error handling live in the framework layer where Effect services handle them naturally

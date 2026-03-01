# Effect Context & Layer Integration Plan

**Status:** Complete (all phases A–F done)

**Created:** 2026-02-28

**Depends on:** `docs/plans/effect-stream-integration.md` phases A–G (complete)

**Analysis:** `docs/plans/Analysis/effect-requirements-type-analysis.md`

**Summary:** Add `Context.res` and `Layer.res` bindings to `rescript-effect`, extend `Effect.res`
with `serviceWith` and `provideService`, and introduce two concrete Reventless services:
`Logger` (structured logging per environment) and `RequestContext` (per-invocation correlation
data). These are the two use cases the analysis identified as high-value without requiring a
framework redesign.

---

## Background

The `'r` (requirements) channel of `Effect.t<'a, 'e, 'r>` is structurally present throughout
the bindings but always `unit` in practice. The analysis identified three obstacles:

1. **No Context/Tag/Layer bindings** — service declaration and lookup are not yet bound.
2. **No generator syntax** — service access requires `flatMap` nesting rather than `yield*`.
3. **`unit` vs `never`** — `runPromise` accepts any `'r`, so satisfaction is not type-enforced.

Obstacle 3 cannot be fixed without changing the core bindings in a breaking way (out of scope).
Obstacle 2 is inherent to ReScript; the verbosity tax is acceptable for leaf code (logging, context
lookup). Obstacle 1 is fully addressable.

The plan adds the minimum bindings needed for services that are defined in ReScript (not
pre-built by the Effect library like `TestContext`):
- `Context.GenericTag` to create a typed tag value
- `Effect.serviceWith` to read a service from context (populates `'r`)
- `Effect.provideService` to satisfy a requirement at the handler boundary
- `Layer.t` type plus `succeed_` and `effect_` constructors for service-level DI

`Logger` and `RequestContext` are then implemented on top of these primitives.

---

## Phase A — `Context.res`: Tag creation

**File:** `rescript/rescript-effect/src/Context.res` (new)

### What to add

```rescript
// ReScript bindings for Effect Context
//
// Context is an immutable map from typed Tags to service implementations.
// It is the runtime carrier of the 'r (requirements) channel.
//
// Usage pattern:
//   1. Declare a tag: let myTag: Context.tag<MyService.t> = Context.genericTag("MyService")
//   2. Use in effects: Effect.serviceWith(myTag, svc => svc.doThing())
//      → effect type is Effect.t<result, err, MyService.t>
//   3. Satisfy at boundary: Effect.provideService(effect, myTag, liveImpl)
//      → effect type becomes Effect.t<result, err, unit>

// Opaque tag type. The phantom 'a is the service type this tag identifies.
// Two tags with the same string key but different 'a types are distinct at runtime.
type tag<'a>

// Create a new tag identified by the given unique string key.
// The 'a type is set by annotation at the call site:
//   let loggerTag: tag<Logger.t> = Context.genericTag("Logger")
// The key must be globally unique within the application.
@module("effect") @scope("Context")
external genericTag: string => tag<'a> = "GenericTag"
```

### Notes

- `Context.GenericTag` is the JS API for creating a tag without class syntax. It is the
  idiomatic non-TypeScript-generator way to declare services.
- The phantom `'a` on `tag<'a>` is not enforced by the JS runtime — it is a ReScript type
  annotation discipline. Tags with wrong phantom types will silently miscast at runtime; use
  descriptive string keys to catch mistakes during debugging.
- No `Context.make`, `Context.add`, or `Context.get` bindings are needed — those are Effect
  internals; the `provideService` / `serviceWith` API is the user-facing surface.

---

## Phase B — `Effect.res`: `serviceWith` and `provideService`

**File:** `rescript/rescript-effect/src/Effect.res` (extend)

### What to add (in the "Dependency injection" section)

```rescript
// Read a service value from the context and map it to a result.
// The 'r channel of the returned effect is set to 'service (the tag's phantom type),
// requiring that service to be provided before the effect can run.
//
// Example:
//   let logInfo = (msg: string): Effect.t<unit, unit, Logger.t> =>
//     Effect.serviceWith(Logger.tag, logger => logger.info(msg)->Effect.flatMap(identity))
//   (For a unit-returning service method use serviceWithEffect instead — see below)
@module("effect") @scope("Effect")
external serviceWith: (Context.tag<'service>, 'service => 'b) => t<'b, 'e, 'service> =
  "serviceWith"

// Like serviceWith but the mapping function returns an Effect.
// Avoids an extra flatMap at the call site when the service method is itself effectful.
// R = 'service (same as serviceWith).
@module("effect") @scope("Effect")
external serviceWithEffect: (Context.tag<'service>, 'service => t<'a, 'e, 'service>) => t<'a, 'e, 'service> =
  "serviceWithEffect"

// Satisfy a single service requirement by supplying a concrete implementation.
// Reduces 'r to unit — all requirements are treated as satisfied (ReScript cannot
// express partial requirement removal without row types).
// Place at the outermost handler boundary, after all service uses are composed.
@module("effect") @scope("Effect")
external provideService: (t<'a, 'e, 'r>, Context.tag<'service>, 'service) => t<'a, 'e, unit> =
  "provideService"
```

### Notes on `serviceWith` vs `serviceWithEffect`

In TypeScript you write `yield* myService.doThing()` in one step. In ReScript the two-step
pattern is needed:

```rescript
// Synchronous service access (service method returns a plain value):
Effect.serviceWith(tag, svc => svc.getValue())

// Effectful service access (service method returns Effect.t):
Effect.serviceWithEffect(tag, svc => svc.doEffectfulThing())

// Without serviceWithEffect you'd need:
Effect.serviceWith(tag, svc => svc.doEffectfulThing())->Effect.flatMap(identity)
// — which is equivalent but more noise.
```

---

## Phase C — `Layer.res`: Layer type and simple constructors

**File:** `rescript/rescript-effect/src/Layer.res` (new)

### What to add

```rescript
// ReScript bindings for Effect Layer
//
// A Layer is a blueprint for constructing a service. It separates
// service *construction* (possibly effectful, possibly requiring other services)
// from service *use* (the Effect pipeline that consumes it).
//
// Layer.t<'out, 'e, 'in_>:
//   'out  — the service type this layer provides (matches tag<'out>)
//   'e    — errors that may occur during layer construction
//   'in_  — services this layer itself requires to be built (unit = none)
//
// Typical use:
//   let loggerLive: Layer.t<Logger.t, unit, unit> =
//     Layer.succeed_(Logger.tag, { info: msg => Effect.sync(() => Console.log(msg)) })
//
//   let result = myEffect->Effect.provide(loggerLive)->Effect.runPromise

type t<'out, 'e, 'in_>

// ─── Construction ────────────────────────────────────────────────────────

// Provide a service implementation directly (no construction effects, no dependencies).
// 'effect suffix dropped: JS name is "succeed"; ReScript name succeed_ avoids shadowing
// Effect.succeed and sidesteps "effect" as a future OCaml keyword.
@module("effect") @scope("Layer")
external succeed_: (Context.tag<'a>, 'a) => t<'a, 'e, unit> = "succeed"

// Lift an Effect that produces a service implementation into a Layer.
// The Effect may be async (e.g. open a DB connection) and may require services of its own.
// JS name is "effect"; ReScript name effect_ avoids the OCaml 5 "effect" keyword.
@module("effect") @scope("Layer")
external effect_: (Context.tag<'a>, Effect.t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "effect"

// ─── Providing layers to effects ──────────────────────────────────────────
// Note: Effect.provide already accepts a Layer (its 'layer parameter is polymorphic).
// These bindings are for composing layers before providing them.

// Chain two layers: inner satisfies some of outer's requirements.
// Layer.provide(outer, inner) — inner feeds into outer.
// The combined layer requires whatever outer still needs after inner is applied.
@module("effect") @scope("Layer")
external provide: (t<'a, 'e, 'r>, t<'r, 'e, 'r2>) => t<'a, 'e, 'r2> = "provide"

// ─── Merge (advanced — deferred) ─────────────────────────────────────────
// Layer.merge combines two layers side-by-side into one that provides both services.
// In TypeScript: Layer<A | B, E, RIn1 | RIn2>.
// ReScript has no type-level union/intersection for row types, so merge is not bound here.
// Workaround: call Effect.provideService twice, once per service, instead of merging layers.
```

### Why `succeed_` and `effect_` have `_` suffixes

`effect` is a keyword in OCaml 5 (algebraic effects). Since ReScript is built on the OCaml AST,
binding a value named `effect` either errors or warns with modern toolchain versions. The `_`
suffix is the standard escape — the same convention used for `await_` in `Deferred.res` (`await`
is a JS reserved word). `succeed_` gets the same treatment for symmetry within the module.

---

## Phase D — `Logger` service

**File:** `rescript/rescript-effect/src/Logger.res` (new, inside rescript-effect)

The Logger service lives in rescript-effect (not Reventless) because it is a general-purpose
service with no framework dependencies.

### Interface

```rescript
// Logger service for Effect pipelines.
//
// Any Effect with 'r = Logger.t requires a Logger to be provided before running.
// Provide at the handler entry point:
//   myEffect->Effect.provideService(Logger.tag, Logger.consoleLogger)->Effect.runPromise
//
// In tests, use Logger.silent to suppress all output:
//   myEffect->Effect.provideService(Logger.tag, Logger.silent)->Effect.runPromise

type t = {
  debug: string => Effect.t<unit, unit, unit>,
  info:  string => Effect.t<unit, unit, unit>,
  warn:  string => Effect.t<unit, unit, unit>,
  error: string => Effect.t<unit, unit, unit>,
}

// The tag — used with serviceWith/provideService
let tag: Context.tag<t>

// ─── Built-in implementations ─────────────────────────────────────────────

// Writes to stdout/stderr via Console
let consoleLogger: t

// Discards all messages — use in tests where log noise is unwanted
let silent: t
```

### Implementation notes

- `tag` is `Context.genericTag("reventless/Logger")`
- `consoleLogger.info` wraps `Effect.sync(() => Console.log(msg))`
- `consoleLogger.error` wraps `Effect.sync(() => Console.error(msg))`
- `silent` returns `Effect.succeed(())` for every level
- A `withPrefix` helper (`(prefix, logger) => { info: msg => logger.info(prefix ++ " " ++ msg), ... }`)
  is useful for correlation-ID-prefixed logging; add if needed

---

## Phase E — `RequestContext` service

**File:** `reventless/reventless-core/src/RequestContext.res` (new, inside reventless-core)

`RequestContext` is Reventless-specific (it references `Message.meta`) so it belongs in
`reventless-core`, not `rescript-effect`.

### Interface

```rescript
// RequestContext service — carries per-invocation data through an Effect pipeline
// without explicit argument threading.
//
// Populated at the Lambda handler entry point from the incoming event's meta field.
// All Effects that need correlationId or tenantId use serviceWith(RequestContext.tag, ...)
// instead of accepting them as function arguments.
//
// Provide in Lambda handler:
//   let ctx = { correlationId: event.meta.correlationId, ... }
//   myEffect
//   ->Effect.provideService(RequestContext.tag, ctx)
//   ->Effect.provideService(Logger.tag, Logger.consoleLogger)
//   ->Effect.runPromise
//
// In tests:
//   ->Effect.provideService(RequestContext.tag, RequestContext.test())

type t = {
  correlationId: string,
  // Extend with tenantId, userId, traceId as multi-tenancy needs arise
}

let tag: Context.tag<t>

// Convenience constructor for tests
let test: (~correlationId: string=?) => t
```

### Implementation notes

- `tag` = `Context.genericTag("reventless/RequestContext")`
- `test(~correlationId="test-correlation-id")` provides a sensible default for test code
- The framework does not automatically inject `RequestContext` — it is opt-in per handler

---

## Phase F — Wire Logger into Reventless framework Effects

**Scope:** Audit `reventless-core` and `reventless-in-memory` for `Console.log` calls inside
Effect pipelines and replace them with `Logger.serviceWithEffect`-based calls.

### Known locations to update

- `InMemory_Bus.res`: `Console.log2("InMemory_Bus: no command handler for channel", channelName)`
- Any `Console.log` / `Console.error` inside `Effect.promise` wrappers in the adapters

### How effects change

Before:
```rescript
// Inside an Effect:
Effect.sync(() => {
  Console.log2("dispatch: no handler for", channelName)
})
```

After:
```rescript
Effect.serviceWithEffect(Logger.tag, logger =>
  logger.warn("dispatch: no handler for channel: " ++ channelName)
)
// Effect type gains Logger.t in 'r
```

The `'r` change propagates upward to callers. At the top of each call chain (the Lambda
handler or in-memory `runPromise` call), add:

```rescript
->Effect.provideService(Logger.tag, Logger.consoleLogger)
// or in tests:
->Effect.provideService(Logger.tag, Logger.silent)
```

### Phasing note

This phase touches many files and changes `'r` signatures. Do it as a single focused commit
after Phases A–E are stable. Because all existing code uses `unit` for `'r` and `runPromise`
accepts any `'r`, the build continues to work throughout — the type change is non-breaking in
practice (the constraint is opt-in).

---

## Summary Table

| Phase | What | New file(s) | Touches existing |
|-------|------|-------------|-----------------|
| A | `Context.res` — `tag<'a>`, `genericTag` | `Context.res` | — |
| B | `Effect.res` — `serviceWith`, `serviceWithEffect`, `provideService` | — | `Effect.res` |
| C | `Layer.res` — `t`, `succeed_`, `effect_`, `provide` | `Layer.res` | — |
| D | `Logger` service | `Logger.res` | — |
| E | `RequestContext` service | `RequestContext.res` | — |
| F | Wire Logger into framework Effects | — | `InMemory_Bus.res`, adapters |

Phases A–E can be done in order in a single sitting. Phase F is a separate, wider refactor.

---

## Full-Framework Logger & Context Migration — Analysis

This section analyses what it would take to extend the Logger and RequestContext services
throughout the entire Reventless stack: every logging call site, every Effect pipeline, and
every Lambda handler boundary. It categorises the existing Console.log landscape, identifies
the architectural obstacles, and proposes concrete follow-on phases.

---

### Audit of Existing Console.log / Console.warn / Console.error Calls

An audit of `reventless-core` and `reventless-in-memory` (excluding test files and the
unrelated `Projection.res` optimiser) reveals four distinct categories of logging call sites.
Each category requires a different migration strategy.

#### Category 1 — Deploy-time (inside `Pulumi.Output.apply` callbacks)

```
AggregateRuntime_Builder_Common.res:134   Console.log2("***** forCommandGenerator … set handler for", infos)
AggregateRuntime_Builder_Common.res:164   Console.log ("***** forCommandTopic … set handler for ${urn}")
AggregateRuntime_Builder_Common.res:203   Console.log2("***** forEventCollector … set handler for", urns)
EventCollectorRuntime_Builder_Single.res:135  Console.log2("***** forEventCollector … set handler for", urns)
EventCollectorRuntime_Builder_Single.res:65   Console.log ("validateParent: parent ${name} type: ${type}")
Adapter.res:63                            Console.log2("resource:", r)
```

**Context:** These callbacks execute synchronously during Pulumi stack construction (deploy
time), not at Lambda invocation time. `Pulumi.Output.apply` callbacks are plain JS callbacks —
they are not Effect fibers and cannot `await` or use `runPromise`.

**Migration options:**
- The Effect Logger service **cannot** be used here.
- `OutputLogger.res` (already in `reventless-core`) is the deploy-time equivalent and is the
  right abstraction. Thread it through the `Make` functor parameters.
- Alternatively, leave these as `Console.log` — they are developer-facing diagnostics visible
  only when `pulumi up` runs, not in CloudWatch or test output.

**Verdict:** Thread a deploy-time logger (plain `Logger.t` value or `OutputLogger`) through the
runtime builder functors. See Phase G below.

---

#### Category 2 — Lambda handler dispatch (inside `async (event, context) =>` functions)

```
AggregateRuntime_Builder_Common.res:40    Console.log2("----- found handler for CommandGenerator", info)
AggregateRuntime_Builder_Common.res:43    Console.log2("no handler found:", info)
AggregateRuntime_Builder_Common.res:53    Console.log2("----- found handler for CommandTopic", urn)
AggregateRuntime_Builder_Common.res:59    Console.log2("----- found ${count} handler(s) for EventCollector", urn)
AggregateRuntime_Builder_Common.res:61    Console.log2("no handler found:", urn)
EventCollectorRuntime_Builder_Single.res:47   Console.log2("----- found ${count} handler(s) for EventCollector", urn)
EventCollectorRuntime_Builder_Single.res:49   Console.log2("no handler found:", urn)
```

**Context:** These are inside `aggregateHandler` / `eventCollectorHandler` — the router
functions that run on every Lambda invocation and dispatch to the registered component handler.
They are typed `async (event, context) => promise<string>`, not Effect pipelines.

**Migration options:**
1. **Thread `Logger.t` through the functor** — Add `logger: Logger.t` to the `Make` functor
   parameters of `AggregateRuntime_Builder_Common` and `EventCollectorRuntime_Builder_Single`.
   The async handler closes over `logger` and calls `logger.info(...)->Effect.runSync`.
   All callers (`AggregateRuntime_Builder_Single`, `_PerAggregate`, `_Micro`) pass the logger
   down from their own `Make` arguments.

2. **Convert handlers to Effect** — Change `aggregateHandler` to return
   `Effect.t<string, 'e, Logger.t>`, satisfy at the Lambda entry point with
   `->Effect.provideService(Logger.tag, Logger.consoleLogger)->Effect.runPromise`.
   This requires changing `Runtime.eventHandler` type and all adapter implementations.
   Significant cascade change; not recommended until the async handlers are already Effect-based
   for other reasons.

**Verdict:** Option 1 is the right near-term path. See Phase H below.

---

#### Category 3 — In-memory bus (async `dispatchCommand`)

```
InMemory_Bus.res:189   Console.log2("InMemory_Bus: no command handler for channel", channelName)
```

**Status:** Migrated in Phase F. `BusConfig` now carries `logger: Logger.t`; `Make` and
`MakeBounded` default to `Logger.consoleLogger`.

---

#### Category 4 — Projection optimiser (synchronous, pure functions)

```
Projection.res: ~12 Console.warn / Console.log calls inside optimise/reduce logic
```

**Context:** `Projection.res` is a pure synchronous module that optimises event-sourced state
projections at read-model build time. Its warnings describe internal merge decisions
("optimizing Delete after Create, therefore ignoring the Create"). They are developer-facing
diagnostics, not application-level logs.

**Migration options:**
- Converting `Projection` functions to return `Effect.t` just to carry `Logger.t` would cascade
  into all callers (`ReadModel_Builder`, `StateChangeSlice_Builder`, `EventMapper_Builder`, …).
- These are not runtime/Lambda logs — they surface during test runs or local dev, not in
  CloudWatch.

**Verdict:** Leave as `Console.warn` for now. If `Projection` is ever refactored to be
Effect-based for other reasons, migrate then.

---

#### Category 5 — GraphQL server startup (Node.js callback)

```
GraphQL_Server.res:59   Console.log("[GraphQL] Listening on http://localhost:…/graphql")
```

**Context:** Inside the Node.js `server.listen(port, callback)` callback. Not Effect-based,
not a Lambda handler. Development-only (the in-memory platform starts a local GraphQL server
for interactive testing).

**Verdict:** Could pass `logger.info(...)` directly once `GraphQL_Server.start()` accepts a
`~logger` parameter; low priority.

---

### Architectural Obstacles

#### 1. `'r` cannot express union types

Effect's TypeScript generics use `R1 | R2` to accumulate requirements. ReScript has no row
types. When an Effect pipeline needs both `Logger.t` and `RequestContext.t`, the `'r`
type parameter can only hold one type at a time.

**Workaround:** Call `Effect.provideService` twice at the handler boundary:
```rescript
effect
->Effect.provideService(Logger.tag, Logger.consoleLogger)
->Effect.provideService(RequestContext.tag, {correlationId: event.meta.correlationId})
->Effect.runPromise
```
Each call reduces `'r` to `unit`. This works but loses compile-time enforcement that both
services are always provided (since `runPromise` accepts any `'r` anyway — see Background
section). For a two-service pipeline, this is acceptable.

#### 2. Deploy-time callbacks are synchronous

`Pulumi.Output.apply` callbacks cannot use `Effect.runPromise` (they are synchronous) and
cannot propagate Effect `'r` requirements. A plain `Logger.t` value threaded through the
functor is the only option.

#### 3. Module type signature changes ripple widely

Adding `logger: Logger.t` to `AggregateRuntime_Builder_Common.Make` means every caller
(`AggregateRuntime_Builder_Single`, `_PerAggregate`, `_Micro`) must thread the value. Those
callers are instantiated by `PluginRuntime_Builder`, which is called from user plugin code.
The ripple touches user-facing APIs. The change must be backwards-compatible (default to
`Logger.consoleLogger`) to avoid breaking existing plugin code.

#### 4. `Runtime.eventHandler` is typed `async`, not Effect

```rescript
type eventHandler<'event, 'ctx, 'result> = ('event, 'ctx) => promise<'result>
```

Converting this to `Effect.t<'result, 'e, 'r>` would require:
- Changing `Runtime.Environment` module type
- Updating all AWS adapter implementations (`AggregateRuntime_Builder_Single`, the Micro/PerAggregate variants, EventCollectorRuntime builders)
- Updating `reventless-aws` Lambda handler entry points

This is a major breaking refactor. It would make Logger propagation via `'r` elegant but the
cost is high. Recommended only as a long-term goal.

#### 5. `RequestContext` is per-invocation, not per-process

`Logger.t` is process-scoped (same implementation for all Lambda calls). `RequestContext.t` is
invocation-scoped (different correlationId per call). This means:
- Logger: safe to thread through functor parameters (set once at construction)
- RequestContext: must be injected at the top of each Lambda invocation handler, not in functor
  parameters. The only clean path is through the Effect `'r` channel or as an explicit
  parameter to the handler itself.

---

### Follow-On Phases

#### Phase G — Logger configurable at Platform level

**Scope:** Allow tests to opt in to `Logger.silent` to suppress log noise from the framework's
own dispatch logging (e.g., "InMemory_Bus: no command handler").

**What to add:**
- `Platform.MakeWithConfig` functor: `(Config: {let logger: Logger.t}): Reventless.Platform.T`
- `InMemory_Bus.MakeWithLogger` functor: `(Config: {let logger: Logger.t}): T`
  (wraps `Impl` with `capacity = None` and the supplied logger)
- Keep `Platform.Make()` and `InMemory_Bus.Make()` unchanged (default to `consoleLogger`)

**Files touched:** `Platform.res`, `InMemory_Bus.res`

**Call-site impact:** Zero — existing `Platform.Make()` sites are unchanged.

---

#### Phase H — Logger in runtime builder functors

**Scope:** Replace all Category 2 Console.log calls (Lambda handler dispatch routing logs)
with `logger.info / logger.warn` calls.

**What to change:**
- Add `logger: Logger.t` to `AggregateRuntime_Builder_Common.Make` functor
  (extra module parameter, or as a named module `(Log: {let logger: Logger.t})`)
- Add same to `EventCollectorRuntime_Builder_Single.Make`
- Thread through `AggregateRuntime_Builder_Single`, `_PerAggregate`, `_Micro`,
  `EventCollectorRuntime_Builder_PerEventCollector`
- Thread through `PluginRuntime_Builder` up to the application handler entry point
- Default to `Logger.consoleLogger` everywhere so no existing call sites break

**Files touched (runtime builder chain):**
```
AggregateRuntime_Builder_Common.res
AggregateRuntime_Builder_Single.res
AggregateRuntime_Builder_PerAggregate.res
AggregateRuntime_Builder_Micro.res
EventCollectorRuntime_Builder_Single.res
EventCollectorRuntime_Builder_PerEventCollector.res
PluginRuntime_Builder.res
PluginRuntime_Builder_Single.res
PluginRuntime_Builder_Micro.res
```

**Category 1 (deploy-time)** can be migrated in the same commit by passing the same logger
into the `Pulumi.Output.apply` closures via closure capture. No extra abstraction needed.

**AWS adapter entry point:** The Lambda handler (in `reventless-aws`) calls
`PluginRuntime_Builder.handler(...)`. This is where the Logger implementation is chosen:
`Logger.consoleLogger` for production (writes to CloudWatch), `Logger.silent` for tests.

---

#### Phase I — Logger in Effect pipelines (`'r` propagation)

**Scope:** Effect-returning operations in components (CommandTopic, EventTopic, Stream variants)
gain `Logger.t` in `'r`. Callers add `provideService` at the handler boundary.

**What to change:**
- `CommandTopic_Operations.publishJsons`, `publishJsonsStream`, `publishJsonStream` gain
  `Logger.t` in `'r` by using `Effect.serviceWithEffect(Logger.tag, ...)` internally for any
  diagnostic logging they emit.
- Same for EventTopic publisher operations.
- At Lambda handler entry points and in-memory test runners: add
  `->Effect.provideService(Logger.tag, Logger.consoleLogger)` before `runPromise`.

**Note:** Since `runPromise` accepts any `'r`, this phase is purely opt-in and non-breaking.
Existing callers that don't add `provideService` still compile and run — they just use whatever
Logger implementation was already in context (or none, since the default is the live Effect
context which has no Logger injected, meaning the requirement goes unsatisfied silently).

---

#### Phase J — `RequestContext` propagation through Effect pipelines

**Scope:** Effects that need per-invocation data (correlationId, future tenantId) declare
`RequestContext.t` in `'r` instead of accepting those values as function arguments.

**What to change:**
- Any Effect-returning function that currently takes `~correlationId: string` as a parameter is
  changed to use `Effect.serviceWith(RequestContext.tag, ctx => ctx.correlationId)` instead.
- Lambda handler entry point extracts the correlationId from the event and provides it:
  ```rescript
  effect
  ->Effect.provideService(RequestContext.tag, {correlationId: event.meta.correlationId})
  ->Effect.provideService(Logger.tag, Logger.consoleLogger)
  ->Effect.runPromise
  ```
- In-memory test runners provide a test context:
  ```rescript
  ->Effect.provideService(RequestContext.tag, RequestContext.test())
  ->Effect.provideService(Logger.tag, Logger.silent)
  ->Effect.runPromise
  ```

**Prerequisite:** Phase I (Logger in Effect pipelines) should be stable first, as both services
are provided together at the same handler boundary.

---

### Migration Order & Priority

| Phase | What | Effort | Value | Prerequisite |
|-------|------|--------|-------|-------------|
| G | Platform-level Logger config | XS | Medium | Phase F |
| H | Logger in runtime builder functors | M | High | Phase G |
| I | Logger in Effect pipelines (`'r`) | S | Medium | Phases A–F |
| J | RequestContext in Effect pipelines | S | High | Phase I |

**Recommended order:** G → H (these address all Category 1 and 2 Console.log calls) → I → J.

Phases I and J are the purest application of the Effect service pattern but have the smallest
immediate impact because the pipeline-internal logging (Category 2) is more frequent and more
visible than the per-operation pipeline logs.

Phase H provides the highest return on investment: it replaces all remaining framework-level
Console.log calls with structured logging that can be silenced in tests and enriched in
production (e.g., prefixed with correlationId via a `withPrefix` wrapper on `Logger.t`).

---

### Long-Term Goal: Effect-Based Runtime Handlers

The cleanest eventual architecture replaces `Runtime.eventHandler`:
```rescript
// Current
type eventHandler<'event, 'ctx, 'result> = ('event, 'ctx) => promise<'result>

// Future
type effectHandler<'event, 'ctx, 'result, 'r> =
  ('event, 'ctx) => Effect.t<'result, 'e, 'r>
```

With this change, `'r` flows naturally from the component handler all the way to the Lambda
entry point, where a single `provideService` chain satisfies all requirements in one place. The
Lambda entry point becomes:

```rescript
handler(event, context)
->Effect.provideService(Logger.tag, Logger.consoleLogger)
->Effect.provideService(RequestContext.tag, {correlationId: event.meta.correlationId})
->Effect.runPromise
```

This requires updating `Runtime.Environment`, all AWS adapter implementations, and all
existing handler registrations. It is a **major breaking refactor** and is listed here as a
long-term goal only. Phases G–J achieve most of the practical benefit at a fraction of the cost.

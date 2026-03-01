# Effect Requirements Type (`'r`) — Analysis

**Status:** Analysis (no implementation planned)

**Created:** 2026-02-28

**Summary:** What the third type parameter of `Effect.t<'a, 'e, 'r>` is, how it works in the
underlying TypeScript/JavaScript Effect library, how it is currently used (or not used) in the
rescript-effect bindings and in Reventless, and what it could realistically be used for.

---

## 1. What the `'r` Parameter Is

`Effect.t<'a, 'e, 'r>` is the three-channel type:

| Parameter | Name | Meaning |
|-----------|------|---------|
| `'a` | Success | The value produced on success |
| `'e` | Error | The expected, typed failure channel |
| `'r` | Requirements | The services/context the effect needs before it can run |

`'r` is a **structural type intersection** in TypeScript: if an effect needs a `Logger` and a
`Database`, its requirements type is `Logger & Database`. The type system enforces at compile time
that all requirements are satisfied before `Effect.runPromise` or `Effect.runSync` is called.

When no requirements are needed, TypeScript uses `never` (the bottom type for intersections).
The rescript-effect bindings use `unit` for this role — a pragmatic choice that is looser
but plays the same conceptual role.

### The Context Map

At runtime, requirements are fulfilled by a **Context** — an immutable map from typed tags to
service implementations. Each service has a `Context.Tag`, a unique identifier that acts as both
the key in the context map and the type-level requirement:

```typescript
// TypeScript
class Logger extends Context.Tag("Logger")<
  Logger,
  { readonly log: (msg: string) => Effect<void> }
>() {}

// Accessing the service makes it appear in R:
const program: Effect<void, never, Logger> = Effect.gen(function* () {
  const logger = yield* Logger       // R = Logger
  yield* logger.log("hello")
})
```

`Effect.provideService` adds an implementation to the context, removing the service from `R`:

```typescript
const runnable: Effect<void, never, never> =
  Effect.provideService(program, Logger, { log: msg => Effect.sync(() => console.log(msg)) })
// R = never → fully satisfied, can call runPromise
```

A **Layer** is a blueprint for constructing a service — it can itself have requirements (`RIn`),
produce a service (`ROut`), and fail during construction (`E`):

```typescript
type Layer<ROut, E, RIn>

// Example: a DatabaseLive layer that needs a Config service to connect
const DatabaseLive: Layer<Database, ConfigError, Config> = Layer.effect(
  Database,
  Effect.gen(function* () {
    const config = yield* Config
    const conn = yield* Database.connect(config.url)
    return { query: sql => Database.executeQuery(conn, sql) }
  })
)
```

Layers compose: `Layer.merge` combines two layers side by side; `Layer.provide` chains them so
the output of one feeds the input of another. Once all transitive requirements are satisfied, the
final layer has `RIn = never` and can be passed to `Effect.provide` to make an effect runnable.

Layers can also manage **resource lifecycle**: `Layer.scoped` wraps an `acquireRelease` so the
service is initialized on layer construction and finalized when the layer's scope closes.

---

## 2. Current State in rescript-effect

### Bindings Status

The rescript-effect bindings acknowledge `'r` throughout but treat it as a pass-through
parameter — always `unit` in practice:

```rescript
// All construction functions produce unit requirements:
external succeed: 'a => t<'a, 'e, 'r>        // 'r is free (unifies with unit)
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r>

// Only 'r-affecting binding:
external provide: (t<'a, 'e, 'r>, 'layer) => t<'a, 'e, unit>
// Accepts any 'layer value (polymorphic), reduces 'r → unit.
```

There is **no** `Context` module, no `Layer` module, and no `Effect.serviceWith` or
`Effect.provideService` binding. The only concrete layer in the bindings is:

```rescript
// TestContext.res
type layer
@module("effect") @scope("TestContext")
external testContext: layer = "TestContext"
// Used as: Effect.provide(myEffect, TestContext.testContext)->Effect.runPromise
```

`TestContext` is an opaque layer that provides `TestClock`, `TestRandom`, and `TestConsole`.
Its use in the test suite (fork+adjust+join within one `Effect.provide(TestContext)` pipeline)
is the only place the requirements mechanism is exercised in the whole codebase.

### All Reventless Effects Have `unit` Requirements

A search across all `Effect.t<>` uses in `reventless/`:

```rescript
Effect.t<result<DcbTag.sequencePosition, string>, string, unit>
Effect.t<unit, unit, unit>
Stream.t<'event, string, unit>
Effect.t<unit, string, unit>
```

Every instance uses `unit` for `'r`. No Reventless component currently declares a service,
reads from context, or provides a layer (beyond TestContext in tests).

---

## 3. Why `'r` Is Hard to Use Fully in ReScript

Three structural obstacles make the TypeScript `'r` pattern difficult to replicate in ReScript:

### 3.1 No Generator Syntax

TypeScript Effect's ergonomics depend entirely on `yield*`:

```typescript
const program = Effect.gen(function* () {
  const db = yield* Database    // <— reads service from context, R = Database
  return yield* db.query(sql)
})
```

ReScript has no generator protocol. Reading a service from context would require:

```rescript
// Hypothetical rescript spelling
Effect.flatMap(
  Effect.serviceWith(Database.tag, identity),  // requires Context bindings
  db => db.query(sql)
)
```

This is functional but significantly more verbose. Every service access becomes a nested
`flatMap`, degrading the linear readability that makes Effect ergonomic in TypeScript.

### 3.2 No Class-Based Tag Declaration

TypeScript `Context.Tag` relies on class syntax and nominal typing via a string key. In
ReScript, the nearest equivalent would be:

```rescript
// Hypothetical
module Logger = {
  type t = { log: string => Effect.t<unit, unit, unit> }
  // needs: external tag: Context.tag<t> = "..."
  // and a way to construct the tag with a unique string key
}
```

This requires `Context.tag<'service>` bindings, a `Context.Tag` constructor binding, and a
convention for uniquely naming services — all currently absent.

### 3.3 `unit` vs `never` as the Empty Requirement

TypeScript uses `never` (the intersection identity) as the "no requirements" type. The bindings
use `unit`. The consequence:

- In TypeScript: `Effect.runPromise` is only callable if `R = never` (type-safe)
- In rescript-effect: `runPromise` accepts any `'r` — the requirement is not enforced

```rescript
// Effect.res — no constraint on 'r:
external runPromise: t<'a, 'e, 'r> => promise<'a> = "runPromise"
```

This means even if services were declared and used in `'r`, the type checker would not prevent
calling `runPromise` on an unsatisfied effect. The safety guarantee would be opt-in rather than
enforced.

---

## 4. What `'r` Could Be Used for in Reventless

Despite the obstacles, there are concrete places in Reventless where the requirements pattern
adds genuine value.

### 4.1 Logger / Tracer Injection (High Value, Low Disruption)

Currently, logging in Reventless is done with `Console.log` calls scattered across modules.
There is no way to redirect logs to a structured logger, suppress them in tests, or attach
correlation IDs.

With a `Logger` service:

```rescript
// Hypothetical
module Logger = {
  type t = {
    info: string => Effect.t<unit, unit, unit>,
    error: string => Effect.t<unit, unit, unit>,
  }
  // tag: Context.tag<t>
}
// Effect inside EventCollector_Builder would have R = Logger
// Tests provide a silent logger; Lambda provides a structured CloudWatch logger
```

This is the most natural use case because:
- All environments (Lambda, in-memory, test) can provide different implementations
- No structural change to the framework's data flow
- ReScript's verbosity tax is limited (logging appears in leaf code, not in composed pipelines)
- The `Pulumi.Output.t` pattern is not involved — purely runtime

### 4.2 Clock / Scheduling Injection (Already Done via TestContext)

`Effect.sleep` and `Schedule`-based retry already respect the `TestClock` service via
`TestContext.testContext`. This is the one fully working use of `'r` in the codebase.

The pattern works precisely because `TestClock` is an Effect-internal service — its tag and
layer are defined inside the Effect library itself; the rescript-effect bindings only need to
expose the pre-built `testContext` layer value.

Any framework service that follows the same pattern (defined inside the Effect library,
exposed as a concrete `layer` value) would work just as cleanly.

### 4.3 Configuration / Environment (Possible, Limited Benefit)

Lambda functions read config from environment variables at startup. This could be modelled as
an injectable `Config` service:

```rescript
// Hypothetical
module Config = {
  type t = { tableName: string, region: string }
  // tag: Context.tag<t>
}
```

However:
- Config is already resolved at deploy time via Pulumi and passed into builders
- Injecting it via the Effect context would duplicate the existing `Pulumi.Output.t` pattern
- Benefit is marginal; this pattern would mainly be useful for testing where config values need
  to differ per test

### 4.4 EventLog / QueryDb Operations as Services (Interesting, High Cost)

The most ambitious use would be to model `EventLog.operations` and `QueryDb.operations` as
Effect services rather than plain functions:

```rescript
// Hypothetical
module EventLogService = {
  type t = EventLog.operations
  // tag: Context.tag<t>
}
// Aggregate_Callback effects would have R = EventLogService
// Provide a real DynamoDB impl in production, mock in tests
```

This would:
- Remove the need for `Pulumi.Output.t` wrapping of operations (currently done at deploy time)
- Give tests a standard place to inject mock implementations via `Effect.provide`
- Enable full Effect composition across the command handling pipeline

But it would be a **fundamental redesign** of how Reventless components receive their
infrastructure dependencies. The current `Pulumi.Output.t` pattern is load-bearing across the
entire framework. Replacing it with Effect services would be a multi-month rewrite.

### 4.5 Request-Scoped Context (Interesting for Multi-Tenancy)

Lambda handlers process one invocation at a time. A `RequestContext` service could carry
per-invocation data (correlation ID, tenant ID, authenticated user) through the entire
Effect pipeline without passing it explicitly as a function argument:

```rescript
module RequestContext = {
  type t = { correlationId: string, tenantId: string }
  // tag: Context.tag<t>
}
// Any Effect in the handler pipeline can access RequestContext without argument threading
```

This is genuinely useful, especially for audit logging and multi-tenant systems. It is also
achievable without restructuring the framework — only the handler entry point would call
`Effect.provideService(pipeline, RequestContext.tag, {correlationId, tenantId})`.

---

## 5. Practical Path Forward

Given the obstacles and the value analysis, the realistic uses of `'r` in Reventless break
into two tiers:

### Tier 1 — Achievable Without New Bindings

These reuse the existing `Effect.provide` + opaque `layer` pattern, the same way `TestContext`
works today:

| Use case | What is needed | Effort |
|----------|---------------|--------|
| TestClock | Already done | — |
| Custom test layers (e.g. silent logger) | Add binding for the specific Effect-internal layer value | Very low |

### Tier 2 — Requires New Context/Layer Bindings

These require adding `Context.tag<'a>`, `Effect.serviceWith`, and `Layer` bindings to
rescript-effect:

| Use case | Value | Effort |
|----------|-------|--------|
| Logger / Tracer injection | High — enables structured logging per environment | Medium (new bindings + usage refactor) |
| RequestContext (correlation ID, tenant) | Medium — clean alternative to argument threading | Medium |
| Config injection for testing | Low — Pulumi.Output already handles this | Medium |
| EventLog / QueryDb as services | Very high (if rewriting anyway) | Very high (framework redesign) |

### What to Add to rescript-effect to Enable Tier 2

Minimum required bindings:

```rescript
// Context.res (new file)
type tag<'a>     // opaque — identifies a service
// Context.Tag constructor: needs string key + phantom type
// Can be constructed via Obj.magic or a dedicated JS wrapper

// Effect.res additions
external serviceWith: (tag<'a>, 'a => 'b) => t<'b, 'e, 'a> = "serviceWith"
// Reads a service from context; R = 'a (the service type)

// Layer.res (new file)
type t<'out, 'e, 'in_>   // the Layer type
external succeed_: (tag<'a>, 'a) => t<'a, 'e, unit> = "succeed"
external effect_: (tag<'a>, Effect.t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "effect"
external merge: (t<'a, 'e, 'r>, t<'b, 'e, 'r2>) => t<'a_and_b, 'e, 'r_and_r2> = "merge"
```

The `effect_` binding takes an Effect.t that produces a service value and lifts it into a Layer.
`merge` composes two layers — but the combined output type `'a_and_b` is hard to express in
ReScript without row types or intersection types, which may require `Obj.magic` bridges.

---

## 6. Summary

| Question | Answer |
|----------|--------|
| What is `'r`? | The set of services/context an Effect needs before it can run |
| How is it currently used? | Only for `TestContext.testContext` (TestClock in tests) |
| Is the type safety enforced? | No — `runPromise` accepts any `'r` in the bindings |
| Why so limited? | No generator syntax; no Context/Tag/Layer bindings |
| Most practical near-term use | Logger/Tracer injection; RequestContext per invocation |
| Highest-value long-term use | EventLog/QueryDb as services (requires framework redesign) |
| Prerequisite | Add `Context.tag`, `Effect.serviceWith`, and `Layer` bindings |

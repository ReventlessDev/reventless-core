# Effect Context & Layer Integration Plan

**Status:** Phases A–E complete; Phase F pending

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

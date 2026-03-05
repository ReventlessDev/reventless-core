/**
ReScript bindings for `Layer<Out, E, In>` — a blueprint for constructing a service.

Layers separate service *construction* (possibly effectful, possibly requiring
other services) from service *use* (the `Effect` pipeline that consumes it).

The three type parameters:
- `'out`  — the service type this layer provides (matches `Context.tag<'out>`)
- `'e`    — errors that may occur during layer construction
- `'in_`  — services this layer itself requires (`unit` = no dependencies)

**Example**
```rescript
let configLive: Layer.t<Config.t, unit, unit> =
  Layer.succeed_(Config.tag, Config.default)

myEffect
->Effect.provide(configLive)
->Effect.runPromise
```
*/
type t<'out, 'e, 'in_>

// ─── Construction ────────────────────────────────────────────────────────

/**
Creates a `Layer` from a concrete service implementation.

No construction effects, no dependencies — the simplest way to provide a service.

> **Note** The JS name is `succeed`; this binding uses `succeed_` to avoid
shadowing `Effect.succeed` and to sidestep `effect` as a future OCaml keyword.
*/
@module("effect") @scope("Layer")
external succeed_: (Context.tag<'a>, 'a) => t<'a, 'e, unit> = "succeed"

/**
Creates a `Layer` from an `Effect` that constructs the service.

Use when service construction is async (e.g. opening a DB connection) or
requires other services as inputs.

> **Note** The JS name is `effect`; this binding uses `effect_` to avoid the
`effect` OCaml 5 keyword.
*/
@module("effect") @scope("Layer")
external effect_: (Context.tag<'a>, Effect.t<'a, 'e, 'r>) => t<'a, 'e, 'r> = "effect"

// ─── Composing layers ─────────────────────────────────────────────────────

/**
Chains two layers: `inner` satisfies some of `outer`'s requirements.

`Layer.provide(outer, inner)` — `inner` feeds into `outer`. The combined
layer requires whatever `outer` still needs after `inner` is applied.

> **Note** `Effect.provide` already accepts a `Layer` directly. Use `Layer.provide`
only when *composing layers together* before supplying them to an effect.
*/
@module("effect") @scope("Layer")
external provide: (t<'a, 'e, 'r>, t<'r, 'e, 'r2>) => t<'a, 'e, 'r2> = "provide"

// ─── Merge (not bound) ────────────────────────────────────────────────────
// Layer.merge combines two layers side-by-side. ReScript has no type-level
// union/intersection for row types, so merge is not bound here.
// Workaround: call Effect.provideService twice, once per service.

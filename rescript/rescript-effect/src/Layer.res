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
// JS name is "succeed"; ReScript name succeed_ avoids shadowing Effect.succeed and
// sidesteps "effect" as a future OCaml keyword.
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

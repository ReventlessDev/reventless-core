# Plan: Remove Obj.magic Usages

## Status

All phases complete. Build: zero warnings. Tests: 141/141 (rescript-effect), 226/226 (reventless-in-memory).

| Phase | Status | Notes |
|---|---|---|
| A | **done** | Replaced `Obj.magic` with `toUnknownSchema` in `extractEventTypes` and `extractTaggedFields` |
| B | **done** | `Exit.match` added; `exitCausePayload` removed. |
| C | **done** | `EffectOption` internal conversion module; `causeOption`, `option`, `poll` now return idiomatic ReScript `option<'a>`. 7 test `Obj.magic` removed. |
| D | **done** | Added `messageFromUnknown` to `Util_Error.res`; replaced 8 `(err->Obj.magic: JsExn.t)->JsExn.message` occurrences (incl. 2 in `Util_DynamoDb_Runtime`). `CommandTopic_Callback` was already clean. |
| E | **done** | Replaced 4 `(args->Obj.magic: dict<string>)` with `JSON.Decode` chain in `QueryDbResolvers_GraphQL.res` |
| F | **done** | Added `let operations` to `ExtensionPoint.T` and `Extension.T` (infra + core + all builders). `Plugin_Helpers` uses narrow `Obj.magic` only to coerce abstract `operations` to concrete type (unavoidable due to infra/core package boundary). |
| G | **done** | Added `let operations` + `let outputs` to `Counter.T` and `Counter_Builder`. Fixed `CounterFixtures.res` and `EventMapper_Builder.res`. |

## Overview

There were ~50 `Obj.magic` usages in the codebase. This plan eliminated or replaced them
where doing so is practical and improves type safety. Some uses are intentional and
remain documented as acceptable.

## Inventory — What Changed

| Category | Before | After | Files changed |
|---|---|---|---|
| Schema introspection (`S.t`) | 2 `Obj.magic` | 0 — uses `toUnknownSchema` | `DcbTag.res` |
| `exitCausePayload` hack | 1 `Obj.magic` | 0 — uses `Exit.match` | `EventLog_Operations.res`, `Exit.res` |
| Effect `_tag` inspection | 7 `Obj.magic` | 0 — bindings convert at boundary | `EffectOption.res` (new), `Exit.res`, `Effect.res`, `Fiber.res`, `EffectTest.res`, `ExitTest.res`, `TestClockTest.res` |
| Exception coercion to `JsExn.t` | 8 `Obj.magic` | 0 — uses `messageFromUnknown` | `Util_Error.res`, `EventLog_Operations.res`, `EventLogStorage_DynamoDb_Runtime.res`, `DcbEventLogStorage_DynamoDb_Runtime.res`, `QueryDbStorage_DynamoDb_Runtime.res`, `Util_DynamoDb_Runtime.res` |
| GraphQL args coercion | 4 `Obj.magic` | 0 — uses `JSON.Decode` | `QueryDbResolvers_GraphQL.res` |
| Module sealing (EP / Extension) | 2 `Obj.magic` (whole component cast) | 2 `Obj.magic` (narrow operations cast) | `Plugin_Helpers.res`, `ExtensionPoint.res` (infra+core), `Extension.res` (infra+core), `ExtensionPoint_Builder.res`, `Extension_Builder.res` |
| Counter.T operations access | 1 `Obj.magic` | 0 — uses `Counter.operations` | `Counter.res` (infra), `Counter_Builder.res`, `CounterFixtures.res` |
| EventMapper Builder coercion | 1 `Obj.magic` | 0 — uses `Counter.operations`/`outputs` | `EventMapper_Builder.res` |

**Net: 26 `Obj.magic` removed, 2 narrowed (abstract→concrete type coercion).**

---

## Phases (reference)

### Phase A — DcbTag: use existing `toUnknownSchema` external (2 occurrences)

Replaced `schema->Obj.magic` with `schema->toUnknownSchema` in `extractEventTypes` and
`extractTaggedFields`. The external was already declared in the same file.

### Phase B — Add `Exit.match` binding; replace `exitCausePayload` hack (1 occurrence)

Added `Exit.match` binding to `rescript-effect/src/Exit.res`. Replaced the
`exitCausePayload` type hack in `EventLog_Operations.res` with `Exit.match`.

### Phase C — Convert Effect Option to ReScript option at binding boundary (7 occurrences)

Created `EffectOption.res` as an **internal** conversion helper (not exposed to consumers):
```rescript
type t<'a>
let toOption: t<'a> => option<'a> = %raw(`
  function(opt) { return opt._tag === "Some" ? opt.value : undefined; }
`)
```

Wrapped raw externals so all public bindings return idiomatic ReScript `option<'a>`:
- `Exit.causeOption` — post-converts with `EffectOption.toOption`
- `Effect.option` — maps inside the Effect with `EffectOption.toOption`
- `Fiber.poll` — maps inside the Effect with `EffectOption.toOption`

Tests now use `Option.isSome`/`Option.isNone` — standard ReScript.

### Phase D — Add `messageFromUnknown` utility; replace JsExn coercions (8 occurrences)

Added `messageFromUnknown` to `reventless-core/src/util/Util_Error.res`:
```rescript
let messageFromUnknown: (unknown, string) => string = %raw(`
  function(err, fallback) {
    if (err != null && typeof err.message === 'string') return err.message;
    return fallback;
  }
`)
```

Replaced 8 occurrences of `(err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr(...)`.
`CommandTopic_Callback.res` was already clean (no `Obj.magic`).
`Util_DynamoDb_Runtime.res` had 2 additional occurrences not in the original inventory.

### Phase E — GraphQL args coercion: use JSON.Decode (4 occurrences)

Replaced `(args->Obj.magic: dict<string>)` with `JSON.Decode.object` + `JSON.Decode.string`
chains in `QueryDbResolvers_GraphQL.res`.

### Phase F — Expose operations on ExtensionPoint.T and Extension.T (2 occurrences)

Added `let operations: component => Pulumi.Output.t<operations>` to:
- `ReventlessInfra.ExtensionPoint.T` and `ReventlessInfra.Extension.T` (infra module types)
- `ReventlessCore.ExtensionPoint.T` and `ReventlessCore.Extension.T` (core module types)
- `ExtensionPoint_Builder.res` and `Extension_Builder.res` (`let operations = Component.operations`)

`Plugin_Helpers.res` now calls `SpecificExtensionPoint.operations(extensionPoint)` instead
of casting the whole component. A narrow `Obj.magic` remains to coerce the abstract
`operations` type to the concrete one — this is unavoidable because `ReventlessInfra`
cannot see `ReventlessCore`'s concrete type definitions.

### Phase G — Counter: expose operations and outputs (2 occurrences)

Added `let operations` and `let outputs` to `ReventlessInfra.Counter.T` module type and
`Counter_Builder.res` implementation.

Fixed:
- `CounterFixtures.res` — now uses `CounterMaker.operations(counter)`
- `EventMapper_Builder.res` — now uses `Counter.operations(counter)` and `Counter.outputs(counter)`

---

## Not Planned (Acceptable Uses)

| Location | Reason |
|---|---|
| `Plugin_Builder.res` line 188, `Query.res` line 40 — Pulumi StackReference JSON | Pulumi outputs are inherently untyped at the TS/JS boundary; `Obj.magic: JSON.t` is the established pattern |
| `AggregateFixtures.res`, `EventLogFixtures.res` — `Obj.magic(0)` in stub `make` | Intentional never-called stub; well-documented pattern |
| `HeartbeatRunner_InMemory.res`, HeartbeatTest, CounterHandlerTest — `Obj.magic(())` for unused params | Stub for unused parameters; not worth typing separately |
| `CommandGeneratorFixtures.res`, `CommandGeneratorTest.res` — test payload | CommandGenerator payloads are inherently `unknown` at the test level |
| `DurationTest.res` — `toBeTruthy` on opaque Duration | Tests that opaque values are non-null/non-undefined; acceptable in test code |
| `HeartbeatTest.res` — Deferred setup | Effect internal, small scope |
| `Plugin_Helpers.res` — narrow operations coercion (2) | Abstract→concrete type boundary; `operations()` added but result type remains abstract at infra level |

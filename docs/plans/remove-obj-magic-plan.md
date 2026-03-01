# Plan: Remove Obj.magic Usages

## Status

| Phase | Status | Notes |
|---|---|---|
| A | pending | DcbTag lines 107, 142 |
| B | **done** | `Exit.match` added; `exitCausePayload` removed. `EventLog_Operations.res` change staged but not committed. |
| C | pending | |
| D | pending | |
| E | pending | |
| F | pending | |
| G | pending | |

## Overview

There are ~50 `Obj.magic` usages in the codebase. This plan eliminates or replaces them
where doing so is practical and improves type safety. Some uses are intentional and
remain documented as acceptable.

## Current Inventory

| Category | Count | Files |
|---|---|---|
| Exception coercion to `JsExn.t` | 9 | EventLog_Operations, CommandTopic_Callback, DcbEventLog/EventLogStorage_DynamoDb_Runtime, QueryDbStorage_DynamoDb_Runtime |
| Effect `_tag` inspection | 7 | EffectTest, ExitTest, TestClockTest |
| Schema introspection (`S.t`) | 2 | DcbTag |
| `exitCausePayload` hack | ~~1~~ 0 | ~~EventLog_Operations~~ (Phase B done) |
| Module sealing (EP / Extension) | 2 | Plugin_Helpers |
| Counter.T operations access | 1 | CounterFixtures |
| GraphQL args coercion | 4 | QueryDbResolvers_GraphQL |
| Heartbeat remote channel stub | 5 | HeartbeatRunner_InMemory, HeartbeatTest (x4) |
| CounterHandler stub params | 3 | CounterHandlerTest |
| EventMapper Builder coercion | 1 | EventMapper_Builder |
| Heartbeat Deferred setup | 2 | HeartbeatTest |
| CommandGenerator test payload | 4 | CommandGeneratorFixtures, CommandGeneratorTest |
| Pulumi StackReference JSON | 2 | Plugin_Builder, Query |
| Mock builders (never called) | 2 | AggregateFixtures, EventLogFixtures |
| Promise.reject coercion | 1 | EffectTest |
| Duration opaque value tests | 5 | DurationTest |

---

## Phases

### Phase A — DcbTag: use existing `toUnknownSchema` external (2 occurrences)
**Effort: trivial | Risk: zero**

`DcbTag.res` already declares:
```rescript
external toUnknownSchema: S.t<'a> => S.t<unknown> = "%identity"
```
used on lines 27 and 99. But lines 107 and 142 still use `Obj.magic` to do the same coercion:
```rescript
// line 107
let unknownSchema: S.t<unknown> = schema->Obj.magic
// line 142
let unknownSchema: S.t<unknown> = schema->Obj.magic
```
Replace both with `schema->toUnknownSchema`.

### Phase B — Add `Exit.match` binding; replace `exitCausePayload` hack (1 occurrence)
**Effort: small | Risk: low**

`EventLog_Operations.res` line 100 uses a private type alias to extract the `Cause` from
a failed `Exit`:
```rescript
type exitCausePayload<'e> = {cause: Cause.t<'e>}
...
let payload: exitCausePayload<string> = exit->Obj.magic
payload.cause->Cause.failures->Array.get(0)->Option.getOr("storage error")
```
Effect v3 exports `Exit.match(exit, onFailure, onSuccess)`. Add the binding to
`rescript-effect/src/Exit.res`:
```rescript
@module("effect") @scope("Exit")
external match: (t<'a, 'e>, Cause.t<'e> => 'b, 'a => 'b) => 'b = "match"
```
Then replace the production code with:
```rescript
let failMsg = exit->Exit.match(
  cause => cause->Cause.failures->Array.get(0)->Option.getOr("storage error"),
  _ => "storage error", // unreachable: we are in the isFailure branch
)
```
Also remove the now-unused `exitCausePayload` type alias.

### Phase C — Add `EffectOption` module; replace `_tag` inspection (7 occurrences)
**Effort: small–medium | Risk: low**

`Effect.option` and `Exit.causeOption` return Effect's `Option` type
(`{_id:"Option", _tag:"Some"|"None"}`), not ReScript's `option`. The current bindings
type them as `option<'a>` which is misleading, causing test code to use `Obj.magic` to
access `._tag`.

**Step C1**: Add `rescript-effect/src/EffectOption.res`:
```rescript
/** Effect's internal Option type — different from ReScript's `option`. */
type t<'a>

@get external _tag: t<'a> => string = "_tag"
let isSome: t<'a> => bool = opt => opt->_tag == "Some"
let isNone: t<'a> => bool = opt => opt->_tag == "None"

/** Extracts the value if Some, otherwise returns the fallback. */
@module("effect") @scope("Option")
external getOrElse: (t<'a>, unit => 'a) => 'a = "getOrElse"
```

**Step C2**: Update `Exit.res` — change `causeOption` return type:
```rescript
external causeOption: t<'a, 'e> => EffectOption.t<Cause.t<'e>> = "causeOption"
```

**Step C3**: Update `Effect.res` — change `option` return type:
```rescript
// The ~catch handler receives Effect.option result as EffectOption.t
external option: t<'a, 'e, 'r> => t<EffectOption.t<'a>, 'e2, 'r> = "option"
```

**Step C4**: Update the 7 test occurrences:
```rescript
// Before:
let tag: string = (v->Obj.magic)["_tag"]
expect(tag)->toBe("Some")

// After:
expect(v->EffectOption.isSome)->toBe(true)
```
Files: `EffectTest.res` (lines 115, 121), `ExitTest.res` (lines 41, 48),
`TestClockTest.res` (line 52), `Fiber.res` doc comment update.

### Phase D — Add `messageFromCaught` utility; replace JsExn coercions (9 occurrences)
**Effort: small | Risk: low**

All 9 occurrences follow the same pattern inside an Effect `~catch` handler (which
receives `unknown`) or a DynamoDB error handler:
```rescript
(err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("storage error")
```

Add a helper to `reventless-core/src/Util.res` (or a new `Util_Error.res`):
```rescript
/** Safely extracts a message string from any caught JS exception-like value. */
let messageFromUnknown: (unknown, string) => string = %raw(`
  function(err, fallback) {
    if (err != null && typeof err.message === 'string') return err.message;
    return fallback;
  }
`)
```
Then each occurrence becomes:
```rescript
// ~catch handler (Effect.tryPromise / Effect.trySync)
~catch=(err: unknown) => Util.Error.messageFromUnknown(err, "storage error")

// Standalone error handler
Util.Error.messageFromUnknown(err, "DynamoDB replay error")
```

Files affected:
- `reventless-core/src/components/EventLog/EventLog_Operations.res` (line 84)
- `reventless-core/src/components/CommandTopic/CommandTopic_Callback.res` (line 34)
- `reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` (lines 43, 57)
- `reventless-aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` (lines 391, 434, 501)
- `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` (line 10)

Note: `CommandTopic_Callback.res` line 34 also passes the `JsExn.t` value to `Logger.error`.
The replacement must ensure `Logger.error` still receives a usable value (may need a second
argument carrying the original `unknown` for logging).

### Phase E — GraphQL args coercion: use JSON.Decode (4 occurrences)
**Effort: small | Risk: low**

`QueryDbResolvers_GraphQL.res` uses `(args->Obj.magic: dict<string>)` to access resolver
arguments that arrive as `JSON.t`. Replace with proper JSON decoding:
```rescript
// Before:
let id = (args->Obj.magic: dict<string>)->Dict.get("id")->Option.getOr("")

// After:
let id = args
  ->JSON.Decode.object
  ->Option.flatMap(dict => dict->Dict.get("id"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("")
```
Apply the same pattern for `subIdField` index lookups (lines 95, 100).

### Phase F — Module type: expose operations on Extension.T / ExtensionPoint.T (2 occurrences)
**Effort: medium | Risk: medium**

`Plugin_Helpers.res` lines 289, 319 cast the return value of `SpecificExtensionPoint.make`
and `SpecificExtension.make` to concrete component types in order to call
`Component.operations`:
```rescript
let concreteEP: ExtensionPoint.component<ExtensionPoint.operations> = Obj.magic(extensionPoint)
```
The root cause: `Reventless.ExtensionPoint.T` module type's `make` function returns
`component` (or a private type), but callers need to call `Component.operations` on the
result.

Fix: add an `operations` function to `ExtensionPoint.T` and `Extension.T` that returns
the result of `Component.operations`. The module type change is:
```rescript
module type T = {
  ...
  let operations: component => Pulumi.Output.t<operations>
}
```
And each implementation provides `let operations = Component.operations`. Then
`Plugin_Helpers.res` calls `SpecificExtensionPoint.operations(extensionPoint)` instead
of the Obj.magic coercion.

This requires updating:
- `reventless-spec/src/components/ExtensionPoint/ExtensionPoint.res` (module type T)
- `reventless-spec/src/components/Extension/Extension.res` (module type T)
- All concrete implementations of ExtensionPoint.T and Extension.T
- `Plugin_Helpers.res`

### Phase G — Counter: expose component type for test access (1 occurrence)
**Effort: small | Risk: low**

`CounterFixtures.res` line 43:
```rescript
let c: ReventlessCore.Counter.component = counter->Obj.magic
```
This is needed because `Counter.T` seals the return type of `make`.

Add to `Counter.res`:
```rescript
let getComponent: (module(T)) => component = (module(M)) => M.make(...)  // or expose differently
```
Or, more practically, expose an `asComponent` accessor:
```rescript
// In Counter.T or Counter module:
let asComponent: component => Reventless.Component.t<operations> = Obj.magic
```
Alternatively, restructure `CounterFixtures.res` to use `Component.operations` via a
helper that `Counter_Builder.Make` exposes. The exact approach depends on what
operations the test needs.

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
| `EventMapper_Builder.res` — Counter coercion | Same root cause as Phase G; fix when Counter.T is fixed |

---

## Execution Order

| Phase | Dependency | Est. files changed |
|---|---|---|
| A | None | 1 |
| B | None (adds Exit.match binding) | 2 |
| C | None (adds EffectOption module) | 5–6 |
| D | A utility helper exists | 5–6 |
| E | None | 1 |
| F | Phase B for context | 5–10 |
| G | Phase F for context | 2–3 |

Phases A–E can be done in any order or in parallel. Phase F and G are
architectural and should be done after the quick wins.

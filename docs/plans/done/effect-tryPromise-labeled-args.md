# Plan: Labeled Argument API for `Effect.tryPromise` / `Effect.trySync`

## Problem

`Effect.tryPromise` and `Effect.trySync` bound the Effect.ts JavaScript API directly
using a JS object literal, which is not idiomatic ReScript:

```rescript
Effect.tryPromise({
  "try": () => fetch("/api/data"),
  "catch": err => NetworkError(err->JsExn.fromException->Option.flatMap(JsExn.message)),
})
```

### Why the object form existed

Two forces converged on this shape:

**1. The Effect.ts JavaScript API takes an options object.**
`Effect.tryPromise({ try: fn, catch: fn })` is the verbatim JS call. A direct
`external` binding with a JS object literal compiles to exactly this — zero wrapper code.

**2. `try` and `catch` are reserved keywords in ReScript.**
`~try` is a parse error. `~catch` was assumed to be one too — `catch` is used as a
keyword in `try { } catch { }` expressions. Whether it was also in the keyword table
for identifiers was unverified.

### The docstring inconsistency

The `Effect.retry` docstring already showed the desired form without it being implemented:

```rescript
Effect.tryPromise(~catch=classifyError, fetchData)
->Effect.retry(Schedule.exponential(...))
```

This was aspirational — a signal that the labeled form was already desired.

---

## Analysis: Viable Approaches

### Approach A — Semantically Renamed Labels

```rescript
let tryPromise = (~attempt: unit => promise<'a>, ~onError: unknown => 'e) =>
  _tryPromiseRaw({"try": attempt, "catch": onError})
```

**Pros:** No keyword conflicts, safe to compile.
**Cons:** Departs from Effect.ts naming; `~attempt` is verbose; both labeled so neither
is privileged for piping.

### Approach B — Positional Thunk, Labeled Error Mapper

```rescript
let tryPromise = (~onError: unknown => 'e, f: unit => promise<'a>) =>
  _tryPromiseRaw({"try": f, "catch": onError})
```

**Pros:** Consistent with `Effect.promise`/`Effect.sync` (bare positional thunk);
`~onError` reads naturally; partial application works.
**Cons:** `~onError` rather than `~catch` — diverges from Effect.ts docs and the
existing docstring example.

### Approach C — `~catch_` Trailing Underscore

```rescript
let tryPromise = (~catch_ as onError: unknown => 'e, f: unit => promise<'a>) => ...
```

**Pros:** Recognizable to Effect.ts users; follows ReScript convention (`open_`, `close_`).
**Cons:** Trailing underscore looks awkward; leaks the reserved-word workaround.

### Approach D — `~catch` ✅ Chosen

Verify whether `~catch` parses. If it does, it is strictly better than the others.

Verified by compilation on 2026-03-01:

```rescript
// scratch test
let f = (~catch as onError: unknown => string, g: unit => promise<string>) => {
  ignore(onError)
  ignore(g)
}
// Compiled output: function f(onError, g) { }
```

`catch` is contextual in `try { } catch { }` expressions but is **not** in the keyword
table for identifiers. The compiler accepts `~catch`.

The `as onError` alias is **mandatory**: the compiler cannot emit `catch` as a JS
identifier (it is a JS reserved word), so the alias is required internal syntax.
It is invisible to callers.

---

## Decision

**Approach D.** Raw externals kept private (`_tryPromiseRaw`, `_trySyncRaw`); wrappers
are the sole public API:

```rescript
let tryPromise = (~catch as onError: unknown => 'e, f: unit => promise<'a>): t<'a, 'e, 'r> =>
  _tryPromiseRaw({"try": f, "catch": onError})

let trySync = (~catch as onError: unknown => 'e, f: unit => 'a): t<'a, 'e, 'r> =>
  _trySyncRaw({"try": f, "catch": onError})
```

---

## Implementation

- [x] Rename `tryPromise` external to `_tryPromiseRaw`
- [x] Add public `let tryPromise = (~catch as onError, f)` wrapper
- [x] Rename `trySync` external to `_trySyncRaw`
- [x] Add public `let trySync = (~catch as onError, f)` wrapper
- [x] Update docstrings for both functions to show new call-site form
- [x] Update `retry` docstring example (was already correct, now accurate)
- [x] Migrate 7 `tryPromise` call sites across `reventless-core` and `reventless-aws`
- [x] Migrate 1 `trySync` call site (`EventCollector_Builder.res`)
- [x] Migrate 2 `tryPromise` call sites in `EffectTest.res`
- [x] Add 4 `trySync` tests to `EffectTest.res`

---

## Result

```rescript
// Before
Effect.tryPromise({
  "try": () => fetch("/api/data"),
  "catch": err => NetworkError(err),
})

// After
Effect.tryPromise(~catch=err => NetworkError(err), () => fetch("/api/data"))
```

Partial application works: `let liftDynamo = Effect.tryPromise(~catch=classifyDynamoError)`

All 126 tests pass, zero warnings.

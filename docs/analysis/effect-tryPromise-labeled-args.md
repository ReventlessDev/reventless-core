# Analysis: Labeled Argument API for `Effect.tryPromise` / `Effect.trySync`

## Background

`Effect.tryPromise` and `Effect.trySync` currently bind the Effect.ts JavaScript API
directly using a JS object literal:

```rescript
@module("effect") @scope("Effect")
external tryPromise: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"
```

Call site today:

```rescript
Effect.tryPromise({
  "try": () => fetch("/api/data"),
  "catch": err => NetworkError(err->JsExn.fromException->Option.flatMap(JsExn.message)),
})
```

The question is whether a labeled-argument API would be more idiomatic ReScript and
worth the change.

---

## Why the Object Form Exists

Two forces converge on the current shape:

**1. The Effect.ts JavaScript API takes an options object.**
`Effect.tryPromise({ try: fn, catch: fn })` is the verbatim JS call. A direct
`external` binding with a JS object literal compiles to exactly this — zero wrapper code.

**2. `try` and `catch` are reserved keywords in ReScript.**
They cannot appear as labeled argument names. `~try` and `~catch` are parse errors:

```rescript
// Compile error — `try` is a keyword
let f = (~try: unit => 'a) => ...

// Likely compile error — `catch` is a contextual keyword in ReScript's
// `try { } catch { }` syntax
let f = (~catch: unknown => 'e) => ...
```

This is the core constraint. A labeled-argument version cannot use the canonical
Effect.ts names without a rename.

---

## The Docstring Inconsistency

The `Effect.retry` docstring (line 205) already shows an aspirational labeled API:

```rescript
Effect.tryPromise(~catch=classifyError, fetchData)
->Effect.retry(Schedule.exponential(...))
```

This form does not match the current implementation. It was written to show what an
ergonomic call site would look like in a pipeline, but it describes a function that
does not exist yet. This inconsistency is a signal that the labeled form is already
desired.

---

## Viable Approaches

### Approach A — Semantically Renamed Labels

Rename both parameters to avoid keyword conflicts:

```rescript
@module("effect") @scope("Effect")
external _tryPromiseRaw: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"

let tryPromise = (~attempt: unit => promise<'a>, ~onError: unknown => 'e) =>
  _tryPromiseRaw({"try": attempt, "catch": onError})
```

Call site:

```rescript
Effect.tryPromise(~attempt=() => fetch("/api"), ~onError=err => NetworkError(err))
```

**Pros:**
- No keyword conflicts, safe to compile
- Clear intent: `attempt` = the thing that might fail, `onError` = the recovery mapper

**Cons:**
- Departs from Effect.ts naming convention that TypeScript users know
- `~attempt` is verbose; the thunk is the "main" argument and deserves to be positional
- Both parameters are labeled, so neither has a privileged position for piping

---

### Approach B — Positional Thunk, Labeled Error Mapper

Make the primary computation positional and label only the mapper:

```rescript
let tryPromise = (~onError: unknown => 'e, f: unit => promise<'a>) =>
  _tryPromiseRaw({"try": f, "catch": onError})
```

Call site:

```rescript
Effect.tryPromise(~onError=err => NetworkError(err), () => fetch("/api"))

// Or with partial application — define a typed "lifter" for a whole module:
let liftFetch = Effect.tryPromise(~onError=classifyHttpError)
liftFetch(() => fetch("/api"))
```

**Pros:**
- The thunk is positional — matches how `Effect.promise` and `Effect.sync` work,
  which take `(unit => 'a)` directly
- Labeled `~onError` reads naturally in a pipeline: "try this promise, on error do..."
- Partial application to curry a typed error classifier across multiple call sites

**Cons:**
- `~onError` rather than `~catch` — diverges from Effect.ts docs and the existing
  docstring example
- Positional `f` at the end means it cannot be the pipe receiver (pipe feeds left-arg)

---

### Approach C — `~catch_` Convention (Trailing Underscore)

If the goal is maximum fidelity to Effect.ts terminology, use the ReScript convention
of appending `_` to reserved identifiers:

```rescript
let tryPromise = (~catch_ as onError: unknown => 'e, f: unit => promise<'a>) =>
  _tryPromiseRaw({"try": f, "catch": onError})
```

Call site:

```rescript
Effect.tryPromise(~catch_=classifyError, () => fetch("/api"))
```

`try_` is not viable because `try` is definitely a keyword, but `catch_` avoids the
question of whether `catch` is reserved by sidestepping it entirely.

**Pros:**
- Recognizable to Effect.ts users — `catch_` visually echoes `catch`
- Follows existing ReScript convention (e.g. `open_`, `close_` in standard libs)

**Cons:**
- The trailing underscore looks awkward at call sites
- It signals "reserved word workaround" which leaks an implementation detail

---

### Approach D — The Docstring Form: `~catch`

The docstring example uses `~catch`. Whether this is valid ReScript depends on whether
`catch` is a true reserved keyword or only a contextual one. In OCaml, `try...with`
uses `with` (a keyword); ReScript replaced it with `try...catch` to be JS-familiar.
If `catch` is in ReScript's keyword table, `~catch` is a syntax error.

**This needs to be verified experimentally** before committing to it in a public API.
If `~catch` parses, it is the ideal form — it exactly matches the docstring, mirrors
Effect.ts, and reads as natural English at the call site:

```rescript
Effect.tryPromise(~catch=classifyError, fetchData)
->Effect.retry(Schedule.exponential(Duration.millis(200))->Schedule.recurs(5))
```

If `~catch` does NOT parse, this approach is eliminated.

---

## Impact on Existing Call Sites

There are currently **7 call sites** across the codebase
(`reventless-core`, `reventless-aws`). All follow the same shape:

```rescript
Effect.tryPromise({
  "try": () => someOperation(...),
  "catch": (err: unknown) => (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("..."),
})
```

A migration to Approach B would mechanically transform each to:

```rescript
Effect.tryPromise(
  ~onError=(err: unknown) => (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("..."),
  () => someOperation(...),
)
```

The change is purely syntactic — identical semantics, same compiled output modulo one
extra function call frame.

`trySync` has **1 call site** (`EventCollector_Builder.res`) with the same pattern.

---

## Compiled JS Output

The raw `external` emits no wrapper — it is a zero-cost binding. A wrapper function
adds one extra JS function call per invocation. For Effect operations, where the thunk
itself is the expensive part and Effect's fiber scheduler adds its own overhead, this
is negligible. It is not a performance concern.

The compiled output for the raw form:
```js
Effect.tryPromise({ try: f, catch: onError })
```

The compiled output for the wrapper form (Approach B):
```js
// wrapper definition (once, in the module)
function tryPromise(onError, f) {
  return Effect.tryPromise({ try: f, catch: onError })
}
// call site
tryPromise(classifyError, fetchData)
```

---

## Recommendation

**Implement Approach B (`~onError`, positional thunk) as the primary API.** Reasons:

1. **Consistent with `Effect.promise` and `Effect.sync`**: both take a bare positional
   thunk. `tryPromise` becomes the "same but with an error mapper tacked on."

2. **Partial application is genuinely useful**: `let liftDynamo = Effect.tryPromise(~onError=classifyDynamoError)` creates a typed lifter that can be applied to many call sites without repeating the error classifier.

3. **No keyword ambiguity**: `~onError` is unambiguous and compiles safely.

4. **Migration is mechanical**: all 7 call sites follow the same pattern and can be
   updated as a batch.

**Additionally: test whether `~catch` parses.** If it does, Approach D is strictly
better and should be used instead — it aligns the library with Effect.ts terminology
and matches the existing docstring at line 205. The test is a one-line scratch file:

```rescript
// scratch.res — if this compiles, Approach D is viable
let f = (~catch as onError: unknown => string, g: unit => promise<string>) =>
  ignore((onError, g))
```

**Either way: keep the raw `external` as `_tryPromiseRaw`** (or an opaque module-internal
binding) so the wrapper remains the sole public API. This preserves the option to
change the labeled names later without a breaking change to the JS interop layer.

---

## Scope

This analysis covers `tryPromise` and `trySync` — both have the same keyword problem
and both benefit from the same solution. `trySync` has one call site and is a simpler
migration.

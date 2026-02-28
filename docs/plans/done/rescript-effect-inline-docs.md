# rescript-effect: Inline Documentation Plan

**Status:** Done

**Created:** 2026-02-28
**Completed:** 2026-02-28

**Goal:** Every binding in `rescript/rescript-effect/src/` should carry a `/** */` doc comment
that appears in the IDE hover tooltip, showing a description, type semantics, usage example,
and any caveats — all drawn from the upstream Effect library documentation.

---

## 1. Current State vs Goal

All 17 files today use `// ...` line comments.
These comments are visible only when reading the source file — they do **not** appear in
IDE hover tooltips.

```rescript
// An effect that always succeeds with the given value   ← invisible in hover
@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"
```

The goal is `/** */` doc comments (JSDoc-style Markdown), which the ReScript LSP surfaces
in VS Code hover and autocomplete:

```rescript
/** Creates an `Effect` that always succeeds with the given value. */
@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"
```

The type signature is already shown by the LSP. Doc comments add the *why* and *how*.

---

## 2. Comment Format

ReScript uses `/** ... */` for doc comments. Content is rendered as Markdown.
Placement: directly above the declaration (no blank line between comment and binding).

> **Important discovery during implementation:** The ReScript LSP does **not** strip
> leading ` * ` from continuation lines in multi-line `/** */` comments. Each ` * text`
> line is passed raw to the Markdown renderer, where `* ` becomes a bullet list item and
> ` * ```rescript` breaks the code fence. The correct format uses **no leading asterisks**.

### Template

```rescript
/**
One-line summary in imperative mood.

Optional extended description — semantics, when to prefer this over alternatives,
relationship to other bindings.

**Example**
```rescript
// idiomatic pipeline showing typical usage
```

> **Note** Caveats, ReScript-specific adaptations, or Effect v3 gotchas.
*/
@module("effect") @scope("Module")
external name: signature = "jsName"
```

For single-line comments both formats work: `/** Short description. */`

Rules:
- Content lines have **no** leading ` * ` prefix — content starts at column 0.
- The first sentence appears in autocomplete previews — keep it ≤ 80 chars.
- Examples should be copy-paste runnable (open no implicit modules).
- Caveats from existing `//` comments are preserved and promoted to the doc body.
- Module-level file header: replace `// ...` block with a `/** */` comment before the
  first `type` declaration.

---

## 3. Examples

### 3.1 `Effect.succeed` — simple constructor

```rescript
/**
Creates an `Effect` that succeeds immediately with `value`.

Use this to lift a pure value into the Effect world, for example as a
base case in a chain or when a function must return an `Effect` but has
nothing async to do.

**Example**
```rescript
let greet = Effect.succeed("hello")
// greet: Effect.t<string, 'e, 'r>

greet->Effect.map(s => s ++ " world")->Effect.runSync
// "hello world"
```
*/
@module("effect") @scope("Effect")
external succeed: 'a => t<'a, 'e, 'r> = "succeed"
```

---

### 3.2 `Effect.tryPromise` — Promise integration with typed errors

```rescript
/**
Wraps a `Promise`-returning thunk and maps thrown exceptions to typed errors.

- `"try"`: the thunk that produces the `Promise`.
- `"catch"`: maps the caught `unknown` exception to a value of type `'e`.

This is the standard entry point for converting existing async functions into
the Effect world. Unlike `Effect.promise`, failures surface in the typed `'e`
channel instead of as defects.

**Example**
```rescript
type fetchError = NetworkError(string) | NotFound

let fetchUser = (id: string) =>
  Effect.tryPromise({
    "try": () => fetch("/users/" ++ id)->Promise.then(r => r->Response.json),
    "catch": exn => switch exn->JsExn.fromException {
      | Some(e) => NetworkError(e->JsExn.message->Option.getOr("unknown"))
      | None    => NetworkError("unknown")
    },
  })
// Effect.t<JSON.t, fetchError, never>
```

> **Note** Exceptions thrown by the `catch` mapper itself become *defects*
> (untyped failures) — keep the mapper pure.
*/
@module("effect") @scope("Effect")
external tryPromise: {
  "try": unit => promise<'a>,
  "catch": unknown => 'e,
} => t<'a, 'e, 'r> = "tryPromise"
```

---

### 3.3 `Effect.retry` + `Schedule` composition

```rescript
/**
Retries a failing `Effect` according to the given `Schedule`.

The `Effect` is re-run each time it fails. The `Schedule` receives the
failure value and decides whether — and after how long — to retry.
When the `Schedule` stops, the most recent failure is returned.

Combine with `Schedule.exponential`, `Schedule.jittered`, and
`Schedule.recurs` to build production-grade retry policies.

**Example**
```rescript
// Retry up to 5 times with exponential backoff + jitter
Effect.tryPromise(~catch=classifyDdbError, () => client->DynamoDB.put(params))
->Effect.retry(
  Schedule.exponential(Duration.millis(500))
  ->Schedule.jittered
  ->Schedule.recurs(5),
)
```

> **Note** `Schedule.recurs(n)` adds *n* retries (total attempts = n + 1).
> To avoid retrying on certain error variants use `Schedule.whileInput`.
*/
@module("effect") @scope("Effect")
external retry: (t<'a, 'e, 'r>, schedule<'out, 'e, 'r2>) => t<'a, 'e, 'r | 'r2> = "retry"
```

---

### 3.4 `Schedule.exponential` and combinators

```rescript
/**
A `Schedule` with exponentially increasing delays: `base`, `2×base`, `4×base`, …

Pair with `Schedule.jittered` to add random variance and prevent
thundering-herd problems, and with `Schedule.recurs` to cap the number
of retries.

**Example**
```rescript
// 100 ms → 200 ms → 400 ms, up to 3 retries
let policy =
  Schedule.exponential(Duration.millis(100))
  ->Schedule.jittered
  ->Schedule.recurs(3)

someEffect->Effect.retry(policy)
```
*/
@module("effect") @scope("Schedule")
external exponential: Duration.t => t<Duration.t, 'in_, 'r> = "exponential"

/**
Adds random jitter to the delay of a `Schedule`.

Each interval is multiplied by a random factor in `[0.0, 1.0)`, so the
actual delay is between zero and the nominal interval. This prevents
multiple clients retrying in lock-step after a shared failure.

**Example**
```rescript
Schedule.exponential(Duration.seconds(1))->Schedule.jittered
```
*/
@module("effect") @scope("Schedule")
external jittered: t<Duration.t, 'in_, 'r> => t<Duration.t, 'in_, 'r> = "jittered"

/**
Limits a `Schedule` to at most `n` additional recurrences.

The schedule terminates after `n` successful recurrences regardless of
what the underlying schedule would do. Combined with `exponential`, this
caps the total number of retries.

> **Note** `recurs(n)` produces **n recurrences** (re-runs after the
> first attempt), giving **n + 1 total attempts**.

**Example**
```rescript
Schedule.exponential(Duration.millis(200))->Schedule.recurs(4)
// up to 5 total attempts: initial + 4 retries
```
*/
@module("effect") @scope("Schedule")
external recurs: int => t<int, 'in_, 'r> = "recurs"
```

---

### 3.5 `Stream.fromIterable` and pipeline

```rescript
/**
Creates a `Stream` that emits each element of an array (or any iterable).

Elements are emitted lazily one at a time as downstream consumers pull
them. This is the standard way to turn an in-memory collection into a
`Stream` for further transformation or fan-out.

**Example**
```rescript
Stream.fromIterable([1, 2, 3, 4, 5])
->Stream.filter(n => mod(n, 2) == 0)
->Stream.map(n => n * 10)
->Stream.runCollect
->Effect.runPromise
// resolves to [20, 40]
```
*/
@module("effect") @scope("Stream")
external fromIterable: array<'a> => t<'a, 'e, 'r> = "fromIterable"
```

---

### 3.6 Module-level doc comment (file header)

The `// ...` block at the top of each file is replaced with `/** */`.
This shows in hover when the user types `Effect.` and sees the module description.

```rescript
/**
ReScript bindings for `Effect<A, E, R>` — the core type of the Effect library.

The three type parameters represent:
- `'a` — the success value
- `'e` — typed expected errors (recoverable failures)
- `'r` — requirements / dependencies (use `unit` for none)

Effects are **lazy and referentially transparent**: they describe a
computation without executing it. Run with `Effect.runPromise` (async) or
`Effect.runSync` (sync, throws on failure).

**Quick start**
```rescript
Effect.succeed(42)
->Effect.map(n => n * 2)
->Effect.runSync
// 84
```
*/
```

---

## 4. Scope

| File | Lines | Priority | Notes |
|---|---|---|---|
| `Effect.res` | 238 | **1** | Most-used file; ~35 externals + wrappers |
| `Stream.res` | 130 | **2** | 20+ bindings; complex paginateEffect caveats |
| `Schedule.res` | 66 | **3** | 15 bindings; retry composition examples critical |
| `Queue.res` | 72 | **4** | 10 bindings; used in PubSub + in-memory adapters |
| `Deferred.res` | 35 | **4** | 5 bindings; concurrency gotcha in existing comment |
| `Cause.res` | 54 | **5** | 8 bindings; parallel-failure semantics need explaining |
| `Exit.res` | 45 | **5** | 8 bindings; `getOrElse` vs missing `toOption` caveat |
| `Fiber.res` | 31 | **5** | 6 bindings; structured concurrency notes |
| `PubSub.res` | 59 | **6** | 8 bindings |
| `Ref.res` / `SynchronizedRef.res` | 35 + 33 | **6** | 8 + 6 bindings |
| `Stm.res` | 73 | **6** | 10 bindings |
| `Latch.res` | 27 | **7** | 4 bindings |
| `Duration.res` | 19 | **7** | 5 simple constructors |
| `TestClock.res` / `TestContext.res` | 26 + 18 | **7** | Test-only; short |
| `Layer.res` / `Logger.res` / `Context.res` | 48 + 36 + 22 | **8** | Less frequently used |

**Total:** ~17 files, ~1 067 lines, ~150 bindings to document.

---

## 5. Content Sources

For each binding, documentation content is drawn from (in priority order):

1. **Existing `//` inline comments** in the file — these are already accurate and
   ReScript-adapted; promote them to `/** */` and enrich.
2. **Effect TypeScript API reference** — `https://effect-ts.github.io/effect/` — the
   upstream JSDoc on each function is the canonical source of truth.
3. **Effect documentation website** — `https://effect.website/docs/` — narrative
   explanations and larger examples.

Adaptation rules when pulling from upstream TypeScript docs:
- Convert TypeScript snippets to ReScript pipelines.
- Replace `pipe(x, Effect.map(f))` with `x->Effect.map(f)`.
- Omit TypeScript-specific type import boilerplate.
- Retain all semantic caveats word-for-word.

---

## 6. Implementation Steps

- [x] **Effect.res** — documented all ~35 externals; updated module header.
- [x] **Schedule.res** — documented all combinators with retry composition examples.
- [x] **Stream.res** — documented construction, transformation, run functions; preserved
  `paginateEffect` wrapper caveat in its doc comment.
- [x] **Queue.res, Deferred.res** — concurrency primitives with motivating examples.
- [x] **Remaining files** — Cause, Exit, Fiber, Ref, SynchronizedRef, Stm, Latch.
- [x] **Test + utilities** — Duration, TestClock, TestContext, Layer, Logger, Context.

All 17 files updated. Built with zero warnings. Format bug (` * ` prefix rendered as
bullet list by LSP) discovered and fixed; all files use the no-asterisk format.
Committed as `d3459e6d` (19 files changed, +1106/-369 lines).

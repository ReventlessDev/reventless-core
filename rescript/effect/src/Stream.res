/**
ReScript bindings for `Stream<A, E, R>` — a lazy, composable, resource-safe sequence.

Streams integrate with Effect's structured concurrency: they can be interrupted,
paginated, and consumed one element at a time without materialising the whole
sequence in memory.

**Quick start**
```rescript
Stream.fromIterable([1, 2, 3])
->Stream.map(n => n * 10)
->Stream.runCollect
->Effect.runPromise
// resolves to [10, 20, 30]
```
*/
/** Core stream type — matches `Stream<A, E, R>` in the Effect TypeScript library. */
type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

/** Lifts a single `Effect` into a one-element `Stream`. */
@module("effect/Stream")
external fromEffect: Effect.t<'a, 'e, 'r> => t<'a, 'e, 'r> = "fromEffect"

/**
Creates a `Stream` that emits each element of an array (or any iterable).

**Example**
```rescript
Stream.fromIterable(events)
->Stream.filter(e => e.type == "Created")
->Stream.runCollect
->Effect.runPromise
```
*/
@module("effect/Stream")
external fromIterable: array<'a> => t<'a, 'e, 'r> = "fromIterable"

/**
Creates a `Stream` that drains a `Queue` until the queue is done.

The stream blocks waiting for new items. After `Queue.end_` it emits what is
still buffered and then terminates cleanly; `Queue.shutdown` stops it at once.
*/
@module("effect/Stream")
external fromQueue: Queue.t<'a> => t<'a, 'e, 'r> = "fromQueue"

/** Creates a `Stream` of every message published to a `PubSub` subscription. */
@module("effect/Stream")
external fromSubscription: PubSub.subscription<'a> => t<'a, 'e, 'r> = "fromSubscription"

/** An empty `Stream` that terminates immediately without emitting any elements. */
@module("effect/Stream")
external empty: t<'a, 'e, 'r> = "empty"

// Internal bindings used by the paginateEffect wrapper below.
@module("effect/Stream")
external paginateRaw: ('s, 's => Effect.t<(array<'a>, 'effectOption), 'e, 'r>) => t<'a, 'e, 'r> =
  "paginate"

// Converts ReScript option (None=undefined, Some=value) to Effect Option.
@module("effect/Option")
external toEffectOption: option<'a> => 'effectOption = "fromNullishOr"

/**
Paginates lazily using a cursor-based producer function.

The producer receives the current cursor and returns an `Effect` that
resolves to `(items, nextCursor)`:
- `items: array<'a>` — the elements for this page
- `nextCursor: option<'s>` — `Some(cursor)` to continue, `None` to stop

The stream emits individual elements; pages are fetched on demand.

> **Note** Internally maps to `Stream.paginate`, converting `option<'s>` → Effect `Option`.

**Example**
```rescript
Stream.paginateEffect(None, cursor =>
  fetchPage(cursor)->Effect.map(page => (page.items, page.nextCursor))
)
->Stream.runForEach(processItem)
->Effect.runPromise
```
*/
let paginateEffect = (initial: 's, f: 's => Effect.t<(array<'a>, option<'s>), 'e, 'r>): t<
  'a,
  'e,
  'r,
> => paginateRaw(initial, s => f(s)->Effect.map(((items, next)) => (items, toEffectOption(next))))

// ─── Transformation ──────────────────────────────────────────────────────

// Effect calls the mapper with (element, index); the wrappers below pass the
// element alone, so a function with an optional second parameter is safe.
@module("effect/Stream")
external mapRaw: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect/Stream")
external mapEffectRaw: (t<'a, 'e, 'r>, 'a => Effect.t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "mapEffect"

/** Transforms each element with a pure function. */
let map = (stream: t<'a, 'e, 'r>, f: 'a => 'b): t<'b, 'e, 'r> => stream->mapRaw(a => f(a))

/** Transforms each element with an effectful function, running effects sequentially. */
let mapEffect = (stream: t<'a, 'e, 'r>, f: 'a => Effect.t<'b, 'e, 'r>): t<'b, 'e, 'r> =>
  stream->mapEffectRaw(a => f(a))

/** Replaces each element with a new `Stream`, then concatenates all the streams. */
@module("effect/Stream")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

/** Keeps only elements for which the predicate returns `true`. */
@module("effect/Stream")
external filter: (t<'a, 'e, 'r>, 'a => bool) => t<'a, 'e, 'r> = "filter"

/**
Takes the first `n` elements then terminates the stream.

Upstream is interrupted resource-safely, so acquired resources are released.
*/
@module("effect/Stream")
external take: (t<'a, 'e, 'r>, int) => t<'a, 'e, 'r> = "take"

/** Runs an effectful side effect for each element without changing the stream. */
@module("effect/Stream")
external tap: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// ─── Terminal runners ────────────────────────────────────────────────────

/**
Groups consecutive stream elements into arrays of at most `n` elements.

The last array may have fewer than `n` elements if the stream ends before
a full group is assembled.

**Example**
```rescript
Stream.fromIterable([1, 2, 3, 4, 5])
->Stream.grouped(2)
->Stream.runCollect
->Effect.runPromise
// resolves to [[1, 2], [3, 4], [5]]
```
*/
@module("effect/Stream")
external grouped: (t<'a, 'e, 'r>, int) => t<array<'a>, 'e, 'r> = "grouped"

/**
Collects all stream elements into a plain JS array.

**Example**
```rescript
stream->Stream.runCollect->Effect.runPromise
// resolves to array<'a>
```
*/
@module("effect/Stream")
external runCollect: t<'a, 'e, 'r> => Effect.t<array<'a>, 'e, 'r> = "runCollect"

/**
Folds all stream elements into a single accumulated value using a pure function.

**Example**
```rescript
Stream.fromIterable([1, 2, 3])
->Stream.runFold(0, (acc, n) => acc + n)
->Effect.runPromise
// resolves to 6
```
*/
@module("effect/Stream")
external runFoldRaw: (t<'a, 'e, 'r>, unit => 's, ('s, 'a) => 's) => Effect.t<'s, 'e, 'r> = "runFold"

// Effect takes the initial value as a thunk.
let runFold = (stream: t<'a, 'e, 'r>, initial: 's, f: ('s, 'a) => 's): Effect.t<'s, 'e, 'r> =>
  stream->runFoldRaw(() => initial, f)

/**
Runs an effectful function for each element of the stream.

Returns `Effect.t<unit>` — use when the purpose is side effects (e.g. writing to storage).

**Example**
```rescript
stream->Stream.runForEach(item => saveItem(item))->Effect.runPromise
```
*/
@module("effect/Stream")
external runForEach: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => Effect.t<unit, 'e, 'r> =
  "runForEach"

/** Drains all stream elements, discarding values. Useful when the stream is run for side effects only. */
@module("effect/Stream")
external runDrain: t<'a, 'e, 'r> => Effect.t<unit, 'e, 'r> = "runDrain"

// Internal: Stream.runHead returns Effect's Option type (not ReScript's native option).
// Option.getOrUndefined converts it to value|undefined, which maps to ReScript option.
@module("effect/Stream")
external runHeadRaw: t<'a, 'e, 'r> => Effect.t<'effectOption, 'e, 'r> = "runHead"

@module("effect/Option")
external effectOptionGetOrUndefined: 'effectOption => option<'a> = "getOrUndefined"

/**
Returns `Some(first)` with the first element of the stream, or `None` for an empty stream.

> **Note** The native `Stream.runHead` returns an Effect `Option`. This wrapper converts
it to a standard ReScript `option<'a>`.
*/
let runHead = (stream: t<'a, 'e, 'r>): Effect.t<option<'a>, 'e, 'r> =>
  stream->runHeadRaw->Effect.map(effectOptionGetOrUndefined)

// ─── Error handling ──────────────────────────────────────────────────────

/**
Recovers from any stream error by switching to a fallback stream.

> **Note** Effect 4 calls this `catch`, a reserved word in ReScript.
*/
@module("effect/Stream")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catch"

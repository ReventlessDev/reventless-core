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
@module("effect") @scope("Stream")
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
@module("effect") @scope("Stream")
external fromIterable: array<'a> => t<'a, 'e, 'r> = "fromIterable"

/**
Creates a `Stream` that drains a `Queue` until the queue is shut down.

The stream blocks waiting for new items and terminates cleanly when
`Queue.shutdown` is called.
*/
@module("effect") @scope("Stream")
external fromQueue: Queue.t<'a> => t<'a, 'e, 'r> = "fromQueue"

/** An empty `Stream` that terminates immediately without emitting any elements. */
@module("effect") @scope("Stream")
external empty: t<'a, 'e, 'r> = "empty"

// Internal bindings used by the paginateEffect wrapper below.
@module("effect") @scope("Stream")
external paginateEffectRaw: ('s, 's => Effect.t<('chunk, 'effectOption), 'e, 'r>) => t<'a, 'e, 'r> =
  "paginateChunkEffect"

@module("effect") @scope("Chunk")
external chunkFromIterable: array<'a> => 'chunk = "fromIterable"

// Converts ReScript option (None=undefined, Some=value) to Effect Option.
@module("effect") @scope("Option")
external toEffectOption: option<'a> => 'effectOption = "fromNullable"

/**
Paginates lazily using a cursor-based producer function.

The producer receives the current cursor and returns an `Effect` that
resolves to `(items, nextCursor)`:
- `items: array<'a>` — the elements for this page
- `nextCursor: option<'s>` — `Some(cursor)` to continue, `None` to stop

The stream emits individual elements; pages are fetched on demand.

> **Note** Internally maps to `Stream.paginateChunkEffect`. Automatically converts
`array<'a>` → Effect `Chunk` and `option<'s>` → Effect `Option`.

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
> =>
  paginateEffectRaw(initial, s =>
    f(s)->Effect.map(((items, next)) => (chunkFromIterable(items), toEffectOption(next)))
  )

// ─── Transformation ──────────────────────────────────────────────────────

/** Transforms each element with a pure function. */
@module("effect") @scope("Stream")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

/** Transforms each element with an effectful function, running effects sequentially. */
@module("effect") @scope("Stream")
external mapEffect: (t<'a, 'e, 'r>, 'a => Effect.t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "mapEffect"

/** Replaces each element with a new `Stream`, then concatenates all the streams. */
@module("effect") @scope("Stream")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

/** Keeps only elements for which the predicate returns `true`. */
@module("effect") @scope("Stream")
external filter: (t<'a, 'e, 'r>, 'a => bool) => t<'a, 'e, 'r> = "filter"

// Internal binding — grouped returns Effect Chunks; the grouped wrapper below converts to arrays.
@module("effect") @scope("Stream")
external groupedRaw: (t<'a, 'e, 'r>, int) => t<'chunk, 'e, 'r> = "grouped"

/**
Takes the first `n` elements then terminates the stream.

Upstream is interrupted resource-safely, so acquired resources are released.
*/
@module("effect") @scope("Stream")
external take: (t<'a, 'e, 'r>, int) => t<'a, 'e, 'r> = "take"

/** Runs an effectful side effect for each element without changing the stream. */
@module("effect") @scope("Stream")
external tap: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// ─── Terminal runners ────────────────────────────────────────────────────

// Internal: Stream.runCollect returns Effect's Chunk type (not a plain JS array).
// The runCollect wrapper below converts it to a plain array via Array.from.
@module("effect") @scope("Stream")
external runCollectRaw: t<'a, 'e, 'r> => Effect.t<'chunk, 'e, 'r> = "runCollect"

@val external arrayFrom: 'chunk => array<'a> = "Array.from"

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
let grouped = (stream: t<'a, 'e, 'r>, n: int): t<array<'a>, 'e, 'r> =>
  stream->groupedRaw(n)->map(arrayFrom)

/**
Collects all stream elements into a plain JS array.

> **Note** The native `Stream.runCollect` returns an Effect `Chunk`. This wrapper
converts it to a standard `array<'a>` for ergonomic use in ReScript.

**Example**
```rescript
stream->Stream.runCollect->Effect.runPromise
// resolves to array<'a>
```
*/
let runCollect = (stream: t<'a, 'e, 'r>): Effect.t<array<'a>, 'e, 'r> =>
  stream->runCollectRaw->Effect.map(arrayFrom)

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
@module("effect") @scope("Stream")
external runFold: (t<'a, 'e, 'r>, 's, ('s, 'a) => 's) => Effect.t<'s, 'e, 'r> = "runFold"

/**
Runs an effectful function for each element of the stream.

Returns `Effect.t<unit>` — use when the purpose is side effects (e.g. writing to storage).

**Example**
```rescript
stream->Stream.runForEach(item => saveItem(item))->Effect.runPromise
```
*/
@module("effect") @scope("Stream")
external runForEach: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => Effect.t<unit, 'e, 'r> =
  "runForEach"

/** Drains all stream elements, discarding values. Useful when the stream is run for side effects only. */
@module("effect") @scope("Stream")
external runDrain: t<'a, 'e, 'r> => Effect.t<unit, 'e, 'r> = "runDrain"

// Internal: Stream.runHead returns Effect's Option type (not ReScript's native option).
// Effect Option is {_id: "Option", _tag: "Some"/"None", value?}.
// Option.getOrUndefined converts it to value|undefined, which maps to ReScript option.
@module("effect") @scope("Stream")
external runHeadRaw: t<'a, 'e, 'r> => Effect.t<'effectOption, 'e, 'r> = "runHead"

@module("effect") @scope("Option")
external effectOptionGetOrUndefined: 'effectOption => option<'a> = "getOrUndefined"

/**
Returns `Some(first)` with the first element of the stream, or `None` for an empty stream.

> **Note** The native `Stream.runHead` returns an Effect `Option`. This wrapper converts
it to a standard ReScript `option<'a>`.
*/
let runHead = (stream: t<'a, 'e, 'r>): Effect.t<option<'a>, 'e, 'r> =>
  stream->runHeadRaw->Effect.map(effectOptionGetOrUndefined)

// ─── Error handling ──────────────────────────────────────────────────────

/** Recovers from any stream error by switching to a fallback stream. */
@module("effect") @scope("Stream")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"

// ─── Node.js interop ─────────────────────────────────────────────────────

/**
Bridges a Node.js `Readable` stream to an Effect `Stream` of string chunks.

The thunk `unit => 'readable` delays opening the file/socket handle until
the stream is actually consumed (lazy resource acquisition).

> **Note** Pass `NodeStreams.Readable.t` as the `'readable` type parameter.
The `int` argument sets the chunk size in bytes (e.g. `65536`).
*/
@module("effect") @scope("Stream")
external fromReadableStream: (unit => 'readable, int) => t<string, string, unit> =
  "fromReadableStream"

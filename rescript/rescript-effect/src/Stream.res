// ReScript bindings for Effect Stream
//
// Stream.t<'a, 'e, 'r> is a lazy, composable, resource-safe sequence.
// It integrates with Effect's structured concurrency: streams can be
// interrupted, paginated, and consumed one item at a time without
// materialising the whole sequence in memory.
//
// See docs/plans/effect-stream-integration.md for the full integration plan.

// Core type — matches Effect.Stream<A, E, R>
type t<'a, 'e, 'r>

// ─── Construction ────────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external fromEffect: Effect.t<'a, 'e, 'r> => t<'a, 'e, 'r> = "fromEffect"

@module("effect") @scope("Stream")
external fromIterable: array<'a> => t<'a, 'e, 'r> = "fromIterable"

// Drain a Queue until it is shut down
@module("effect") @scope("Stream")
external fromQueue: Queue.t<'a> => t<'a, 'e, 'r> = "fromQueue"

// Empty stream — terminates immediately
@module("effect") @scope("Stream")
external empty: t<'a, 'e, 'r> = "empty"

// Paginate with state cursor.
// Producer returns (chunk: array<'a>, nextCursor: option<'s>).
// Stream emits individual items; terminates when nextCursor is None.
// IMPORTANT: maps to JS "paginateChunkEffect" (chunk-based variant).
// Do NOT use JS "paginateEffect" — it takes one item per page, not a chunk.
//
// Internally, paginateChunkEffect expects Effect Chunk (not plain JS array)
// and Effect Option (not ReScript option). This wrapper converts automatically:
//   array<'a>  →  Chunk.fromIterable(array)
//   option<'s> →  Option.fromNullable(value|undefined)  (ReScript None = undefined)
@module("effect") @scope("Stream")
external paginateEffectRaw: ('s, 's => Effect.t<('chunk, 'effectOption), 'e, 'r>) => t<'a, 'e, 'r> =
  "paginateChunkEffect"

@module("effect") @scope("Chunk")
external chunkFromIterable: array<'a> => 'chunk = "fromIterable"

// Converts ReScript option (None=undefined, Some=value) to Effect Option.
@module("effect") @scope("Option")
external toEffectOption: option<'a> => 'effectOption = "fromNullable"

let paginateEffect = (initial: 's, f: 's => Effect.t<(array<'a>, option<'s>), 'e, 'r>): t<
  'a,
  'e,
  'r,
> =>
  paginateEffectRaw(initial, s =>
    f(s)->Effect.map(((items, next)) => (chunkFromIterable(items), toEffectOption(next)))
  )

// ─── Transformation ──────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external map: (t<'a, 'e, 'r>, 'a => 'b) => t<'b, 'e, 'r> = "map"

@module("effect") @scope("Stream")
external mapEffect: (t<'a, 'e, 'r>, 'a => Effect.t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "mapEffect"

@module("effect") @scope("Stream")
external flatMap: (t<'a, 'e, 'r>, 'a => t<'b, 'e, 'r>) => t<'b, 'e, 'r> = "flatMap"

@module("effect") @scope("Stream")
external filter: (t<'a, 'e, 'r>, 'a => bool) => t<'a, 'e, 'r> = "filter"

// Take first N items then stop (resource-safe upstream interruption)
@module("effect") @scope("Stream")
external take: (t<'a, 'e, 'r>, int) => t<'a, 'e, 'r> = "take"

@module("effect") @scope("Stream")
external tap: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => t<'a, 'e, 'r> = "tap"

// ─── Terminal runners ────────────────────────────────────────────────────

// Internal: Stream.runCollect returns Effect's Chunk type (not a plain JS array).
// The runCollect wrapper below converts it to a plain array via Array.from.
@module("effect") @scope("Stream")
external runCollectRaw: t<'a, 'e, 'r> => Effect.t<'chunk, 'e, 'r> = "runCollect"

@val external arrayFrom: 'chunk => array<'a> = "Array.from"

// runCollect — collects all stream items into a plain JS array.
// (Effect's native runCollect returns a Chunk; this wrapper converts it.)
let runCollect = (stream: t<'a, 'e, 'r>): Effect.t<array<'a>, 'e, 'r> =>
  stream->runCollectRaw->Effect.map(arrayFrom)

@module("effect") @scope("Stream")
external runFold: (t<'a, 'e, 'r>, 's, ('s, 'a) => 's) => Effect.t<'s, 'e, 'r> = "runFold"

@module("effect") @scope("Stream")
external runForEach: (t<'a, 'e, 'r>, 'a => Effect.t<unit, 'e, 'r>) => Effect.t<unit, 'e, 'r> =
  "runForEach"

@module("effect") @scope("Stream")
external runDrain: t<'a, 'e, 'r> => Effect.t<unit, 'e, 'r> = "runDrain"

// Internal: Stream.runHead returns Effect's Option type (not ReScript's native option).
// Effect Option is {_id: "Option", _tag: "Some"/"None", value?}.
// Option.getOrUndefined converts it to value|undefined, which maps to ReScript option.
@module("effect") @scope("Stream")
external runHeadRaw: t<'a, 'e, 'r> => Effect.t<'effectOption, 'e, 'r> = "runHead"

@module("effect") @scope("Option")
external effectOptionGetOrUndefined: 'effectOption => option<'a> = "getOrUndefined"

// runHead — returns Some(first item) or None for an empty stream.
let runHead = (stream: t<'a, 'e, 'r>): Effect.t<option<'a>, 'e, 'r> =>
  stream->runHeadRaw->Effect.map(effectOptionGetOrUndefined)

// ─── Error handling ──────────────────────────────────────────────────────

@module("effect") @scope("Stream")
external catchAll: (t<'a, 'e, 'r>, 'e => t<'a, 'e2, 'r>) => t<'a, 'e2, 'r> = "catchAll"

// ─── Node.js interop (Phase E) ────────────────────────────────────────────

// Bridge a Node.js Readable stream to an Effect Stream of string chunks.
// The thunk `unit => 'readable` delays opening the file handle until the
// stream is consumed. Pass NodeStreams.Readable.t as the 'readable type.
// The int argument is the chunk size in bytes (e.g., 65536).
@module("effect") @scope("Stream")
external fromReadableStream: (unit => 'readable, int) => t<string, string, unit> =
  "fromReadableStream"

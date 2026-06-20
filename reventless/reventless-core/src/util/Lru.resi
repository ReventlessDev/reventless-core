/**
A bounded, in-process least-recently-used cache.

Backs the StateChangeSlice decision-model projection cache
(`docs/plans/done/dcb-decision-model-projection-cache.md`): a warm Lambda
instance keeps the `(decisionState, readHead)` it last derived per query so the
next same-entity command reads only the delta instead of folding full history.

`get` and `put` both mark the key most-recently-used. Once `size` exceeds
`capacity`, `put` evicts the least-recently-used key. A `capacity <= 0` disables
the cache entirely (`get` always misses, `put` is a no-op) so a slice can opt out.
*/

type t<'k, 'v>

/** Creates an empty cache holding at most `capacity` entries (`<= 0` disables it). */
let make: (~capacity: int) => t<'k, 'v>

/** Looks up `key`, marking it most-recently-used on a hit. */
let get: (t<'k, 'v>, 'k) => option<'v>

/** Inserts/updates `key`, marking it most-recently-used and evicting the LRU entry if over capacity. */
let put: (t<'k, 'v>, 'k, 'v) => unit

/** Drops `key` if present. */
let invalidate: (t<'k, 'v>, 'k) => unit

/** Drops every entry. */
let clear: (t<'k, 'v>) => unit

/** Current number of live entries. */
let size: (t<'k, 'v>) => int

// Effect-specific test helper (not a Jest binding).
//
// Convert an Effect Chunk to a plain ReScript array. Effect functions like
// Queue.takeAll and Cause.failures return Chunk<A> (a persistent data
// structure), not a plain JS array; Jest's toEqual compares Chunk objects by
// shape, not by iterable contents — use arrayFrom first.
@val external arrayFrom: 'chunk => array<'a> = "Array.from"

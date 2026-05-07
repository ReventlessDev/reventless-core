# Plan: Monotonic Position Generation for DCB Event Log

**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md) — Consistency issue #5 ("smell, not a correctness issue under the new design")
**Sibling plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)

## Problem

`DcbEventLogStorage_DynamoDb_Runtime.generatePosition` returns `${Date.now()}-${uuidv4()}`. Two writers committing in the same millisecond get positions that sort by their UUIDs — which are random. Lexically, `"1700000000000-A..."` < `"1700000000000-B..."` is determined by the random UUID first character.

Under the **old** read-then-write design this could let conflicting events through if a concurrent writer's UUID happened to sort below the reader's `headPosition`. Under the **new** atomic-append design this is no longer a correctness issue — fence comparisons are anchored to what the slice observed, not to a globally monotonic counter, and `TransactWriteItems` serialises commits.

So this plan is a clean-up:

- Stop relying on millisecond resolution for ordering.
- Make event ordering predictable for readers and replays.
- Remove the cosmetic smell flagged in the original analysis.

## Goals

- A position generator whose output is strictly monotonic per call site within a single Lambda invocation.
- Cross-Lambda monotonicity within a single millisecond is *desirable* but not strictly required (no correctness invariant depends on it).
- Lexical ordering matches commit ordering for any two same-machine writes; "best effort" for cross-machine same-ms writes.
- Backwards-compatible with stored positions — old `${ms}-${uuid}` values must still parse and compare against new ones.

## Non-goals

- A globally distributed monotonic counter. That would require coordination (DynamoDB conditional update on a counter item, or atomic fetch-and-add via `UpdateItem` with `ADD`). The cost (extra round-trip per append) outweighs the benefit (cosmetic ordering).
- Replacing the format entirely. Keep the `${ms}-...` prefix so existing positions still sort sensibly.

## Approach

Hybrid Logical Clock (HLC) — minimal in-memory variant. Each Lambda instance keeps a per-process counter that increments within the same millisecond:

```rescript
// state local to the Lambda instance
let lastMs = ref(0)
let counter = ref(0)

let generatePosition = () => {
  let now = Date.make()->Date.getTime->Float.toInt
  if now == lastMs.contents {
    counter := counter.contents + 1
  } else {
    lastMs := now
    counter := 0
  }
  let counterStr = counter.contents->Int.toString->String.padStart(6, "0")
  let uuid = Uuid.v4()  // tiebreaker for cross-instance same-ms collisions
  `${now->Int.toString}-${counterStr}-${uuid}`
}
```

Format: `<msTimestamp>-<6-digit counter>-<uuid>`.

- Within one Lambda: strictly monotonic. The counter increments any same-ms call.
- Across Lambdas in the same ms: the counter resets to 0 on a different instance, so two writers can produce `1700000000000-000000-A...` and `1700000000000-000000-B...`. UUID breaks the tie. Same as today, but ordering is at least predictable per-instance.
- Across millisecond boundaries: timestamp dominates, ordering is correct.
- Existing `${ms}-${uuid}` positions: sort BEFORE new `${ms}-000000-uuid` positions in the same millisecond (`-${uuid}` vs `-000000-${uuid}` — `-0` (0x2D-0x30) is below most UUID chars). Slight discontinuity at deployment boundary but no comparison errors.

### Backwards compatibility

The fence's `lastPosition` is opaque — it's only ever compared against itself or against a slice's `headPosition`. Both come from the same generator at any given moment. As long as the generator is monotonic *forward* across the change, comparisons remain valid.

Existing fence sentinel items written with old positions remain valid: `lastPosition <= :after` works for any string format.

### Risk

`generatePositionForBatch(basePosition, idx)` currently does `${basePosition}-${idx}` for batch items. Under the new format that becomes `${ms}-${counter}-${uuid}-${idx}`. Still sorts lexically; safe.

## Steps

### Step 1 — Replace `generatePosition`

Update `DcbEventLogStorage_DynamoDb_Runtime.res:6-10`. Add `lastMs` and `counter` refs at module scope. New function as above.

### Step 2 — Verify `generatePositionForBatch`

Confirm batch positions still sort correctly under the new format. Test: 25 events generated in one batch, sort by position, assert order matches insertion order.

### Step 3 — Tests

In `tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res`:

- Two consecutive `generatePosition` calls within the same ms produce strictly increasing strings.
- `generatePosition` after a forward time tick resets the counter.
- `generatePositionForBatch` preserves order for same-base, different-idx.
- Old format positions sort sensibly relative to new format positions (seed a few in a list, sort, assert).

Mock `Date.make` via Jest's fake timers if needed.

### Step 4 — Compatibility check

Run all existing slice GWT tests (in-memory adapter — uses a different position generator, so unaffected) and `reventless-aws` tests. Run the AWS integration test (once it exists) on a fresh table — confirm new positions work with fence comparisons.

### Step 5 — Document

Update [`docs/analysis/dcb-dynamodb-consistency-check.md`](../../analysis/dcb-dynamodb-consistency-check.md) consistency issue #5 to mark resolved. Move plan to `done/`.

## Open questions

- Should `lastMs`/`counter` survive across Lambda invocations? They're module-level refs in ReScript → preserved while the Lambda container is warm, reset on cold start. That matches the desired semantics: monotonic within a container, no cross-container coordination needed. Confirm during Step 1.
- 6-digit counter caps at 999999 same-ms calls per instance. At even 100k req/s that's 100 calls per ms — well below the cap. Unless a future workload sustains millions of calls per ms per instance, 6 digits is sufficient.

## Status

Not started.

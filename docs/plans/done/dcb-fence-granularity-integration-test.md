# Backlog: Live DynamoDB integration test for per-type DCB fences — **DONE (2026-07-08)**

**Carved from**: [done/dcb-fence-event-type-granularity.md](../done/dcb-fence-event-type-granularity.md)
(the per-type fence fix shipped 2026-06-23, commit `a20646f31`; this is its remaining test work).
**Needs**: DynamoDB Local (Docker) — cannot run on the in-memory/SQLite backends, which don't use
fences. Run via `jest.integration.config.js` + `scripts/run-integration-tests.sh`.

## Status — DONE (2026-07-08)

The DCB DynamoDB integration suite (`DcbEventLogStorage_DynamoDb_IntegrationTest.res`) already
encodes the per-type `pos#<eventType>` fence model — **Tasks 1–3 and 5 shipped with the per-type
rewrite** (the `⚠️ PENDING REWRITE` header is long gone; `H.setFence` takes `~eventTypes`; queries
name their consumed types; the create-guard scenarios assert the folded guard). The one remaining
gap was **Task 4's live regression proof** — the same-partition/different-type "both Ok, never
wedges" case that the per-type fix actually addressed was only *shape*-tested in the unit suite.

Closed 2026-07-08 by adding the `per-type fence granularity` describe block (2 scenarios):
- **interleaved distinct-type changes on one product all succeed (never wedges)** — seed
  `ProductAdded`, then two rounds of `PriceChanged`/`NameChanged`/`DescriptionChanged`; all Ok.
  Pre-fix the first `PriceChanged` bumped the single partition fence, permanently conflicting the
  following `NameChanged` (the entity wedged after one edit).
- **two concurrent SAME-type changes still serialize (per-type OCC preserved)** — two concurrent
  `NameChanged` at the same `pos#NameChanged` head → at most one commits, every non-winner conflicts.

Task 4's remaining bullets are covered by pre-existing cases: two concurrent first-writers of the
same `(producedType, partition)` by the "exactly one creates it (Issue 2)" scenario. Suite green at
**14 tests** against DynamoDB Local (`bash reventless/reventless-aws/scripts/run-integration-tests.sh`).

The original task list below is retained for context.

## Why

The unit suite ([`DcbEventLogStorage_DynamoDb_RuntimeTest.res`](../../../reventless/reventless-aws/tests/DcbEventLogStorage_DynamoDb_RuntimeTest.res),
45 green) asserts the *shape* of the built `TransactWriteItems`. Only a live DynamoDB run proves
the `ConditionExpression`s actually interpret as intended — the OCC behaviour end-to-end.

The existing suite
([`DcbEventLogStorage_DynamoDb_IntegrationTest.res`](../../../reventless/reventless-aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res))
still encodes the OLD scalar-`lastPosition` model and is marked `⚠️ PENDING REWRITE` at its header.

## Tasks

1. Replace `H.setFence(~lastPosition=…)` seeding with per-type `pos#<eventType>` seeding (extend
   `DcbIntegrationHarness`).
2. Add `eventTypes` to the queries (the per-type path treats a tag-only clause as vacuous).
3. Rewrite the create-guard scenarios to the **folded** guard: assert no `create#…` row; a
   first-write conflict comes from `attribute_not_exists(pos#<producedType>)` on the partition
   fence; a subset-type first-write on a partition that already has another type is NOT conflicted.
4. New regression scenarios (the live proof of the fix):
   - Create product `P`; change **price**, then change **name** → both **Ok** (the bug was a
     permanent `Conflict` here).
   - Interleave name/description/price changes in any order → all Ok; the entity never wedges.
   - Two concurrent `ChangeProductName` for `P` → exactly one Ok, one conflicts (same-type OCC
     preserved).
   - Two concurrent first-writers of the same `(producedType, partition)` → one Ok, one conflicts
     (folded create race).
5. Green run against DynamoDB Local; drop the `PENDING REWRITE` header.

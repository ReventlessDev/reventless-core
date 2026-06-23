# Backlog: Live DynamoDB integration test for per-type DCB fences

**Carved from**: [done/dcb-fence-event-type-granularity.md](../done/dcb-fence-event-type-granularity.md)
(the per-type fence fix shipped 2026-06-23, commit `a20646f31`; this is its remaining test work).
**Needs**: DynamoDB Local (Docker) — cannot run on the in-memory/SQLite backends, which don't use
fences. Run via `jest.integration.config.js` + `scripts/run-integration-tests.sh`.

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

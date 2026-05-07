# Plan: AWS Integration Test for DCB Atomic Append

**Parent plan**: [dcb-dynamodb-atomic-append.md](../done/dcb-dynamodb-atomic-append.md)
**Analysis**: [dcb-dynamodb-consistency-check.md](../../analysis/dcb-dynamodb-consistency-check.md)

## Problem

The atomic-append fix (parent plan) is verified by 18 unit tests covering helper shape and validation gates, plus existing slice GWT tests against the in-memory adapter. None of those run against a real DynamoDB engine. We claim atomicity under concurrent writers but have no test that proves it on the actual storage primitive.

The risk is narrow: the unit tests confirm we *send* the right `TransactWriteItems` payload, but not that DynamoDB *interprets* the `ConditionExpression`s the way we expect — particularly for the `attribute_not_exists(lastPosition) OR lastPosition <= :after` form, which is the safety-critical clause.

## Goals

- One test demonstrating two parallel `appendConditional` calls with overlapping query tags result in exactly one `Ok(_)` and one `Error("Conflict: …")`.
- One test demonstrating `attribute_not_exists(lastPosition)` correctly seeds a fresh fence on first write.
- One test demonstrating `lastPosition <= :after` correctly accepts a chain of compatible commits.
- One test demonstrating cross-partition transaction semantics: a transaction with multiple fence updates aborts entirely if any single fence condition fails.
- All tests run in CI without a live AWS account.

## Approach

Use [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html) running as a sidecar in CI. Two viable hosting options:

1. **dynamodb-local in Docker** via `testcontainers` (Node has `@testcontainers/localstack` and a generic image runner). CI must have Docker; macOS dev machines do too.
2. **dynamodb-local as a downloadable JAR** run via `java -jar`. Lighter than Docker but adds a JVM dependency.

Option 1 is the standard. Option 2 is the fallback if the workspace already runs without Docker for other reasons.

### Test harness

- New file: `reventless/reventless-aws/tests/integration/DcbEventLogStorage_DynamoDb_IntegrationTest.res`
- Use a separate `jest` config (or a `// @jest-environment` directive) so unit tests stay fast and integration tests can be skipped via env var (`SKIP_INTEGRATION=1`).
- Configure `DynamoDBClient` to point at `http://localhost:8000` (DynamoDB Local default).
- Per-test setup: create a fresh table with the schema the production adapter expects (id PK, position SK, GSIs on tag attributes, `tag_composite` GSI). Tear down after.

### Tests to write

1. **Two concurrent conditional appends, same tag** — fire two `appendConditional` calls in parallel via `Promise.all`. Assert: one returns `Ok(_)`, the other returns `Error("Conflict: …")`. Read back; only the winner's events are persisted.
2. **Fresh fence seeding** — first conditional append on a never-seen tag value succeeds via `attribute_not_exists(lastPosition)` branch. Read back the fence; assert `lastPosition` matches the returned position.
3. **Sequential compatible commits** — three appends in series, each passing `cond.after = previousResult`. All succeed. Fence ends at the last position.
4. **Multi-tag fence atomicity** — append with two query tags (T1, T2). Pre-bump T1's fence externally to break the condition. The transaction must abort *entirely* (T2's fence must NOT have been updated).
5. **Tagless rejection round-trip** — passing a tagless condition returns `Error` *without* having created any items in the table.
6. **Limit error round-trip** — same as (5) but for the >100-items case.

## Steps

### Step 1 — Decide harness (Docker vs JAR)

Look at whether the project already uses any container-based testing in CI. If yes, follow that pattern. Otherwise default to dynamodb-local JAR.

### Step 2 — Add scaffolding

- Add `dynamodb-local` runner script to `reventless/reventless-aws/scripts/`.
- Add `pretest:integration` / `posttest:integration` package.json scripts.
- Add a thin `Util_DynamoDbLocal_Runtime.res` helper (or extend `Util_DynamoDb_Runtime.res`) that returns a client pointed at the local endpoint when `DDB_ENDPOINT` env var is set.

### Step 3 — Write tests (1)–(6)

### Step 4 — CI wiring

- New CI job: `aws-integration` — boots DynamoDB Local, runs `pnpm --filter ./reventless/reventless-aws run test:integration`.
- Default `pnpm test` continues to skip integration tests; only the new job exercises them.

### Step 5 — Document

Update [parent plan's "Tests run" section](../done/dcb-dynamodb-atomic-append.md) once integration tests pass.

## Non-goals

- Live AWS testing. Production confidence comes from staging deploys, not from CI tests against real DynamoDB.
- Integration tests for `read` / `readStream` — separate concerns; this plan is scoped to `append` correctness.

## Open questions

- DynamoDB Local has a known divergence from production around GSI propagation — but our atomicity guarantees come from base-table conditional writes, not GSI behaviour. Should be safe.
- Whether to gate on Docker availability or pin a specific dynamodb-local JAR version. Decide during Step 1.

## Status

Not started.

# Plan: Real Sequence Numbers with Optimistic Locking for Aggregate EventLog

**Analysis**: [docs/analysis/done/aggregate-eventlog-sequence-handling.md](../../analysis/done/aggregate-eventlog-sequence-handling.md)

## Overview

Replace timestamp-based sequenceNr with integer sequence numbers and enforce optimistic locking via DynamoDB conditional writes. Use an adaptive write strategy that selects PutItem, sequential PutItems, or TransactWriteItems based on batch size. Data migration is out of scope — new tables will use integer sequence numbers; existing tables are unaffected.

---

## Step 1: In-Memory Adapter — Optimistic Locking

Add conflict detection to the in-memory EventLog adapter for behavioral parity with the AWS adapter.

- [x] Update `EventLogStorage_InMemory.res`: check that `sequenceNr` matches the current event count for the aggregate before appending
- [x] Return `Error("conflict")` when the expected sequence number doesn't match
- [x] Update existing in-memory adapter tests to verify conflict detection
- [x] Add test: concurrent append with stale sequenceNr returns conflict error

## Step 2: Core Encoding — Integer Sequence Numbers

Change event encoding to use caller-provided integer sequence numbers instead of generating timestamps.

- [x] Update `EventLog_Operations.res` (`encodeEvent'`): accept sequenceNr as parameter, format as zero-padded integer string (`String.padStart(9, "0")`)
- [x] Update `EventLog_Operations.res` (`encodeEvent'` callers): thread the sequenceNr through, incrementing per event in a batch
- [x] Remove or deprecate `Message.hrtime` and `Message.hrtimeToString` (check for other usages first)
- [x] Verify in-memory E2E tests still pass with integer sequenceNr format

## Step 3: AWS SDK Bindings

Add ReScript bindings for DynamoDB conditional PutItem and TransactWriteItems.

- [x] Add `ConditionExpression` support to PutItem in `rescript-aws-sdk` DynamoDB bindings (if not already present) — already present
- [x] Add `TransactWriteItems` binding to `rescript-aws-sdk` DynamoDB bindings (if not already present) — already present
- [x] Add `ConditionalCheckFailedException` error detection helper — already present in `DynamoDb_Error.classify` → `StaleState`
- [x] Verify bindings compile and match AWS SDK types

## Step 4: AWS Adapter — Adaptive Conditional Append

Replace unconditional `batchWriteWithRetries` with an adaptive strategy based on batch size.

- [x] Implement `putItemConditional`: single PutItem with `conditionExpression: "attribute_not_exists(sequenceNr)"` — used for 1 event
- [x] Implement `putItemsSequentialConditional`: sequential PutItem calls each with condition — used for 2-5 events
- [x] Implement `transactWriteConditional`: TransactWriteItems with conditions on all items — used for 6+ events
- [x] Implement `appendWithCondition` that selects the strategy based on `events->Array.length`
- [x] Update `EventLogStorage_DynamoDb_Runtime.res` `append`: use `appendWithCondition` instead of `batchWriteWithRetries`
- [x] Map `ConditionalCheckFailedException` to `Error("conflict")` return value
- [x] Update `appendStream`: use `putItemConditional` per item (events arrive one at a time)

## Step 5: Aggregate Callback — Retry on Conflict

Add retry logic to the aggregate command handler for conflict detection and recovery.

- [x] Update `Aggregate_Callback.res` `handleCommands`: wrap the replay+process+append sequence in a retry loop
- [x] On `Error("conflict")` from append: re-replay event log, re-process commands, retry append
- [x] Set maximum retries to 3 (configurable via adapter or constant)
- [x] Log each retry attempt with aggregate ID and attempt number
- [x] After max retries exhausted: return `Error(reference)` for all commands in the batch (SQS will re-deliver)

## Step 6: Testing

Verify the full pipeline end-to-end.

- [x] In-memory unit tests: conflict detection, retry behavior, successful append after conflict
- [x] Aggregate callback test: verify retry loop re-replays and re-processes on conflict
- [x] Aggregate callback test: verify max retries exhausted returns error

Remaining test items moved to a follow-up plan: [aggregate-eventlog-sequence-numbers-missing-tests-plan.md](../aggregate-eventlog-sequence-numbers-missing-tests-plan.md)

---

## Out of Scope

- **Data migration**: Existing DynamoDB tables with timestamp-based sequenceNr are not migrated. New deployments use integer sequence numbers. Migration will be planned separately if needed.
- **DCB EventLog**: Uses a separate position system — unaffected by this change.
- **Snapshot/partial replay optimization**: Integer sequence numbers enable this but it's a separate feature.

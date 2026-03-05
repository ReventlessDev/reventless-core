# Plan: Harmonize Error Handling & Retry with Effect

**Status:** DONE (remaining items moved to `Backlog/effect-runtime-dispatch.md`)
**Created:** 2026-03-05
**Based on:** `docs/analysis/effect-retry-error-handling-migration.md`

---

## Goal

Replace all manual retry loops, raw try/catch, and `Promise.allSettled` patterns with Effect
library equivalents. The framework already uses Effect-based retry in `EventLog_Operations.res` —
that pattern becomes the standard everywhere.

---

## Phase 1: Typed Error Variants — DONE

### Step 1.1 — DynamoDB error types — DONE

- [x] Created `DynamoDb_Error.res` with `Transient(string) | StaleState(string) | Permanent(string)`
- [x] `classify: unknown => t` uses `PutError.classify` for `ConditionCheckFailedException` detection
  and string-matching for transient AWS errors
- [x] `isTransient`, `message` helpers
- [x] `retrySchedule`: exponential 500ms, jittered, 5 retries, whileInput(isTransient)

### Step 1.2 — SQS error types — DONE

- [x] Created `SQS_Error.res` with `Transient(string) | Permanent(string)`
- [x] `classify`, `isTransient`, `message` helpers
- [x] `retrySchedule` (1s base, 5 retries) and `sendRetrySchedule` (3s base, 10 retries)

### Step 1.3 — SNS error types — DONE

- [x] Created `SNS_Error.res` with `Transient(string) | Permanent(string)`
- [x] `classify`, `isTransient`, `message` helpers
- [x] `retrySchedule` (1s base, 5 retries)

### Step 1.4 — Cognito error types — DONE

- [x] Created `Cognito_Error.res` with `Transient(string) | Permanent(string)`
- [x] `classify` includes `TooManyRequestsException` and `InternalErrorException` (Cognito-specific)
- [x] `retrySchedule` (1s base, 5 retries)

### Step 1.5 — Kinesis error types — DONE

- [x] Created `Kinesis_Error.res` with `Transient(string) | Permanent(string)`
- [x] `classify` includes `ProvisionedThroughputExceededException` and `InternalFailureException` (Kinesis-specific)
- [x] `retrySchedule` (1s base, 5 retries)

### Step 1.6 — EventLog_Operations.res kept its own isTransient

- [x] `isTransient` and `storageRetrySchedule` kept in EventLog_Operations since they operate on
  plain `string` error messages (from storage adapter interface), not `DynamoDb_Error.t`

---

## Phase 2: Convert Manual Retry Functions — DONE

### Step 2.1 — Retry schedules co-located with error types

- [x] DynamoDB schedule in `DynamoDb_Error.retrySchedule`
- [x] SQS schedules in `SQS_Error.retrySchedule` / `sendRetrySchedule`
- [x] SNS schedule in `SNS_Error.retrySchedule`
- [x] No separate `Util_RetrySchedule.res` needed — schedules live with their error types

### Step 2.2 — `Util_DynamoDb_Runtime.res` — DONE

- [x] `putWithRetries` — `Effect.tryPromise(~catch=classify)->Effect.retry(schedule)`
- [x] `putIfNotExistsWithRetries` — StaleState not retried via `whileInput(isTransient)`
- [x] `deleteWithRetries` — same pattern
- [x] `batchWriteWithRetries` — `Effect.retry(DynamoDb_Error.retrySchedule)` for transient failures,
  recursive only for unprocessed-items subset retry
- [x] `queryStream` — error type changed from `string` to `DynamoDb_Error.t` with `~catch=DynamoDb_Error.classify`
- [x] `scanStream` — same change as `queryStream`
- [x] All callers updated (QueryDbStorage, EventLogStorage, DcbEventLogStorage, QueryEngine)

### Step 2.3 — `Util_SQS_Runtime.res` — DONE

- [x] `send` — `Effect.retry(sendRetrySchedule)` replaces infinite manual recursion (now capped at 10)
- [x] `sendMessages` — `Effect.retry(SQS_Error.retrySchedule)` for transient failures,
  recursive only for failed-ids subset retry (5 subset retries max)
- [x] `deleteMessages` — `Effect.retry(SQS_Error.retrySchedule)` for transient failures,
  recursive only for failed-ids subset retry (5 subset retries max), replaces infinite retry

### Step 2.4 — `EventLogStorage_DynamoDb_Runtime.res` — DONE

- [x] Merged `tryReplay` into `replay` — removed redundant `async id => await tryReplay(table, id)` wrapper
- [x] Uses `DynamoDb_Error.retrySchedule` (centralized) instead of local `replayRetrySchedule`
- [x] `replayStream` converts `DynamoDb_Error.t` back to `string` at adapter boundary via `Stream.catchAll`

### Step 2.5 — `Util_SNS_Runtime.res` — DONE

- [x] `publish` — `Effect.tryPromise(~catch=SNS_Error.classify)->Effect.retry(SNS_Error.retrySchedule)`
- [x] `publishFifo` — same pattern
- [x] `EventTopicPublisher_SNS_Runtime.res` — removed redundant `->Util.Promise.toUnit` calls

### Step 2.6 — `Util_CognitoGroupUser_Runtime.res` — DONE

- [x] `addUserToGroup` — `Effect.tryPromise(~catch=Cognito_Error.classify)->Effect.retry(Cognito_Error.retrySchedule)`
- [x] `removeUserFromGroup` — same pattern
- [x] `Util_Cognito_Runtime.signUpIfMissing` — updated to use `Cognito_Error.classify` (no retry, intentionally silent)

### Step 2.7 — `Util_Kinesis_Runtime.res` — DONE

- [x] `putRecord` — `Effect.tryPromise(~catch=Kinesis_Error.classify)->Effect.retry(Kinesis_Error.retrySchedule)`

### Step 2.8 — `CommandPublisher.res` — DONE

- [x] Replaced `Util.Promise.finishTimeout` with `Effect.sleep(Duration.millis(timeout))->Effect.runPromise`
- [x] Removed infinite retry loop in `SendChunks` — underlying SQS already retries transient failures
- [x] Both `SendChunks` and `SendAllInOneChunk` now log errors consistently without re-enqueuing

### Step 2.9 — `QueryDbStorage_DynamoDb_Runtime.res` `load` — DONE

- [x] Added `Effect.retry(DynamoDb_Error.retrySchedule)` — previously had no retry on query failures

### Step 2.10 — `QueryEngine_DynamoDb.res` — DONE

- [x] `queryByTableName` — added `Effect.retry(DynamoDb_Error.retrySchedule)`
- [x] `scanByTableName` — added `Effect.retry(DynamoDb_Error.retrySchedule)`
- [x] Both previously had no retry on query failures

---

## Phase 3: Convert try/catch + rethrow to Effect.tryPromise — DONE

### Step 3.1 — `Util_TopicSubscription_Runtime.res` — DONE

- [x] `subscribe` / `unsubscribe` — `Effect.tryPromise(~catch=SQS_Error.classify)` with retry

### Step 3.2 — `Util_PluginMessage_Runtime.res` — DONE

- [x] `sendMessage` — `Effect.tryPromise(~catch=SQS_Error.classify)` with retry

### Step 3.3 — `ScheduleOps.res` — DONE

- [x] `create` / `delete` — wrapped in `Effect.tryPromise->Effect.runPromiseExit`
- [x] Kept `ScheduleNotCreated` / `ScheduleNotDeleted` exceptions for API compatibility

### Step 3.4 — `Util_Cognito_Runtime.res` — DONE

- [x] Added explicit `// Intentionally silent on failure` comment
- [x] Replaced `~catch=_err =>` with `~catch=Error.messageFromUnknown` for better error messages

---

## Phase 4: Convert Promise fan-outs to Effect.all — DONE (scope-limited)

### Step 4.1 — `QueryDbStorage_DynamoDb_Runtime.res` writeMultiple — DONE

- [x] Replaced `Promise.allSettled` + manual rejection filtering with `Effect.all(batchEffects, {"concurrency": "unbounded"})`

### Step 4.2 — `EventMapper_Callback.res` doCount retry — DONE

- [x] Replaced `Effect.promise(() => Util.Promise.finishTimeout(timeout))` with `Effect.sleep`
- [x] Replaced infinite `let rec doCount` with `Effect.retry(countRetrySchedule)` — exponential 1s, jittered, 10 retries

### Remaining — deferred to `Backlog/effect-runtime-dispatch.md`

Runtime handler fan-outs and Promise-based dispatch patterns require broader architectural changes.

---

## Phase 5: S3 Pagination & Cleanup — deferred to `Backlog/effect-runtime-dispatch.md`

---

## Phase 6: Error Module Organization — DONE

### Step 6.1 — Dropped `Util_` prefix from error modules — DONE

- [x] `Util_DynamoDb_Error` → `DynamoDb_Error`
- [x] `Util_SQS_Error` → `SQS_Error`
- [x] Updated all 7 consumer files

### Step 6.2 — Moved error modules to `src/errors/` — DONE

- [x] `src/util/DynamoDb_Error.res` → `src/errors/DynamoDb_Error.res`
- [x] `src/util/SQS_Error.res` → `src/errors/SQS_Error.res`
- [x] `src/errors/SNS_Error.res` — new module

### Step 6.3 — Added missing Util module aliases — DONE

- [x] Added `Cloudwatch`, `Env`, `PluginMessage_Runtime`, `ResourceNaming`, `TopicSubscription_Runtime`, `Vpc`
- [x] Sorted all aliases alphabetically

---

## Files Changed

| File | Phase | Change |
|---|---|---|
| `reventless-aws/src/errors/DynamoDb_Error.res` | 1.1, 6 | **New** — typed DynamoDB errors + retry schedule (moved from util) |
| `reventless-aws/src/errors/SQS_Error.res` | 1.2, 6 | **New** — typed SQS errors + retry schedules (moved from util) |
| `reventless-aws/src/errors/SNS_Error.res` | 1.3, 6 | **New** — typed SNS errors + retry schedule |
| `reventless-aws/src/errors/Cognito_Error.res` | 1.4 | **New** — typed Cognito errors + retry schedule |
| `reventless-aws/src/errors/Kinesis_Error.res` | 1.5 | **New** — typed Kinesis errors + retry schedule |
| `reventless-aws/src/util/Util_DynamoDb_Runtime.res` | 2.2 | queryStream/scanStream use DynamoDb_Error.t; replaced 3 manual retry functions with Effect.retry |
| `reventless-aws/src/util/Util_SQS_Runtime.res` | 2.3 | `send` uses Effect.retry with schedule |
| `reventless-aws/src/util/Util_SNS_Runtime.res` | 2.5 | publish/publishFifo use Effect.tryPromise + SNS_Error.retrySchedule |
| `reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` | 2.4 | Merged tryReplay into replay; uses centralized DynamoDb_Error.retrySchedule |
| `reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res` | 2.5 | Removed redundant Promise.toUnit |
| `reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` | 2.2, 2.7, 4.1 | Added retry to load; Promise.allSettled -> Effect.all |
| `reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res` | 2.8 | Added retry to queryByTableName/scanByTableName |
| `reventless-aws/src/util/Util.res` | 6.3 | Added 6 missing module aliases |
| `reventless-core/src/util/CommandPublisher.res` | 2.6 | Effect.sleep replaces Util.Promise.finishTimeout |
| `reventless-core/src/components/EventLog/EventLog_Operations.res` | 1.4 | Removed explicit type annotation on schedule |
| `reventless-aws/src/util/Util_TopicSubscription_Runtime.res` | 3.1 | Effect.tryPromise + retry |
| `reventless-aws/src/util/Util_PluginMessage_Runtime.res` | 3.2 | Effect.tryPromise + retry |
| `reventless-core/src/util/ScheduleOps.res` | 3.3 | Effect.tryPromise + runPromiseExit |
| `reventless-aws/src/util/Util_CognitoGroupUser_Runtime.res` | 2.6 | Effect.tryPromise + Cognito_Error retry |
| `reventless-aws/src/util/Util_Kinesis_Runtime.res` | 2.7 | Effect.tryPromise + Kinesis_Error retry |
| `reventless-aws/src/util/Util_Cognito_Runtime.res` | 2.6, 3.4 | Uses Cognito_Error.classify; intentionally no retry |
| `reventless-core/src/components/EventMapper/EventMapper_Callback.res` | 4.2 | Infinite recursive retry → Effect.retry with bounded schedule |

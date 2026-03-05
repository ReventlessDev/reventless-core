# Pure Effect AWS Runtime (Phase D)

**Status:** Done

**Created:** 2026-03-05

**Completed:** 2026-03-05

**Depends on:** `docs/plans/done/pure-effect-callbacks.md` (core callbacks complete)

**Summary:** Lifted AWS adapter runtime handlers into pure Effect pipelines and migrated
`Console.*` logging to `Effect.logInfo`/`Effect.logError`/`Effect.logWarning`.

---

## What was done

All 16 runtime files were migrated. Additionally, `DcbEventLogStorage_DynamoDb_Runtime.res`
was updated as a downstream caller of `batchWriteWithRetries`.

### Migration patterns applied

1. **Retry loops** → recursive `Effect.flatMap` chains with `Effect.sleep(Duration.millis(...))` for delays
2. **`try { await ... } catch { ... }`** → `Effect.tryPromise(~catch=..., ...)` with `Effect.catchAll`
3. **`Console.log/error/warn`** → `Effect.logInfo/logError/logWarning`
4. **`async/await` functions** → Effect pipelines with `Effect.runPromise` at framework boundaries
5. **Sync helpers with Console** → simplified (removed diagnostic-only logs) or moved logging to Effect caller

### Utility files (return `Effect.t` for composition within reventless-aws)

- [x] `util/Util_DynamoDb_Runtime.res` — 13 Console calls → Effect pipelines for putWithRetries, putIfNotExistsWithRetries, deleteWithRetries, batchWriteWithRetries; simplified insertTtl
- [x] `util/Util_SQS_Runtime.res` — 9 Console calls → Effect pipelines for send, sendMessages, deleteMessages; simplified parseSqsRecord
- [x] `util/Util_TopicSubscription_Runtime.res` — 2 Console calls → Effect pipeline with `runPromise`
- [x] `util/Util_PluginMessage_Runtime.res` — 1 Console call → Effect pipeline with `runPromise`
- [x] `util/Util_Cognito_Runtime.res` — 2 Console calls → Effect pipeline with `runPromise`
- [x] `util/Util_SNS_FIFO.res` — 1 Console call removed (sync throw, error in message)
- [x] `util/Util_DeadLetterQueue.res` — 1 Console call → `Effect.logError` in callback

### Adapter runtime files (chain Effect utils, `runPromise` at framework boundary)

- [x] `adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res` — 5 Console calls → Effect pipeline for handleQueueEvent, publishJsons uses Effect.runPromise
- [x] `adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res` — 6 Console calls → Effect pipeline, removed ignored-record logging from sync filterMap
- [x] `adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res` — 2 Console calls → removed (sync filterMap, no Effect benefit)
- [x] `adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` — 2 Console calls → Effect pipeline for append, tryReplay
- [x] `adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` — 14 Console calls → Effect pipelines for load, save, count, delete, writeMultiple
- [x] `adapter/QueryEngine/QueryEngine_DynamoDb.res` — 4 Console calls → Effect pipelines for queryByTableName, scanByTableName (query param logging → logDebug)
- [x] `adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res` — 7 Console calls → Effect pipeline for addToCounterTarget; sync filterMap logging uses runSync (pragmatic choice)
- [x] `adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res` — 2 Console calls → Effect pipelines with `runPromise`
- [x] `adapter/Cloner/ClonerRunner_Fargate_Runtime.res` — 1 Console call → Effect pipeline with `runPromise`

### Downstream fix

- [x] `adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res` — added `Effect.runPromise` for `batchWriteWithRetries` call

### Deploy-time files (kept as `Console.*` — no Effect pipeline)

- `util/Util_DynamoDb.res`, `util/Util_DynamoDbStream.res`, `util/Util_SNS.res`
- `adapter/EventCollector/EventCollectorChannel_Helpers.res`
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res`
- `components/DataCleaner.res`

---

## Build & Test Results

- Zero compiler warnings
- All 85 test suites pass (697 tests)

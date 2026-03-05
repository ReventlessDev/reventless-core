# Pure Effect AWS Runtime (Phase D)

**Status:** Backlog

**Created:** 2026-03-05

**Depends on:** `docs/plans/pure-effect-callbacks.md` (core callbacks complete)

**Summary:** Lift AWS adapter runtime handlers into pure Effect pipelines and migrate
`Console.*` logging to `Effect.logInfo`/`Effect.logError`. Using `Effect.logInfo->Effect.runSync`
in plain async functions provides no benefit over `Console.*`, so the runtime functions must
first be restructured into Effect pipelines before logging can be migrated.

---

## Goal

- Consistent logging across the entire stack (core + AWS adapters)
- Enable testability: silence logs with `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`
- Structured log output with fiber/timestamp context from Effect's built-in logger
- Align AWS runtime code with the Effect programming model

---

## Scope

### AWS runtime files to migrate (all in `reventless/reventless-aws/src/`)

Each file needs two changes: (1) lift async handlers into Effect pipelines, (2) replace `Console.*` with `Effect.logInfo`/`Effect.logError`.

- `adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res` -- SQS command handling + publishing
- `adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res` -- SQS/DynamoDB stream event handling
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res` -- DynamoDB stream events
- `adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res` -- event log storage errors/warnings
- `adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res` -- QueryDb CRUD with retry logging
- `adapter/QueryEngine/QueryEngine_DynamoDb.res` -- query/scan logging
- `adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res` -- counter stream handling
- `adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res` -- scheduled publish errors
- `adapter/Cloner/ClonerRunner_Fargate_Runtime.res` -- cloner diagnostics
- `util/Util_SQS_Runtime.res` -- SQS send/delete with retry logging
- `util/Util_DynamoDb_Runtime.res` -- DynamoDB put/delete with retry logging
- `util/Util_TopicSubscription_Runtime.res` -- SNS subscribe/unsubscribe errors
- `util/Util_PluginMessage_Runtime.res` -- plugin message errors
- `util/Util_Cognito_Runtime.res` -- Cognito user creation logging
- `util/Util_SNS_FIFO.res` -- SNS FIFO error logging
- `util/Util_DeadLetterQueue.res` -- dead letter logging

### AWS deploy-time files (keep as `Console.*` -- no Effect pipeline)

These run at deploy time (Pulumi) and have no Effect pipeline:

- `util/Util_DynamoDb.res`, `util/Util_DynamoDbStream.res`, `util/Util_SNS.res`
- `adapter/EventCollector/EventCollectorChannel_Helpers.res`
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res`
- `components/DataCleaner.res`

---

## Approach

This is a significant refactor -- each runtime file can be migrated independently.
Should be broken into per-file work items when work begins.

Patterns established in the core callback migration (Phase C) apply here:
- `Effect.promise(async () => { ... })` → `Effect.flatMap` chains with `Effect.promise(() => singleCall)`
- `Console.log(...)` → `Effect.logInfo(...)` (natural in pipeline, no `runSync`)
- `Console.error(...)` → `Effect.logError(...)`
- `try { await ... } catch { ... }` → `Effect.tryPromise(~catch=..., ...)`
- Retry loops → `Effect.retry` with `Schedule` or recursive `Effect.flatMap`

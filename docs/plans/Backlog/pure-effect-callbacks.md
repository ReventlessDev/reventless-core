# Pure Effect Callbacks (Phase C)

**Status:** Backlog

**Created:** 2026-03-05

**Depends on:** `docs/plans/done/effect-logger-and-request-context.md` (complete)

**Summary:** Restructure callbacks to stay entirely in the Effect pipeline, eliminating
`Effect.promise(async () => ...)` blocks in favor of Effect combinators. Also migrate AWS adapter
runtime files from `Console.*` to `Effect.logInfo`/`Effect.logError` once they are lifted into
pure Effect pipelines.

---

## Goal

After the logger migration (Phase A+B), logging inside async closures uses
`Effect.logInfo(...)->Effect.runSync` -- it works but is awkward. Pure Effect callbacks would:

- Make logging natural: `->Effect.tap(_ => Effect.logInfo("msg"))` with no `runSync`
- Enable testability: silence logs with `Effect.provide(Logger.minimumLogLevel(LogLevel.None))`
- Enable composability: callbacks become pure Effect values -- combinable, retriable, timeable
- Align with the Effect programming model

---

## Scope

### Core callbacks

Each needs restructuring:
- `Effect.promise(async () => { ... })` -> Effect combinators (`flatMap`, `tap`, `forEach`, `all`)
- `await somePromise` -> `Effect.tryPromise(() => somePromise)`
- `Array.map(async ...)` -> `Effect.forEach` or `Effect.all`
- Mutable accumulators -> `Effect.reduce` or `Ref`

### AWS adapter runtime files

Migrate `Console.*` to `Effect.logInfo`/`Effect.logError` once the functions they're called from
are lifted into pure Effect pipelines. Using `Effect.logInfo->Effect.runSync` in plain async
functions provides no benefit over `Console.*`.

AWS runtime files to migrate (all in `reventless/reventless-aws/src/`):

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

- `util/Util_DynamoDb.res`, `util/Util_DynamoDbStream.res`, `util/Util_SNS.res`
- `adapter/EventCollector/EventCollectorChannel_Helpers.res`
- `adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res`
- `components/DataCleaner.res`

---

## Approach

This is a significant refactor -- each callback can be migrated independently.
Should be broken into per-callback work items when work begins.

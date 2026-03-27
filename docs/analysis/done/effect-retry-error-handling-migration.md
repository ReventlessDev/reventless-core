# Effect Migration: Retry & Error Handling Analysis

**Status:** Analysis (no implementation planned)

**Created:** 2026-02-28

**Summary:** Where in the Reventless framework there are still manual retries or raw error
handling without Effect, and where adopting Effect would improve robustness and reduce code.

---

## 1. Retry Logic — Manual Recursion Everywhere

All retry logic is hand-rolled recursive async functions with hardcoded counters and random
backoff. No `Schedule`, no jitter strategy, no composability.

### `reventless-aws/src/util/Util_DynamoDb_Runtime.res` — 5 functions

- **`putWithRetries`**, **`putIfNotExistsWithRetries`**, **`deleteWithRetries`** — recursive with
  `~retry=0, ~maxRetries=5`, random 500–1500ms backoff via `Math.Int.random`.
- **`batchWriteWithRetries`**, **`retryBatchWriteIfNecessary`** — additionally filter unprocessed
  items and re-drive only the failed subset before recursing.
- `putIfNotExistsWithRetries` uses `PutError.classify` to separate
  `ConditionCheckFailedException` (→ `Error("Stale State")`) from transient errors (→ retry).

### `reventless-aws/src/util/Util_SQS_Runtime.res` — 3 functions

- **`send`**, **`sendMessages`**, **`deleteMessages`** — same recursion pattern, random
  3000–7000ms backoff. SQS batch versions filter `Result.Error(failedIds)` before retrying only
  the failed subset.

### `reventless-core/src/util/CommandPublisher.res`

- **`send`** — re-enqueues failed commands back into a mutable buffer before recursing.

Each of these 15–30-line functions could be replaced with a one-liner:

```rescript
Effect.tryPromise(~catch=classifyDdbError, () => client->DynamoDB.put(params))
->Effect.retry(
  Schedule.exponential(Duration.millis(500))
  ->Schedule.jittered
  ->Schedule.recurs(5)
)
```

---

## 2. Error Handling Without Effect

### `try/catch` + rethrow (log and re-propagate, no recovery)

| File | Function | Notes |
|---|---|---|
| `Util_PluginMessage_Runtime.res` | `sendMessage` | Catches `JsExn`, logs, rethrows |
| `Util_TopicSubscription_Runtime.res` | `subscribe`, `unsubscribe` | SNS operations; catches `JsExn`, rethrows |
| `ScheduleOps.res` | `createSchedule`, `deleteSchedule` | Throws custom `ScheduleNotCreated` exception on failure |

### Silent exception suppression

- **`Util_Cognito_Runtime.res` — `signUpIfMissing`**: catches all exceptions and continues
  without any error signal, making failures invisible to callers.

### `Promise.allSettled` + manual rejection filtering

- **`QueryDbStorage_DynamoDb_Runtime.res`** — batch query operations use `Promise.allSettled`
  with hand-rolled `filterRejected` to extract failures.
- **`AggregateRuntime_Builder_Common.res`** and **`CommandTopicChannel_InMemory.res`** — fan-out
  to multiple handlers via `->Array.map(handler => handler(...))->Promise.all`. No concurrency
  limit, no timeout, no cancellation on first failure.

### `Result` as a poor-man's error channel

- `Util_DynamoDb_Runtime.res` returns `result<unit, string>` — plain strings lose type
  information across call boundaries.
- SQS batch operations use `Error(failedIds)` to drive retry selection, mixing error signalling
  with data.

### Hand-rolled Promise utilities (`Util_Promise.res`)

`allSettled`, `filterRejected`, `mapOk`, `mapExn` are workarounds for what Effect's error channel
and `Effect.all` provide natively. Once usages are migrated this module becomes dead code.

---

## 3. Current Effect Usage

Effect is already in use, but only at the streaming layer:

| File | Pattern |
|---|---|
| `CsvStream.res` | Wraps FastCSV callback API in `Effect.promise`, maps error to channel, emits `Stream.fromIterable` |
| `CommandTopicChannel_InMemory.res` | `publishJsonsStream` collects stream → `Effect.promise(publishJsons)` |
| `MockEventLogStorage.res` | `replayStream` via `Stream.fromIterable`; `appendStream` via `Stream.runForEach` + `Effect.sync` |
| `QueryEngine_InMemory.res` | `Stream.take(limit)->Stream.runCollect->Effect.runPromise` for pagination |
| `CommandTopicChannel_InMemory.res` | `Deferred.await_->Effect.runPromise` for handler registration |

The pattern is proven and consistent. It just hasn't been applied to the error/retry layer yet.

---

## 4. Improvement Opportunities

### Priority 1 — Retry functions (highest value, self-contained)

The 8+ retry functions in `Util_DynamoDb_Runtime` and `Util_SQS_Runtime` are the clearest win.
They are self-contained, well-tested, and the conversion is mechanical.

The DynamoDB `ConditionCheckFailedException` case (currently caught as an exception and mapped to
`Error("Stale State: ...")`) maps cleanly to a typed error variant with `Effect.catchTag` —
eliminating string-typed errors and enabling callers to pattern-match on specific failure modes.

**Requires first:** Defining typed error variants for DynamoDB and SQS operations. Example:

```rescript
type ddbError =
  | TransientError(string)
  | StaleState(string)
  | RetryLimitExceeded

// putIfNotExistsWithRetries becomes:
Effect.tryPromise(~catch=classifyDdbError, () => client->DynamoDB.put(params))
->Effect.retry(
  Schedule.exponential(Duration.millis(500))
  ->Schedule.jittered
  ->Schedule.whileInput(err => err != StaleState(_))  // don't retry stale state
  ->Schedule.recurs(5)
)
->Effect.catchTag("StaleState", ({id}) => Effect.fail(StaleState(id)))
```

### Priority 2 — `Promise.all` fan-outs → `Effect.all` with concurrency control

`AggregateRuntime_Builder_Common.res` and the in-memory command channel both fan-out handler
calls with `->Array.map(handler => handler(...))->Promise.all`. These have no concurrency limit
and no timeout. Replacing with `Effect.all(effects, {concurrency: "unbounded"})` is a small
change but opens the door to adding `Effect.timeout` and structured resource cleanup.

### Priority 3 — `try/catch` + rethrow → `Effect.tryPromise`

The SNS/SQS operations that catch and re-throw are straightforward conversions. The benefit is
composability — once they return an `Effect`, callers can add `Effect.retry`, `Effect.catchTag`,
or `Effect.timeout` without touching the implementation.

### Priority 4 — S3 list pagination → `Stream.paginateEffect`

`TaskBucket_S3_Runtime.res` fetches all S3 keys eagerly. For large buckets this is unbounded
memory. `Stream.paginateEffect` with the S3 continuation token would make listing lazy and
interruptible, consistent with how DcbEventLog and EventLog already use streams.

### Priority 5 — `Util_Promise.res` deletion

Once `Promise.allSettled` / `filterRejected` / `mapOk` usages are replaced with Effect
equivalents, that whole utility module becomes dead code and can be removed.

---

## 5. Risk Assessment

| Conversion | Effort | Value | Notes |
|---|---|---|---|
| `Util_TopicSubscription_Runtime` (SNS) | Low | Medium | Simple try→Effect.tryPromise |
| `Util_PluginMessage_Runtime` (SQS send) | Low | Medium | Single operation |
| `Promise.all` fan-outs → `Effect.all` | Low | Medium | Enables timeout/concurrency later |
| `Util_DynamoDb_Runtime` retry functions | Medium | High | Requires typed error variants first |
| `Util_SQS_Runtime` retry functions | Medium | High | Same as DynamoDB |
| `CommandPublisher` retry | High | Medium | Mutable buffer needs redesign |
| S3 pagination → `Stream.paginateEffect` | Medium | Medium | Requires understanding S3 cursor API |
| FTP stream → `Stream.fromReadableStream` | High | Low | Rarely exercised path |

**Recommended entry point:** Define typed error variants for DynamoDB and SQS, then convert the
retry functions. This is the highest-value work and unlocks the rest of the error layer migration
naturally.

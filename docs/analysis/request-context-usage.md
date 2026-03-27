# RequestContext — Fields and Usage Analysis

> **Status: Partial.** `RequestContext.t` was implemented with `{ correlationId, identity, claims }`. The `causationId` and `retryCount` fields recommended by this analysis were not added. The shape diverged from the recommendation — `identity` and `claims` were added instead (not proposed here).

**Created:** 2026-03-05

**Related:** `docs/plans/effect-logger-and-request-context.md` (Work Item 2)

---

## Current State

`RequestContext.res` defines `type t = { correlationId: string }` with a service tag and a
`test()` constructor. This analysis explores what additional fields would be valuable to
provide at the dispatch point.

---

## Candidate Fields

### correlationId (already planned)

| | |
|---|---|
| **Type** | `string` |
| **Source** | `event.meta.correlationId` (SQS message body or in-memory event) |
| **Value** | Traces a user action across the full callback chain. See `correlation-id-usage.md`. |
| **Recommendation** | Include — primary motivation for RequestContext |

### causationId

| | |
|---|---|
| **Type** | `string` |
| **Source** | The ID of the specific event or command that triggered the current callback |
| **Value** | Enables proper event lineage graphs. While correlationId groups all effects of one user action, causationId records the direct parent, allowing reconstruction of the causal tree. Essential for debugging complex chains (command → events → generated commands → more events). |
| **Extraction** | Available from the same `meta` object as correlationId — commands carry `meta.commandId`, events carry `meta.eventId`. |
| **Recommendation** | Include — standard event sourcing practice, minimal extraction cost |

### sourceAggregate

| | |
|---|---|
| **Type** | `option<string>` |
| **Source** | The aggregate or component name that originated the current processing chain |
| **Value** | Useful in EventMapper and SideEffectHandler for routing decisions without parsing the event payload. Reduces coupling to event structure. |
| **Extraction** | Available from the SQS message attributes or the in-memory dispatch metadata. |
| **Recommendation** | Defer — callbacks already receive the event which carries source information. Adding this creates a second source of truth. |

### timestamp

| | |
|---|---|
| **Type** | `float` |
| **Source** | Request arrival time from SQS `SentTimestamp` attribute or in-memory dispatch time |
| **Value** | Callbacks can compute processing latency without calling `Date.now()`. More accurate for latency metrics since it captures when the message was sent, not when the callback started. |
| **Extraction** | SQS: `record.attributes.SentTimestamp`. In-memory: `Date.now()` at dispatch. |
| **Recommendation** | Defer — useful for observability but not needed until metrics are instrumented |

### retryCount

| | |
|---|---|
| **Type** | `int` |
| **Source** | SQS `ApproximateReceiveCount` attribute; in-memory: always 0 |
| **Value** | Enables smarter error handling: skip expensive operations on early retries, implement exponential backoff, log differently on final attempt before dead-letter queue, or fail fast when retries are exhausted. |
| **Extraction** | SQS: `record.attributes.ApproximateReceiveCount` (string, parse to int). In-memory: hardcode 0. |
| **Recommendation** | Include — high value for production resilience, trivial to extract |

### platform

| | |
|---|---|
| **Type** | `string` (e.g. `"lambda"`, `"in-memory"`) |
| **Source** | Known statically per RuntimeEnvironment module |
| **Value** | Lets callbacks adapt behavior: skip S3 uploads in tests, adjust timeouts for Lambda limits, use different external service endpoints. |
| **Extraction** | Static constant per platform — no parsing needed. |
| **Recommendation** | Avoid — callbacks should be platform-agnostic. Platform-specific behavior belongs in adapters, not callbacks. Providing this field encourages the wrong pattern. |

### deadlineMs

| | |
|---|---|
| **Type** | `option<float>` |
| **Source** | Lambda: `context.getRemainingTimeInMillis()`. In-memory: `None`. |
| **Value** | Long-running callbacks like SideEffectHandler could bail out gracefully before Lambda timeout, avoiding partial work and SQS redelivery of already-processed items. |
| **Extraction** | Lambda context is already available at the dispatch point. |
| **Recommendation** | Defer — valuable but only matters for callbacks approaching Lambda's 15-minute limit. Can be added later without breaking changes. |

---

## Recommended Initial Shape

```rescript
type t = {
  correlationId: string,
  causationId: string,
  retryCount: int,
}
```

### Rationale

- **correlationId** — primary use case, already planned
- **causationId** — standard event sourcing practice, near-zero cost to include alongside correlationId since it comes from the same `meta` object
- **retryCount** — high operational value, trivial extraction from SQS attributes

### Fields Explicitly Deferred

- **sourceAggregate** — redundant with event payload
- **timestamp** — useful but not needed until metrics work begins
- **platform** — anti-pattern for callback code
- **deadlineMs** — valuable but premature; add when timeout handling becomes a real concern

### Migration Path

Adding fields later is non-breaking: `RequestContext.test()` gets new optional parameters with
defaults, and the dispatch-point extraction is localized to two `runEffect` functions.

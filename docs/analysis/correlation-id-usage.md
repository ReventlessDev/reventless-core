# Correlation ID Usage in Callbacks

**Created:** 2026-03-05

**Related:** `docs/plans/effect-logger-and-request-context.md` (Work Item 2)

---

## What is the correlationId?

The correlationId is a string identifier that traces a single user action through the entire
processing chain. It originates from the command's `meta.correlationId` field and should propagate
unchanged through every callback that processes the resulting events.

---

## Usage Patterns in Callbacks

### 1. Structured Log Correlation

Every log line from a single request shares the same correlationId. This enables filtering in
log aggregation tools (e.g. CloudWatch Insights, Datadog) to reconstruct the full processing
path of one command across the entire chain:

```
Aggregate_Callback → EventMapper_Callback → ReadModel_Callback → SideEffectHandler_Callback
```

Without correlationId, log lines from concurrent requests interleave and are nearly impossible
to follow in production.

**Relevant callbacks:** All callbacks benefit from this.

### 2. Error Diagnostics

When `Aggregate_Callback` rejects a command or `SideEffectHandler_Callback` fails an external
call, the correlationId in the error log lets operators trace back to the originating command
and see what happened at each processing step.

**Relevant callbacks:** `Aggregate_Callback`, `SideEffectHandler_Callback`, `OutboundTranslationSlice_Callback`

### 3. Distributed Tracing Headers

`SideEffectHandler_Callback` makes external HTTP/API calls. Passing correlationId as an
`X-Correlation-Id` (or W3C `traceparent`) header lets downstream services participate in the
same trace, enabling cross-service observability.

**Relevant callbacks:** `SideEffectHandler_Callback`

### 4. Audit Trail Enrichment

EventMapper or ReadModel callbacks could stamp the correlationId onto outbound events or
projection updates, creating an end-to-end audit chain. This is valuable in regulated domains
where you need to prove which user action caused which state change.

**Relevant callbacks:** `EventMapper_Callback`, `ReadModel_Callback`

### 5. Idempotency Key Derivation

`CommandGenerator_Callback` generates new commands from events. Using
`correlationId + sourceEventId` as a deterministic idempotency key prevents duplicate command
generation on retries (e.g. SQS redelivery).

**Relevant callbacks:** `CommandGenerator_Callback`, `AutomationSlice_Callback`

---

## Priority

Patterns 1-2 (logging and error diagnostics) are the primary motivation and should be
implemented first. They require no changes to callback signatures or event schemas, only
access to RequestContext via the Effect service.

Patterns 3-5 are secondary and can be adopted per-callback as needed.

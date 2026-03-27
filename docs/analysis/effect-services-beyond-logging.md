# Effect Services Beyond Logging and RequestContext

> **Status: Not implemented.** The linked plan (`docs/plans/done/effect-logger-and-request-context.md`) implemented logging and RequestContext only. None of the proposed Effect services (Clock, Random/ID, Metrics, HTTP Client, Feature Flags, Event Publisher, Secret Store) have been created.

**Created:** 2026-03-05

**Related:** `docs/plans/effect-logger-and-request-context.md`, `docs/analysis/request-context-usage.md`

---

## Context

The Effect-based handler architecture (commit 7ab3b3e8) established a service injection point
at the dispatch boundary (`runEffect`). Currently only `EffectLogger` is provided there, with
`RequestContext` planned next. This analysis explores what other Effect services could be
valuable for the Reventless framework.

All callbacks already return `Effect.t` and are executed via `runEffect`, so adding new
services requires only: (1) defining the service tag/type, (2) providing at the dispatch point,
and (3) consuming via `Effect.serviceWith` in callbacks.

---

## Candidate Services

### 1. Metrics / Telemetry

| | |
|---|---|
| **Problem** | No structured metrics collection. Callbacks have no standard way to emit counters, histograms, or timing data. Observability is limited to log scraping. |
| **Service shape** | `{ increment: (string, ~tags: dict<string>=?) => Effect.t<unit>, timing: (string, float, ~tags: dict<string>=?) => Effect.t<unit>, gauge: (string, float, ~tags: dict<string>=?) => Effect.t<unit> }` |
| **Provider** | Lambda: CloudWatch EMF (Embedded Metric Format) or Datadog StatsD. In-memory: accumulator for test assertions or silent no-op. |
| **Use in callbacks** | `Aggregate_Callback`: count commands processed, measure replay duration. `SideEffectHandler_Callback`: count external API calls, measure latency. `ReadModel_Callback`: count projections applied. |
| **Value** | High — production observability is a persistent gap. Effect service injection means metrics can be silenced in tests and swapped between providers without touching callback code. |
| **Complexity** | Medium — needs provider implementations per platform. |
| **Recommendation** | Include in roadmap after Logger/RequestContext migration |

### 2. Clock / Time

| | |
|---|---|
| **Problem** | Callbacks call `Date.now()` directly, making time-dependent logic untestable. Any callback that computes deadlines, TTLs, or timestamps is implicitly coupled to wall-clock time. |
| **Service shape** | `{ now: unit => Effect.t<float>, nowDate: unit => Effect.t<Date.t> }` |
| **Provider** | Production: `Effect.sync(() => Date.now())`. Test: fixed or advancing clock for deterministic assertions. |
| **Use in callbacks** | `SideEffectHandler_Callback`: timeout calculations. `Aggregate_Callback`: timestamp on generated events. `Counter_Callback`: TTL-based expiry. Any future scheduling logic. |
| **Value** | Medium — improves testability significantly for time-dependent callbacks. Standard practice in Effect ecosystems. |
| **Complexity** | Low — trivial to implement. |
| **Recommendation** | Include — low cost, high testability benefit |

### 3. Random / ID Generation

| | |
|---|---|
| **Problem** | Callbacks generate UUIDs via direct `Uuid.v4()` calls. This makes output non-deterministic in tests — you can't assert on exact generated IDs. |
| **Service shape** | `{ uuid: unit => Effect.t<string>, randomInt: (int, int) => Effect.t<int> }` |
| **Provider** | Production: `Uuid.v4()`. Test: sequential or seeded generator (`"test-id-1"`, `"test-id-2"`, ...). |
| **Use in callbacks** | `CommandGenerator_Callback`: generates command IDs for new commands. `Aggregate_Callback`: event IDs for emitted events. Any callback producing new identifiers. |
| **Value** | Medium — enables snapshot testing and deterministic assertions on generated messages. |
| **Complexity** | Low — trivial to implement. |
| **Recommendation** | Include — pairs well with Clock for fully deterministic test pipelines |

### 4. HTTP Client

| | |
|---|---|
| **Problem** | `SideEffectHandler_Callback` makes external HTTP calls using direct `fetch` or SDK calls. These are hard to mock, hard to retry, and invisible to the Effect pipeline. |
| **Service shape** | `{ fetch: (string, ~method: string=?, ~headers: dict<string>=?, ~body: option<string>=?) => Effect.t<{ status: int, body: string }, httpError> }` |
| **Provider** | Production: native `fetch` wrapped in Effect. Test: recorded responses or assertion-based mock. |
| **Use in callbacks** | `SideEffectHandler_Callback`: all external API calls. Any future webhook or notification callback. |
| **Value** | High — side effects are the hardest part to test. An injectable HTTP client makes SideEffectHandler fully testable without network access. Also enables automatic retry policies at the service level. |
| **Complexity** | Medium — needs error type design and response parsing conventions. |
| **Recommendation** | Include in roadmap — critical for SideEffectHandler testability |

### 5. Feature Flags / Configuration

| | |
|---|---|
| **Problem** | No runtime configuration mechanism for callbacks. Feature toggles, percentage rollouts, or per-tenant configuration require code changes and redeployment. |
| **Service shape** | `{ flag: string => Effect.t<bool>, config: string => Effect.t<option<string>> }` |
| **Provider** | Production: environment variables, SSM Parameter Store, or LaunchDarkly. Test: static map. |
| **Use in callbacks** | Any callback that needs conditional behavior: migration toggles, gradual rollouts, per-tenant feature gates. |
| **Value** | Low-medium — useful at scale but premature for most deployments. Adds indirection that complicates reasoning about callback behavior. |
| **Complexity** | Medium — needs caching strategy (don't call SSM on every invocation). |
| **Recommendation** | Defer — only valuable when the framework has users needing runtime toggles |

### 6. Event Publisher

| | |
|---|---|
| **Problem** | Callbacks that need to publish events or commands do so through operations passed as module parameters (e.g., `Ops.publishJsons`). This parameter threading is verbose and makes the dependency implicit in the module signature rather than the Effect type. |
| **Service shape** | `{ publishEvents: array<JSON.t> => Effect.t<unit, publishError>, publishCommands: (string, array<JSON.t>) => Effect.t<unit, publishError> }` |
| **Provider** | Production: SQS/SNS publish. In-memory: bus dispatch. Test: captured array for assertions. |
| **Use in callbacks** | `EventMapper_Callback`: publishes mapped commands. `CommandGenerator_Callback`: publishes generated commands. `AutomationSlice_Callback`: publishes automation commands. |
| **Value** | Medium — reduces parameter threading and makes publish operations visible in the Effect requirements type. However, the current module-parameter approach works and is well-established. |
| **Complexity** | High — would require reworking how operations are wired through builders. |
| **Recommendation** | Defer — the current pattern works. Migration cost exceeds benefit unless the builder architecture is being reworked for other reasons. |

### 7. Secret Store

| | |
|---|---|
| **Problem** | `SideEffectHandler_Callback` needs API keys, tokens, and credentials for external calls. Currently these come from environment variables or hardcoded config, with no standard access pattern. |
| **Service shape** | `{ getSecret: string => Effect.t<string, secretError> }` |
| **Provider** | Production: AWS Secrets Manager or SSM SecureString with caching. Test: static map. |
| **Use in callbacks** | `SideEffectHandler_Callback`: API keys for external services. Any future OAuth/webhook signing. |
| **Value** | Medium — centralizes secret access, enables rotation without redeployment, and prevents secrets from appearing in logs. |
| **Complexity** | Medium — needs caching (Secrets Manager calls are slow and metered). |
| **Recommendation** | Defer until SideEffectHandler patterns mature — environment variables suffice for now |

---

## Priority Ranking

| Priority | Service | Rationale |
|----------|---------|-----------|
| **1** | Clock | Trivial to implement, immediate testability gain |
| **2** | Random/ID Generation | Trivial to implement, enables deterministic tests |
| **3** | Metrics | High production value, moderate implementation effort |
| **4** | HTTP Client | Critical for SideEffectHandler testability |
| **5** | Secret Store | Useful but environment variables suffice initially |
| **6** | Feature Flags | Premature without scale |
| **7** | Event Publisher | Current pattern works; high migration cost |

---

## Implementation Strategy

### Phase 1 — Foundation (with Logger + RequestContext)

Add **Clock** and **Random** alongside the Logger/RequestContext migration. These are trivial
services (2-3 lines each) that immediately improve test determinism:

```rescript
// Clock.res
type t = { now: unit => Effect.t<float, unit, unit> }
let tag = Context.genericTag("reventless/Clock")
let real = { now: () => Effect.sync(() => Date.now()) }
let fixed = (time) => { now: () => Effect.sync(() => time) }

// Random.res
type t = { uuid: unit => Effect.t<string, unit, unit> }
let tag = Context.genericTag("reventless/Random")
let real = { uuid: () => Effect.sync(() => Uuid.v4()) }
let sequential = () => {
  let counter = ref(0)
  { uuid: () => Effect.sync(() => { counter := counter.contents + 1; "test-id-" ++ Int.toString(counter.contents) }) }
}
```

Both get provided in `runEffect` alongside Logger and RequestContext.

### Phase 2 — Observability

Add **Metrics** service once Logger migration is complete and the pattern is proven. Design
the provider interface to support CloudWatch EMF (zero-dependency structured metrics for Lambda).

### Phase 3 — External Integration

Add **HTTP Client** when SideEffectHandler testing becomes a priority. Consider whether this
should be a thin wrapper or include retry/circuit-breaker policies at the service level.

### Non-Goals

**Event Publisher** and **Feature Flags** should not become Effect services in the near term.
The current module-parameter pattern for publishing is well-established and works. Feature flags
add complexity without clear demand.

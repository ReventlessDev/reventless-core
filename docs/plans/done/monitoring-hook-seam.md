# Plan: deploy-time Monitoring hook seam

**Status**: Done (2026-07-11) — core registry, AWS Lambda + DLQ sites,
`Cloudwatch_MetricAlarm` binding, conformance obligation, and registry unit test
landed. K8s site and behavioral example-deploy test remain future work (see
Acceptance / §2).
**Nature**: small additive adapter seam. No resources, no alarm logic, no
notification vocabulary in the framework — a no-op-by-default hook through
which every runtime backend announces the **execution units** it provisions,
so an extension can attach provider-native monitoring to each. Zero behavioral
change unless an extension registers a backend.

## Motivation

A deployed platform's command handler crashed on 100% of its messages for three
weeks with no operator-visible signal (see
`platform-infrastructure-in-plugin-list.md`, field-additions-brick section).
Monitoring/alerting itself is deliberately NOT a framework concern — but
extensions that want to provide it currently have no deploy-time integration
point: the compute units that execute handlers are created deep inside each
runtime backend, invisible to extension code running in the same deploy
program. This plan adds the missing seam, in the same spirit as the existing
runtime seams (middleware hooks, adapter wrapping): the framework tells whoever
is listening "I just provisioned an execution unit"; what to do about it is the
listener's business.

## Runtime-neutrality requirement (design driver)

The seam must fit **every** runtime implementation of
`ReventlessCore.Runtime.environmentMaker`, current and future — not just the
Lambda backend:

| Runtime | Execution unit | What "failing" natively looks like |
|---|---|---|
| AWS Lambda (`RuntimeEnvironment_Lambda`) | one Lambda function (often hosting many components — Single/Micro flavors) | `AWS/Lambda Errors` metric |
| Kubernetes (`RuntimeEnvironment_K8s`, in development) | one Deployment of NATS-JetStream consumers (KEDA-scaled) | container restarts / crash-loop, consumer redeliveries & lag |
| In-memory/local | in-process, no provisioned unit | n/a (never notifies; Noop default regardless) |

Two consequences drove the design:

1. **The seam announces units, not failure semantics.** What "handler failure"
   means is provider-specific (an Errors metric vs. restart counts vs. NATS
   redeliveries) and belongs in the extension's per-provider implementation.
   Core only says *that* a unit exists and *what role* it plays. This is what
   keeps the contract stable across runtimes.
2. **The unit is described by the existing `Adapter.resource` vocabulary** —
   both current backends already construct these at their provisioning sites
   (`aws:lambda:Function` with the function name; `apps/v1:Deployment` with
   the deployment name, `role="runtime"`, provider extras in `configuration`).
   `component.name` is precisely what a CloudWatch alarm (FunctionName
   dimension) or a PrometheusRule (deployment selector) needs. No new resource
   vocabulary.

Note the unit ≠ domain component: with the Single/Micro builder flavors one
unit executes many components. The seam is about the *provisioned compute*, the
thing whose health a monitoring system watches.

## Design

### 1. Core: `Monitoring` registry (`reventless-core/src/adapter/Monitoring/Monitoring.res`)

```rescript
// The ROLE of the provisioned unit, not its mechanism. Grounded in the actual
// runtime-builder inventory (every maker of execution units, both backends);
// `Other(string)` is the escape hatch for support units and future roles
// (same pattern as the protocol's `OtherKind`).
type unitKind =
  | CommandHandler   // aggregates, state-change slices, extension points —
                     // failure = writes rejected/dropped (the silent-freeze class)
  | Projection       // state-view slices, read models — failure = SILENTLY
                     // STALE READS (same operator-invisible class as the freeze)
  | Reactor          // automation slices, side-effect handlers, translations —
                     // failure = missed side effects at boundaries
  | EventCollector   // cross-plugin/admin event ingestion — failure = event
                     // flow between plugins stops
  | Task             // scheduled task runners
  | Scheduler        // heartbeat/keep-alive — failure = lifecycle detection AND
                     // any staleness watchdog go blind (monitoring's own pulse)
  | DeadLetterSink   // receives messages that exhausted processing
  | Other(string)    // support units (counters, change-feed relays, migration
                     // runners, query resolvers, …) — providers pass their name

// Registered by an extension (deploy program) BEFORE the platform builds.
// `~name` is the unit's STATIC logical name (the string the builder passed to
// its provisioning call) — required because a Pulumi-based backend derives
// logical resource names from it, and `component`'s fields are Outputs
// (physical, suffix-bearing — right for metric dimensions, unusable as logical
// names).
module type Backend = {
  let onProvisioned: (
    ~kind: unitKind,
    ~name: string,
    ~component: ReventlessInfra.Adapter.resource,
  ) => unit
}

module Noop: Backend
let use: module(Backend) => unit          // called by the extension, once, first
let notify: (
  ~kind: unitKind,
  ~name: string,
  ~component: ReventlessInfra.Adapter.resource,
) => unit                                 // called by runtime backends at provisioning sites
```

Mutable module-level ref, `Noop` default. No config passes through core: an
extension reads its own configuration (stack config etc.) itself. Because
`notify` fires during resource creation inside the deploy program, a
Pulumi-based backend implementation can create monitoring resources in the same
stack (CloudWatch alarms, PrometheusRule CRs, …), parented naturally.

### 2. Backend obligation (the conformance rule)

**Every implementation of `Runtime.environmentMaker` MUST call
`Monitoring.notify` once per execution unit it provisions**, with the unit's
`Adapter.resource`; a backend that provisions a dead-letter mechanism notifies
it with `DeadLetterSink` (the resource may be a function, a workload, or a
stream/consumer — role-based kind, mechanism-agnostic resource). Backends that
provision nothing (in-memory) call nothing. Add this rule to the
adapter-conformance checklist (`conformance-test-kit.md`).

Both existing infrastructures have exactly **one choke point each**, which
validates the shape:

- `reventless-aws`: `RuntimeEnvironment_Lambda.makeFromCodeAsset` — every
  execution-unit Lambda flows through it (verified by call-site sweep: ~20
  builder call sites). It gains a required `~unitKind` argument and calls
  `notify` after creating the function; each builder passes its role, and the
  compiler enforces the sweep is exhaustive:
  `AggregateRuntime_Builder_*` / `StateChangeSliceRuntime_Builder` /
  `ExtensionPointRuntime_Builder_*` / `PluginExtensionPointRuntime_Builder` →
  `CommandHandler`; `StateViewSliceRuntime_Builder` (+ read-model units) →
  `Projection`; `AutomationSliceRuntime_Builder` /
  `SideEffectHandlerRuntime_Builder` → `Reactor`;
  `EventCollectorRuntime_Builder_*` + the admin event collector →
  `EventCollector`; `TaskRuntime_Builder_PerBucket` → `Task`; the heartbeat
  entry point (`PluginRuntime_Builder`) → `Scheduler`;
  `CounterHandler_DynamoDbStream` / `PgChangeFeedRelay_Builder` /
  `PgMigration_Builder` / `PgQueryResolver_Builder` → `Other("Counter")` etc.
  Second site: `Util_DeadLetterQueue` (`DeadLetterSink`).

  Why the taxonomy matters even though the seam carries no failure semantics:
  an extension keys **severity, thresholds, and routing** on the role — a
  `CommandHandler` failure pages, a `Projection` failure warns of stale reads,
  a `Scheduler` failure means monitoring itself is blind (escalate), an
  `Other("Counter")` might only log. A minimal implementation may treat all
  kinds identically at zero extra cost; the vocabulary makes differentiation
  possible later without touching core again.
- Kubernetes runtime: its deployment maker in `RuntimeEnvironment_K8s` — the
  single site that creates consumer `Deployment`s (+ KEDA ScaledObject) and
  already builds the corresponding `Adapter.resource`. One added `notify` call
  when that backend adopts the seam; its dead-letter mechanism notifies
  `DeadLetterSink` when it lands.

Out of scope (follow-up if wanted): AWS AppSync resolver/API Lambdas created
outside `makeFromCodeAsset` — different failure surface (API errors are
user-visible), not the silent-freeze class.

### 3. `rescript-pulumi-aws`: `Cloudwatch_MetricAlarm` binding

Mechanical addition (`Cloudwatch/Cloudwatch_MetricAlarm.res`,
`aws.cloudwatch.MetricAlarm`): namespace, metricName, dimensions, statistic,
period, evaluationPeriods, threshold, comparisonOperator, treatMissingData,
alarmActions, tags. SNS `Topic`/`TopicSubscription` bindings already exist.
Required by any AWS alarm-provisioning consumer of the seam; belongs in the
bindings package rather than being re-bound locally by each consumer. (The
Kubernetes counterpart — PrometheusRule/Alertmanager CRs — lives with that
runtime's binding surface, not here.)

## Scope: what the seam is (and is not) for

The seam is a **deploy-time inventory hook**: it fires once per unit at
provisioning, never at invocation, and runs zero code in production. That makes
it suitable for any per-unit deploy-time concern, not only alarms:

- **Alarms** — attach failure alarms per unit (first consumer).
- **Dashboards / unit-level metrics** — providers already record per-unit
  invocation counts, durations, and error rates with no framework work
  (Lambda `Invocations`/`Duration`/`Errors`; container & consumer metrics on
  Kubernetes). What is missing is the enumeration — the seam lets an extension
  auto-generate dashboards ("all Projections, grouped by plugin, with rates")
  from the role-tagged catalog. No new instrumentation needed for unit-level
  counting.
- Per-unit log-retention / metric-filter policies, cost-allocation audits,
  inventory registration.

**Not this seam**: component- and domain-level runtime metrics ("how often did
projection X run", per-command counts, projection lag, per-event-type
throughput). One unit hosts many components (Single/Micro flavors), so provider
metrics cannot see components at all — such metrics need hooks that fire **per
invocation with domain context**: the runtime seams (middleware pre/post-command
hooks, event-topic subscription, adapter wrapping). Those carry real
per-invocation cost and stay opt-in extension territory, complementing the
existing runtime-metric islands (`~dcbMetrics` DCB retry/conflict filters, the
per-handler ConsoleStats resources). Keeping deploy-time inventory and runtime
instrumentation as separate seams is deliberate.

## Ordering contract

`Monitoring.use(backend)` must run before the platform/plugin build in the
deploy program (plain statement order — the registry is consulted lazily at
each provisioning site). Document on `use`.

## Acceptance

- With no backend registered: byte-identical deploys on every runtime (Noop,
  zero resources).
- A test backend registered in an example deploy records one `notify` per
  execution unit the stack provisions, plus one `DeadLetterSink`, with
  `component.name` resolving to the unit's native name (function name /
  deployment name).
- The seam contract contains no Lambda-specific vocabulary (review test:
  the table above must be expressible without changing `Monitoring.res`).
- Conformance checklist gains the backend obligation (§2).
- Train: publish `reventless-core` + `reventless-aws` + `rescript-pulumi-aws`.

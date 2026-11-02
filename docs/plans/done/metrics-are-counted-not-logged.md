# Plan: the local platform counts its metrics instead of logging them

**Date:** 2026-11-02<br/>
**Status:** ✅ Built 2026-11-02, as planned ([§7](#7-as-built)); the open questions decided as
recommended.<br/>
**Repos:** `reventless-core` only.<br/>
**Builds on:** [the-local-platform-serves-what-is-watched.md](../the-local-platform-serves-what-is-watched.md)
(the platform API's watching reads, which this adds one to) ·
[dcb-high-contention-handling.md](../../analysis/dcb-high-contention-handling.md) (why the append
metrics exist).

> **Questions and short answers**
>
> - *Where does the platform emit metrics today?* **In one place: a DCB state change slice's
>   command handler.** It emits five counts per slice: a decision read served from the cache or
>   missing it, how many events a cached read still had to read, an append retried after a
>   concurrent write, and an append that gave up ([§1](#1-why)).
> - *Should metrics be in the log at all?* **Not locally.** A metric is a count, not something
>   that happened; one command yields one or two of them, and what a reader wants is the totals.
>   Deployed, the log line is how CloudWatch collects them, so there it stays ([§1](#1-why),
>   [LMCD1](#4-decisions)).
> - *What does this plan change?* **Where a metric goes is chosen at start, like the PII
>   provider.** Deployed, it is written as the JSON line it is today. The local platform counts
>   it in memory per metric, slice and plugin, writes nothing, and serves the counts on the
>   platform API ([LMC1](#lmc1-a-metric-sink-chosen-at-start) to
>   [LMC3](#lmc3-the-counts-on-the-platform-api)).
> - *Does anything deployed change?* **No.** The line, its fields and the CloudWatch metric
>   filters stay as they are ([LMCD2](#4-decisions)). Writing the line in CloudWatch's embedded
>   metric format instead is a separate question ([LMCQ3](#5-open-questions)).
> - *Who reads the counts?* **Anything that watches a local platform**: a tool's metrics summary,
>   the MCP server, a script against the platform API ([LMC3](#lmc3-the-counts-on-the-platform-api)).

The steps are numbered **LMC1 to LMC5**, the decisions **LMCD1 to LMCD4**, the open questions
**LMCQ1 to LMCQ3**. LMC stands for *local metric counts*.

---

## 1. Why

**In plain words:** when the shop places an order, the slice that decides it notes a few numbers
along the way. Was the order's history still in the cache, or did it have to be read from the
start? Did two orders for the same product collide, so that one had to try again? Those numbers
are *metrics*: nobody needs each one, but their totals say whether a slice is healthy. Ninety
cache hits out of a hundred is fine; ninety misses means the cache does nothing.

Today each such number is written to the platform's output as a line of JSON, beside the log
lines. On AWS that is the point: CloudWatch reads the Lambda's output and turns every line with
the `reventlessMetric` field into a data point of a real metric, through one metric filter per
metric name ([Util_DcbMetrics.res](../../../reventless/aws/src/util/Util_DcbMetrics.res)).

Locally nothing collects them. They land in the output among the log lines, where a person
watching the log sees a line per command that says nothing on its own (`{"reventlessMetric":
"DcbDecisionModelCacheMiss","slice":"PlaceOrder","value":1}`), and nowhere can the totals be read.

The five metrics, all emitted by
[StateChangeSlice_Callback.res](../../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)
through [Metrics.res](../../../reventless/core/src/util/Metrics.res):

| Metric | Counts | Emitted |
|---|---|---|
| `DcbDecisionModelCacheHit` | a decision read seeded from the warm cache | once per command |
| `DcbDecisionModelCacheMiss` | a decision read that had to read in full | once per command |
| `DcbDecisionModelDeltaEventCount` | the events a cached read still read (its value is the count) | once per cache hit |
| `AppendRetry` | an append retried after a concurrent write | once per retry |
| `AppendConflict` | an append that gave up after its retries | once per command that gave up |

## 2. Scope

**In:**
- Choosing where a metric goes at start: the JSON line, or a count kept in memory.
- The local platform counting its metrics, per metric, slice and plugin, and serving them.
- The counts on the platform API, behind its admin check.

**Out:**
- Anything deployed: the line, its fields and the metric filters stay.
- New metrics. The five stay as they are; a new one later goes through the same sink.
- Showing the counts. That is for whoever reads them.

## 3. Steps

### LMC1: a metric sink chosen at start

[Metrics.res](../../../reventless/core/src/util/Metrics.res) keeps `emitCount` as the one call that
emits a metric. Where the count goes becomes a *sink*, installed at a process's start the way
`Pii.Provider.install` installs the PII provider
([Pii.res](../../../reventless/spec/src/components/Pii.res)):

- `Metrics.Sink.install(sink)`, where a sink is a function taking the metric's name, its slice,
  its value and its unit.
- The default sink is today's behavior: the JSON line, written only to a JSON log sink. Nothing
  deployed installs another, so nothing deployed changes.
- `emitCount` adds the plugin the slice belongs to, read from the registry that already names a
  log line's plugin ([LogPrefix.res](../../../reventless/spec/src/LogPrefix.res)), so a sink can count
  by plugin. The JSON line does not gain the field ([LMCD2](#4-decisions)).

### LMC2: the local platform counts in memory

The local platform installs a counting sink at start, beside setting its log level
([Platform.res](../../../reventless/local/src/Platform.res)). For each metric, slice and plugin it
keeps:

- the number of times it was emitted, and the sum of its values (for
  `DcbDecisionModelDeltaEventCount` the sum is what matters: events read in total);
- the time of the last one;
- the counts of the last 60 minutes, one bucket a minute, so a reader can draw a rate.

It writes nothing to the output. Memory stays bounded: the counters grow with the number of
slices, not with the number of commands, and the buckets are a ring of 60.

The counts restart with the platform ([LMCQ1](#5-open-questions)).

### LMC3: the counts on the platform API

[LocalPlatformObserve.res](../../../reventless/local/src/adapter/LocalPlatformObserve.res) adds one
read beside `Platform_EventLog` and `Platform_LogLevels`:

```graphql
type Platform_MetricCount {
  metric: String!
  plugin: String!
  slice: String!
  count: Int!
  sum: Float!
  unit: String!
  lastAt: String
  perMinute: [Int!]!   # the last 60 minutes, oldest first
}

Platform_Metrics(plugins: [String!]): [Platform_MetricCount!]!
```

Behind the same admin check as the other watching reads. A reader polls it; there is no
subscription, since a count that changes many times a second is better read than pushed
([LMCQ2](#5-open-questions)). The MCP server gets the same as a resource, `platform/metrics`.

### LMC4: tests

- The default sink writes the line it writes today, byte for byte (the CloudWatch filters key on
  it).
- The counting sink counts by metric, slice and plugin, sums values, and rolls its minute buckets.
- The platform API answers `Platform_Metrics` for an admin only, narrowed by plugin.
- A local platform's output carries no `reventlessMetric` line.

### LMC5: the docs

- [§7 of the plan that serves the watching reads](../the-local-platform-serves-what-is-watched.md#7-the-wire-as-built),
  the list of what the platform API serves, gains `Platform_Metrics`.
- The [CloudWatch Logs Insights guide](../../guides/cloudwatch-logs-insights.md) says that a line
  with `reventlessMetric` is a metric on its way to CloudWatch, not a log line, and that its
  numbers are read as metrics there rather than queried.

## 4. Decisions

| # | Decision | Decided | Why |
|---|---|---|---|
| LMCD1 | Locally, metrics leave the output | **counted in memory, not written** | a count read one occurrence at a time says nothing; its total does |
| LMCD2 | Deployed | **unchanged: the same JSON line, the same filters** | CloudWatch's metric filters depend on the line; changing it is its own decision ([LMCQ3](#5-open-questions)) |
| LMCD3 | The one call that emits | **`Metrics.emitCount` stays; only its sink is chosen** | the slice handler does not know, or care, where its counts go |
| LMCD4 | How a reader gets them | **a read on the platform API, polled** | the same door, check and filter as the other watching reads |

## 5. Open questions

**LMCQ1. Should the counts survive a restart?** Kept in the SQLite store, they would. A
restart is also when a developer wants a clean count, and the store would gain a table for
something no app decision depends on. **Recommendation:** no, they live in memory and restart with
the platform. Revisit if someone compares counts across restarts.

**LMCQ2. A subscription for the counts as well as the read?** A tool watching live would see a
change at once. Every command changes a count, so a subscription would push as often as the log
does, which is what this plan takes metrics out of. **Recommendation:** no; a reader polls, every
few seconds while it shows the counts. Revisit if a reader needs sub-second counts.

**LMCQ3. Should the deployed line move to CloudWatch's embedded metric format?** That format
(`_aws` metadata in the same JSON line) makes CloudWatch create the metric itself, without one
metric filter per name, and adds a new metric without a deploy change. It changes the line every
existing filter keys on, and a provider-neutral core would then write AWS's own shape.
**Recommendation:** not in this plan. Decide it when a sixth metric is added, since that is when a
filter per metric starts to cost something.

## 6. Acceptance

- A local platform running the online shop writes no `reventlessMetric` line, and
  `Platform_Metrics` answers each DCB slice's hits, misses, retries and conflicts, by plugin.
- A deployed platform's Lambda output carries the same metric lines as before, and its CloudWatch
  metrics keep receiving data.
- The tests of [LMC4](#lmc4-tests) pass.

## 7. As built

- **The sink.** [Metrics.res](../../../reventless/core/src/util/Metrics.res): `Metrics.Sink.install`
  and `Metrics.Sink.reset`; `Sink.line`, the default, writes the line it wrote before. `emitCount`
  hands each sink a `sample` with the slice's plugin from the log registry.
- **The counts.** `Metrics.Counts`, in core so any platform can use it: `make`, `add`, `sink`,
  `read(~now, ~plugins?)` and `clear`. Entries are keyed by metric, plugin and slice; the 60
  minute buckets roll on both write and read, so a slice quiet for an hour reads all zeros.
- **The local platform.** [LocalMetrics.res](../../../reventless/local/src/adapter/LocalMetrics.res)
  holds the counts and installs their sink when [Platform.res](../../../reventless/local/src/Platform.res)
  loads. [LocalPlatformObserve.res](../../../reventless/local/src/adapter/LocalPlatformObserve.res)
  serves `Platform_Metrics(plugins)`, admin-checked, and the MCP resource `platform/metrics`.
  The platform API's golden,
  [platform-api.graphql](../../../reventless/spec/schema/platform-api.graphql), follows.
- **Tests.** [MetricsTest.res](../../../reventless/core/tests/util/MetricsTest.res) (the sink, the
  counts, their minutes, the plugin filter) and
  [LocalPlatformObserveTest.res](../../../reventless/local/tests/adapter/LocalPlatformObserveTest.res)
  (refused to a non-admin, narrowed by plugin).
- **Docs.** [§7 of the watching-reads plan](../the-local-platform-serves-what-is-watched.md#7-the-wire-as-built)
  lists the read, and the [CloudWatch Logs Insights guide](../../guides/cloudwatch-logs-insights.md#tips)
  says a `reventlessMetric` line is a metric.

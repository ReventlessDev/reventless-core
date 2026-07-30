# Log Retention and Log Levels per Environment

## Context

Today every CloudWatch log group in a Reventless AWS deployment keeps its logs
**forever**. Lambda log groups are auto-created by the Lambda service with no
retention policy, AppSync creates its own with no retention, and the one place
the framework *can* set retention is wired to only three of the ~25 Lambda
builders — and even there it is not applied by default. The result is unbounded
log storage growth and cost across every stack, including short-lived `alpha`,
`beta`, and `pr-*` stacks whose logs stop being useful within hours.

The goal of this analysis:

- Establish what we actually want from logs, separately for production and for
  the ephemeral dev stacks — the goals genuinely differ.
- Propose environment-tiered **retention** so prod keeps logs long (or forever)
  while alpha/beta keep them briefly.
- Decide whether **log levels** should differ per environment.
- Identify everything else worth improving about logging.
- Describe how to **wipe the logs that have already accumulated**, and which of
  them are safe to wipe.

Related: [logging-output-optimization.md](./logging-output-optimization.md)
(log *format*), [command-handler-lambda-per-flavor-tuning.md](./command-handler-lambda-per-flavor-tuning.md)
(where `logRetentionDays` came from), [protecting-prod-infrastructure-resources.md](./protecting-prod-infrastructure-resources.md)
(the existing prod/non-prod conditional-config pattern this proposal reuses),
[telemetry-substrate.md](./telemetry-substrate.md).

## Current state

### Retention — effectively "never" everywhere

The only place a managed log group with retention is created is
[`RuntimeEnvironment_Lambda.res:266-310`](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L266-L310),
guarded by an optional `~logRetentionDays`:

```rescript
// When not set, Lambda auto-creates a log group with no retention
// (logs accumulate indefinitely).
logRetentionDays->Option.forEach(days => {
  let logGroup = Cloudwatch.LogGroup.make(
    ~name=`${name}LogGroup`,
    ~args={
      name: `/aws/lambda/${name}`->Pulumi.Input.make,
      retentionInDays: days->Pulumi.Input.make,
      tags: tagsFor(~resourceName=`${name}LogGroup`, ~role=Logs),
    },
    ~opts?,
  )
  ...
})
```

`makeFromCodeAsset` is the shared factory for **every** Lambda, but only three
builders thread `~logRetentionDays` through at all — and they pass it as a bare
pass-through with no default:

- [`AggregateRuntime_Builder_Single.res:345`](../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res#L345)
- [`AggregateRuntime_Builder_Single_Async.res:320`](../../reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Single_Async.res#L320)
- [`StateChangeSliceRuntime_Builder_Single.res:241`](../../reventless/aws/src/adapter/Runtime/StateChangeSliceRuntime_Builder_Single.res#L241)

The config type already carries the field, and even defines a default that is
never used — [`Runtime.res:196-224`](../../reventless/core/src/adapter/Runtime/Runtime.res#L196-L224):

```rescript
type commandHandlerConfig = {
  memorySize?: int,
  timeout?: int,
  reservedConcurrency?: int,
  sqsBatchSize?: int,
  ephemeralStorageMb?: int,
  logRetentionDays?: int,
  envVars?: dict<string>,
}

module CommandHandlerDefaults = {
  let memorySize = 1024
  let timeout = 30
  let sqsBatchSize = 10
  let ephemeralStorageMb = 512
  let logRetentionDays = 7   // ← defined, but NOT applied
}
```

Note the asymmetry: `memorySize`/`timeout` fall back via
`->Option.getOr(CommandHandlerDefaults.…)`, but `logRetentionDays` is passed as
`=?cfg.logRetentionDays` with no `getOr`. **So the "7-day default" documented in
[lambda-deployment.md §10](../../packages/doc/docs-infrastructure/lambda-deployment.md)
is a phantom — it is never applied unless an app developer sets it explicitly.**
Out of the box, no `LogGroup` resource is created and retention is "never
expire" for all Lambdas.

Beyond Lambda:
- **AppSync** ([`AppSync_Adapter.res:497-547`](../../reventless/aws/src/components/Api/AppSync_Adapter.res#L497-L547))
  sets `fieldLogLevel: ERROR` and a logs role but creates **no** `LogGroup` and
  **no** retention — its `/aws/appsync/apis/<id>` group also lives forever.
- SQS/SNS/DynamoDB create no log groups; various adapters only grant
  `logs:*` IAM actions.

### Measured state — `eu-west-1`, 2026-07-30

The analysis above is confirmed by the account, not just by reading the code:

| | |
|---|---|
| log groups in region | 241 |
| …with a retention policy | **0** |
| stored, live groups | 1.3 GiB |
| stored, orphaned groups | 1.4 GiB |

Every group — Lambda *and* AppSync — reported `retentionInDays: null`. Not one
deployment anywhere has ever set retention, which makes the phantom default above
an observed fact rather than an inference.

### Orphan accumulation — the structural cost of an unmanaged log group

181 of those 241 groups were `/aws/lambda/<name>` where **no such Lambda exists**.
That is the part retention alone does not explain, and it is a second, independent
argument for the proposal below.

Because nothing sets `~logRetentionDays`, Pulumi never creates the `LogGroup`, so
Lambda auto-creates it — and Pulumi therefore never *deletes* it. `pulumi destroy`
removes the function and leaves its logs behind permanently, with no retention to
age them out. Every deploy whose Lambda name changes suffix strands another group.
The distribution shows exactly that: `CustomerPluginHeartbeat` ×13,
`CustomerAggrCmdGen` ×9, `AllReadModels` ×6 — 62 distinct components across ~11
months of deploy cycles, including stacks (`customer/dev`, `core/dev`) last touched
long ago.

**Swept 2026-07-30:** all 181 orphans deleted, 1.4 GiB reclaimed, 241 → 60 groups.
The 7 AppSync groups and 53 groups belonging to live functions were left untouched.
This will recur on the same curve until log groups become Pulumi-managed — the sweep
treats the symptom.

### Retention also gates observability, not only cost

`~logRetentionDays` is not merely a cost knob: it is the switch that decides whether
a *managed* log group exists at all, and other features hang off that group.
[`RuntimeEnvironment_Lambda.res:116-118`](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L116)
says so directly — `~dcbMetrics` "requires a managed log group, so it only takes
effect when `~logRetentionDays` is also set."

The two arguments are set in the same call, three lines apart, and disagree —
[`StateChangeSliceRuntime_Builder_Single.res:241-245`](../../reventless/aws/src/adapter/Runtime/StateChangeSliceRuntime_Builder_Single.res#L241):

```rescript
~logRetentionDays=?cfg.logRetentionDays,   // None unless the app opts in
…
~dcbMetrics=true,                          // unconditional
```

In `RuntimeEnvironment_Lambda` the `if dcbMetrics` block sits *inside*
`logRetentionDays->Option.forEach(…)`, so `None` skips the metric filters along with
the log group. Every DCB state-change command handler therefore asks for
`AppendRetry` / `AppendConflict` / `DcbDecisionModelCacheHit|Miss` /
`DcbDecisionModelDeltaEventCount`, and gets none of them — on every stack, including
prod. The code is present, wired, and inert; the request is silently dropped by a
guard about something else.

Fixing retention switches them on as a side effect. Worth knowing in both directions:
before someone spends time debugging why those metrics are missing, and before the
retention rollout makes a batch of new metric filters appear unannounced.

### Cost calibration — this is a hygiene fix, not a savings fix

Worth stating plainly, because "save storage and therefore money" is the obvious
motivation and it is the weakest of the reasons here. CloudWatch Logs bills
**ingestion** at roughly an order of magnitude more per GB than **storage** per
GB-month (check current `eu-west-1` figures before quoting any number). Retention
only reduces stored bytes. At the measured 2.7 GiB total, the storage line is
pennies per month, and cutting retention to 7 days would save a fraction of that.

The real returns, in descending order of value:

1. **Ingest volume is the money lever, and it is a *level* decision, not a retention
   decision** — so the log-level tiering in the proposal matters more financially
   than the retention tiering.
2. **Orphan accumulation stops** once Pulumi owns the groups.
3. **DCB metrics start existing.**
4. **A bounded data-retention horizon** for anything personal that reaches a log line
   — a compliance property, not a cost one, and the one that would be hardest to
   retrofit under pressure.

Retention is still worth fixing; it is just worth fixing for reasons 2–4.

### Log level — one global default, env-var driven

Log level is chosen entirely by the `LOG_LEVEL` environment variable, read per
call in [`Logger.res`](../../reventless/core/src/util/Logger.res) (mirrored in
[`EffectLogger.res`](../../reventless/core/src/util/EffectLogger.res)):

```rescript
switch _logLevel {
| Some("silent") => None
| Some("debug") => Some(Debug)
| Some("info") => Some(Info)
| Some("warn") => Some(Warn)
| Some("error") => Some(Error)
| Some(_) => Some(Info)          // unrecognized ⇒ Info
| None => Some(defaultMinLevel.contents)   // default ⇒ Info
}
```

- Levels: `Debug | Info | Warn | Error`, plus `silent` to suppress everything.
- Default when `LOG_LEVEL` is unset is **`Info`** (`defaultMinLevel = ref(Info)`);
  `reventless-local` lowers it to `Debug`.
- There is **no first-class log-level config field** on the Lambda. The only way
  to set it per deployment is the generic `envVars` map in `commandHandlerConfig`
  — and again only for the three command-handler Lambdas.
- Logs are structured JSON in Lambda (queryable `level`/`message`/`comp`/`data`
  keys, `service` from `REVENTLESS_SERVICE`/`AWS_LAMBDA_FUNCTION_NAME`, detail
  truncated at `REVENTLESS_LOG_MAX_DETAIL_BYTES`, default 32 KB).

### Environments already have a distinction — logging just doesn't use it

Environments are Pulumi stacks (`alpha`, `beta`, `main`, `prod`, plus ephemeral
`pr-verify` / `pr-<n>`). The stack name is read at deploy time via
`Pulumi.Pulumi.getStackName()` and already injected into every Lambda as the
`Environment` env var and the `reventless:environment` tag.

Critically, a **prod/non-prod distinction already exists** and is used for other
conditional config —
[`Util_HostUiDomain.res`](../../reventless/aws/src/util/Util_HostUiDomain.res):

```rescript
let defaultProdStacks = ["prod", "main"]
let resolveProdStacks = () =>
  Util_LocalConfig.get("hostUiProdStacks")
    ->Option.map(parseProdStacks)->Option.getOr(defaultProdStacks)
```

This same allow-list already drives store layout (`PerStore` vs `SharedBucket`)
and delete-protection in [`Util_StoreLayout.res`](../../reventless/aws/src/util/Util_StoreLayout.res).
**It is the natural hook for environment-tiered logging — but nothing wires
logging into it today.**

## Goals — and why they differ by environment

Logs serve different purposes in production vs. the dev stacks, and the retention
and level decisions fall straight out of the goals.

### Production goals

1. **Incident diagnosis.** When something breaks at 3am, the logs must still be
   there. This is the primary reason prod logs need to survive well beyond the
   moment of failure — an issue may not surface for days.
2. **Security forensics.** Detecting and reconstructing a breach typically needs
   weeks-to-months of history. Common baselines land around 90 days hot, longer
   in cold storage.
3. **Trend / regression analysis.** Comparing error rates or latency across
   releases needs a reasonable window of history.
4. **Not the audit source of truth.** The event log itself is the durable
   record of what happened to the domain — CloudWatch logs are operational
   telemetry, not the system of record. This matters: it means prod logs do
   **not** need to be kept forever for correctness, only long enough for
   operations and security.

Implication: prod wants **long finite retention** (order of a year), a **signal-
rich but not noisy** level (`info`), and — if a compliance regime truly demands
multi-year retention — **cheap cold archival** rather than years of hot
CloudWatch storage.

### Alpha / beta / PR-stack goals

1. **Fast feedback during an active debugging session.** Logs are consumed
   within minutes-to-hours of being produced, usually by the person who just
   deployed.
2. **Verbosity beats retention.** During development you want *more* detail
   (`debug`), but you want it *now* — yesterday's debug logs are worthless.
3. **Cheap and disposable.** These stacks are recreated constantly; reproducing
   a scenario is a redeploy away, so keeping logs around has almost no value.
4. **Cost control.** Dozens of ephemeral stacks × forever-retention × verbose
   logging is pure waste.

Implication: dev stacks want **short retention** (days) combined with a **verbose
level** (`debug`) — verbose but discarded fast is exactly the right trade.

The key insight: **retention and level pull in opposite directions between the
two worlds.** Prod = quiet + long-lived; dev = loud + short-lived. A single
global setting cannot serve both, which is why this should be environment-tiered.

## Proposal

### 1. Environment-tiered retention (applied to *all* log groups)

Introduce a retention tier derived from the stack name, reusing the existing
prod allow-list. CloudWatch only accepts a fixed set of `retentionInDays` values
(`1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, …, 3653`, and
`0` = never expire), so the tiers must pick from that enum.

| Tier | Stacks | Retention | Rationale |
|------|--------|-----------|-----------|
| **prod** | `prod`, `main` (the `hostUiProdStacks` allow-list) | **365 days** (configurable; `0` for never) | Incident + forensic window without unbounded cost |
| **staging** | `beta` | **30 days** | Pre-prod validation; a month of history is ample |
| **dev** | `alpha`, and default for anything else | **7 days** | Active development; logs consumed within hours |
| **ephemeral** | `pr-verify`, `pr-<n>` | **3 days** | Torn down quickly; minimal footprint |

Add a resolver next to the existing prod-stack logic — conceptually:

```rescript
// Util_LogRetention.res (new), sibling to Util_StoreLayout / Util_HostUiDomain
let retentionDaysFor = (~stack, ~prodStacks) =>
  switch stack {
  | s if prodStacks->Array.includes(s) => 365
  | "beta" => 30
  | s if s->String.startsWith("pr-") => 3
  | _ => 7  // alpha and all other non-prod stacks
  }
```

Then **apply it to every Lambda**, not just the three command handlers, by
defaulting `~logRetentionDays` inside `RuntimeEnvironment_Lambda.makeFromCodeAsset`
when the caller doesn't override it. This is the single biggest change: it turns
"forever for all ~25 Lambdas" into "environment-appropriate for all of them."
Also create a managed `LogGroup` with the same retention for the AppSync API.

Precedence (least surprising): explicit `commandHandlerConfig.logRetentionDays`
→ per-stack override via a new Pulumi config key (e.g. `logRetentionDays`, CSV or
per-tier, mirroring `hostUiProdStacks`) → the tier default above.

**Why 365 and not "forever" for prod:** CloudWatch storage is billed per GB-month
indefinitely, and logs older than ~a year almost never get read. If a compliance
regime requires multi-year retention, the cost-effective pattern is a CloudWatch
**subscription filter → S3 (→ Glacier)**, not years of hot log storage. Keep
`0` (never) available as an explicit opt-in, but don't make it the default. This
is worth a follow-up if a real retention requirement lands.

### 2. Environment-tiered log level

Yes — levels should differ, and it falls straight out of the goals above.

| Tier | Default `LOG_LEVEL` | Rationale |
|------|--------------------|-----------|
| prod / main | `info` | Operational signal without debug noise or cost; debug detail can leak sensitive payloads |
| beta | `info` | Mirror prod so pre-prod behaves like prod |
| alpha / pr-* / other | `debug` | Verbose feedback during active development (paired with short retention, so cheap) |

Two changes:

- **Promote log level to a first-class field.** Add `logLevel?: string` (or a
  proper variant) to `commandHandlerConfig` rather than requiring people to hand-
  set `envVars["LOG_LEVEL"]`. The AWS builder maps it onto the `LOG_LEVEL` env var
  the logger already reads.
- **Default `LOG_LEVEL` per tier** when unset, injected in the same place the
  `Environment` env var is set ([`RuntimeEnvironment_Lambda.res:223`](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L223)),
  and for **all** Lambdas, not just command handlers.

Keep `silent`/explicit overrides working — a developer chasing a specific bug on
prod can temporarily bump a single function to `debug` via config, and a noisy
alpha stack can be dialed back.

### 3. Apply both to every Lambda + AppSync, by default

The recurring theme in both changes: today's config only reaches 3 of ~25
Lambdas. The proposal only works if the tier defaults are applied **inside the
shared `makeFromCodeAsset` factory** so every event collector, side-effect
handler, extension point, resolver, task, DLQ, and plugin-runtime Lambda gets an
environment-appropriate retention and level with zero per-builder wiring.

Measured coverage today, for the record: 20 modules call `makeFromCodeAsset`; four
mention `logRetentionDays`, and one of those is `RuntimeEnvironment_Lambda` itself.
So three builders, as above.

#### Prerequisite: the managed log group is currently named wrong

**Enabling `~logRetentionDays` as the code stands would not work, and would look like it
had.** The log group's name is built from the *logical* name while the function's
physical name carries Pulumi's auto-name suffix:

```rescript
let lambda = Lambda.Function.make(~name, ~args={ /* no `name` field exists */ })
//                     physical name becomes  AllReadModels-11898ba
…
name: `/aws/lambda/${name}`->Pulumi.Input.make
//                     group becomes         /aws/lambda/AllReadModels
```

`Lambda.Function.args` has **no** `name` field, so the physical name cannot be pinned —
it is always `<logical>-<7hex>`. Verified against the account: all 53 live Lambda log
groups carry the suffix, and **not one** unsuffixed group exists.

Turning the flag on today would therefore produce:

1. An **empty** `/aws/lambda/AllReadModels` with the configured retention.
2. The real `/aws/lambda/AllReadModels-11898ba`, still auto-created by Lambda, still with
   no retention — **so orphan accumulation continues unchanged.**
3. DCB metric filters attached to the empty group, matching nothing, reporting zero
   forever — worse than being inert, because now they look provisioned.
4. A **cross-stack collision**: `alpha`, `beta` and `pr-*` share one account, so every
   stack would claim the same `/aws/lambda/AllReadModels`. The auto-name suffix is
   exactly what prevents this today.

**Fix — derive the group name from the function's own name output:**

```rescript
name: lambda.name
  ->Pulumi.Output.apply(n => `/aws/lambda/${n}`)
  ->Pulumi.Output.asInput,
```

`LogGroup.args.name` is `Pulumi.Input.t<string>`, so an Output is accepted. This keeps
the suffix, so uniqueness and the group↔function match both hold.

**Do not instead add `name` to the `Lambda.Function` args binding and pin it.** That
would replace every Lambda on every stack and reintroduce the collision the suffix
exists to prevent.

#### Migration hazard: the first deploy on an existing stack

Making log groups Pulumi-managed changes a **create** path on stacks that already
have the auto-created group. `Cloudwatch.LogGroup.make` with an explicit
`name: /aws/lambda/<fn>` will hit a group AWS already created, and
`CreateLogGroup` fails with `ResourceAlreadyExistsException` rather than adopting it.
Every existing stack — `alpha`, `beta`, prod — is in that state for every Lambda
that has ever been invoked.

Options, in order of preference:

1. **Adopt via `import`** — a `pulumi import` (or the `import` resource option) per
   group on first rollout. Correct, but ~25 imports per stack.
2. **Delete-then-deploy on ephemeral stacks only** — for `pr-*` and `alpha` the logs
   are disposable, so deleting the groups immediately before the first managed deploy
   is simpler than importing. Not acceptable for prod.
3. **Let the group name float** — omit the explicit `name` so Pulumi picks one; loses
   the `/aws/lambda/<fn>` convention that makes Lambda write into it, so this does not
   actually work for Lambda. Recorded only to close it off.

Whichever path: **roll it out on a `pr-*` stack first, from scratch, and verify the
group exists and carries the expected `retentionInDays`** — not merely that the deploy
went green. This is the same create-vs-update asymmetry documented in
[new-plugin-stack-create-path.md](../plans/done/new-plugin-stack-create-path.md),
where an update-only code path hid four defects, one of which was a resource that was
silently never created while the deploy reported success.

## What else could be improved about logs

1. **Fix the phantom default (or the docs).** Right now
   [lambda-deployment.md](../../packages/doc/docs-infrastructure/lambda-deployment.md)
   claims a 7-day retention default that the code never applies. Wiring the tier
   defaults (above) makes the docs true; until then, correct the docs.
2. **Retention on AppSync (and any future) log groups**, not just Lambda.
3. **Metric filters + alarms on `ERROR`.** The managed-log-group path already
   attaches `dcbMetrics` metric filters; extend that to an error-count metric and
   a CloudWatch alarm so prod failures page someone instead of sitting unread in
   logs that merely happen to be retained.
4. **Cold archive for prod** via subscription filter → S3/Glacier if long-term
   retention is ever required — far cheaper than forever-in-CloudWatch, and keeps
   the hot retention window short.
5. **Debug sampling in prod.** If a prod issue needs debug detail without the
   full cost/noise, sample debug logs (e.g. 1%) rather than flipping the whole
   fleet to `debug`.
6. **Cost-allocation tags on log groups.** Log groups already get `role=Logs`
   tags; ensure `reventless:environment` / `pulumi-stack` are present so log
   storage cost can be attributed per stack in Cost Explorer.
7. **Finish the format cleanup** tracked in
   [logging-output-optimization.md](./logging-output-optimization.md) — ANSI
   codes leaking into JSON make the retained prod logs harder to query, which
   compounds as retention grows.
8. **Give each line its own identity.**
   [`Runtime.annotateInvocation`](../../reventless/core/src/adapter/Runtime/Runtime.res#L15)
   annotates `correlationId`, `causationId`, `comp` and `pluginName` — but **not the
   emitting message's own `msgId`**. So `causationId` points at a message that cannot be
   located among the returned lines: anything reconstructing a causal chain from logs can
   produce a time-ordered sequence but never a tree. Adding `msgId` to the annotation is
   the one change that turns log lines from a list into a linkable graph. Relates to
   [aggregate-msgid-causation-correlation.md](../plans/Backlog/aggregate-msgid-causation-correlation.md).
9. **Attribution by tag, not by name-matching.** Once log groups are Pulumi-managed they
   can carry `plugin` / `component` / stack tags at creation. Today a consumer wanting
   "which plugin produced this row" has to match names heuristically, which breaks when a
   stack name hyphenates a camel-cased plugin (`catalog-search` vs `CatalogSearch`) — the
   row simply does not carry the plugin. Tagging at ingest removes the guesswork rather
   than improving the guess.
10. **`comp` granularity for shared runtimes.** `comp` identifies the *runtime* —
    `EventCollectorRuntime(<parentName>)` — not the domain element. For components that
    share a runtime Lambda (read models and projections behind one handler), filtering by
    `comp` cannot isolate a single element: the parent aggregate's name is what rides the
    line. A stable, key-derived `comp` would make per-element filtering exact instead of
    best-effort.
11. **Publish the effective logging configuration.** Retention days and minimum level are
    decided at deploy time and then invisible at read time. Exporting them per component
    lets a consumer distinguish three cases that look identical in a query result: nothing
    was logged, the level suppressed it, or the time range fell outside retention. See the
    next section — this is the single highest-leverage item on this list for anything built
    on top of these logs.

## What a log-exploration surface needs from the platform

Independent of any particular tool, an operator-facing view over these logs — a CLI, a
dashboard, an IDE panel — depends on guarantees the platform either provides or does not.
Recording them here so the retention and level work above lands in a shape such consumers
can actually use, rather than being retrofitted afterwards.

| Requirement | Status today | Affected by this proposal |
|---|---|---|
| Per-component filter (`comp` on every line) | present, runtime-granular only | no |
| Structured, queryable fields (`time`, `level`, `message`, `comp`, `plugin`) | present | no |
| `correlationId` / `causationId` on lines | present | no |
| Line's own `msgId` | **missing** — no causal tree possible | no (item 8) |
| Retention horizon, readable at query time | **missing** | **yes** — tiering makes it vary per stack |
| Effective minimum level, readable at query time | **missing** | **yes** — tiering makes it vary per stack |
| Plugin/component attribution on the row | **missing** — name heuristics only | **yes** — managed groups can be tagged |
| Stable log-group naming | suffix-based, stable | **yes** — see the naming fix in Proposal §3 |

**The absence-versus-zero problem is the one worth designing for.** Tiering retention and
level per environment introduces two brand-new reasons a query can legitimately return
nothing:

- the requested range predates the stack's retention window;
- the requested level is below the stack's effective minimum, so those lines were never
  emitted.

Neither is distinguishable from "this component was idle" unless the platform publishes the
horizon and the level. A consumer that cannot tell them apart will report "no activity" for
a component that was busy, which is worse than showing nothing — and the failure gets *more*
likely as retention shortens, i.e. it is created by the very change proposed here. Exporting
both values alongside the existing component metadata is a small addition and should land in
the same change as the tiering, not after it.

**Corollary for metric-backed views.** The DCB metric filters described above are currently
provisioned nowhere, so any view rendering them sees permanent absence. Once retention is set
they begin to exist, and components will flip from "no metric-backed data" to real values
without the consumer changing. Anything that caches or special-cases the empty state should
expect that transition rather than treat it as a regression.

## Wiping the logs that already exist

> **Partly done — 2026-07-30.** The 181 orphaned Lambda groups (1.4 GiB) were deleted
> outright, i.e. Option B, scoped to `/aws/lambda/<name>` where the function no longer
> exists. That set was the safe subset by construction: no live function writes to it,
> nothing in Pulumi state references it, and its logs describe torn-down
> infrastructure. **Still outstanding:** the 53 live-function groups and 7 AppSync
> groups, all still `retentionInDays: null`. Those are Option A territory — set a
> retroactive retention rather than deleting groups something is actively writing to.

Setting a retention policy only affects **future** aging; it also applies
retroactively to existing events once set, so the cheapest wipe of accumulated
history is often just **setting a short retention and letting CloudWatch delete
the backlog**. For an immediate hard wipe, delete the log groups outright.

### What is safe to wipe

- **Auto-created Lambda log groups** (`/aws/lambda/<name>`) and the **AppSync log
  group** (`/aws/appsync/apis/<id>`) are *not* in Pulumi state today — nothing
  manages them — so deleting them via the CLI causes **no Pulumi drift**. Lambda
  recreates its group on the next invocation.
- **Once this proposal lands and log groups become Pulumi-managed**, deleting them
  out-of-band *does* cause drift — you'd then reconcile with `pulumi refresh`
  (same caveat as [clearing-aws-eventlog-querydb-tables.md](./clearing-aws-eventlog-querydb-tables.md)).
- CloudWatch log data is operational telemetry, **not** the event-sourcing system
  of record — wiping it never affects domain state or replay. Prefer wiping the
  ephemeral stacks (`alpha`, `beta`, `pr-*`) and leaving prod alone.

> ⚠️ `aws logs describe-log-groups` returns **every** log group in the
> account/region. As with the table-wipe doc, **always filter by stack prefix or
> tag** and dry-run first — an unfiltered delete loop is irreversible.

### Option A — Set retention retroactively (recommended; lets the backlog age out)

Cheapest and lowest-risk: apply the target retention to existing groups and let
CloudWatch expire the backlog. Great for alpha/beta where you just want the
mountain of old logs gone within a day or two.

```bash
REGION="eu-west-1"
PREFIX="/aws/lambda/<your-stack-prefix>"   # e.g. /aws/lambda/online-shop-alpha-
DAYS=7

aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "$PREFIX" \
  --query 'logGroups[].logGroupName' --output text \
  | tr '\t' '\n' | tee /tmp/log-groups.txt      # 1. dry-run: inspect the list

while read lg; do                                # 2. apply retention
  aws logs put-retention-policy --region "$REGION" \
    --log-group-name "$lg" --retention-in-days "$DAYS"
done < /tmp/log-groups.txt
```

### Option B — Delete log groups outright (immediate hard wipe)

```bash
REGION="eu-west-1"
# Prefer tag-based discovery — survives naming changes (mirrors the table-wipe doc)
STACK="<pulumi-stack-name>"
aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --resource-type-filters logs:log-group \
  --tag-filters "Key=pulumi-stack,Values=$STACK" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' | awk -F: '{print $NF}' \
  | tee /tmp/log-groups.txt

# Inspect /tmp/log-groups.txt, then delete in parallel
xargs -P 10 -I {} aws logs delete-log-group --region "$REGION" --log-group-name {} \
  < /tmp/log-groups.txt
```

Note: tag-based discovery only finds groups that carry tags — auto-created
Lambda/AppSync groups are untagged today, so fall back to Option A's
prefix-based discovery for those.

### Option C — Clear a single log group but keep it

```bash
aws logs delete-log-group    --region "$REGION" --log-group-name "$LG"
aws logs create-log-group    --region "$REGION" --log-group-name "$LG"
```

(There is no `TRUNCATE` for a log group; delete + recreate is the equivalent.)

### After a CLI delete of Pulumi-managed groups

Only relevant once log groups are Pulumi-managed (post-proposal):

```bash
pulumi refresh --yes   # sync state with reality (groups marked deleted)
pulumi up --yes        # recreate with the configured retention
```

## Recommendation

0. **First**, fix the managed log group's name to derive from `lambda.name` rather than
   the logical name — see Proposal §3. Everything else in this list is either useless or
   actively misleading until that is done, and it is the change that actually ends orphan
   accumulation.
1. Add `Util_LogRetention.res` (stack → retention tier) beside the existing
   `Util_StoreLayout`/`Util_HostUiDomain` prod-stack machinery.
2. Default `~logRetentionDays` **and** a per-tier `LOG_LEVEL` inside
   `RuntimeEnvironment_Lambda.makeFromCodeAsset`, so **all** Lambdas and the
   AppSync log group inherit environment-appropriate settings; keep explicit
   `commandHandlerConfig` overrides and a Pulumi config key as escape hatches.
3. Prod: `info` + 365-day retention (never = explicit opt-in; cold-archive to S3
   if multi-year is ever required). Beta: `info` + 30d. Alpha/PR: `debug` + 7d/3d.
4. Wipe the existing forever-logs on the ephemeral stacks now via **Option A**
   (retroactive retention) — cheap, no drift, no risk to domain state. Leave prod
   logs in place. *(The orphaned subset is already gone — see the note under
   "Wiping the logs that already exist". The 60 remaining groups still have no
   retention.)*
5. Fix or delete the phantom "7-day default" claim in the Lambda deployment guide
   as part of the same change.
6. Sequence the rollout **ephemeral stack first, from scratch**, and verify the log
   group and its `retentionInDays` actually exist afterwards. Managing the group is a
   create-path change on every already-deployed stack, and it will fail with
   `ResourceAlreadyExistsException` without an adopt/import step — see the migration
   hazard under Proposal §3.

## Motivation, ranked

Since the framing for this work is usually cost, worth keeping the ordering honest —
the measured numbers put savings last:

1. **Bounded retention horizon for anything personal in a log line** — compliance, and
   the expensive one to retrofit later.
2. **Orphan accumulation stops** — 181 groups in ~11 months, and the sweep only treats
   the symptom.
3. **DCB metric filters begin to exist** — currently inert everywhere because they hang
   off the managed log group.
4. **Ingest cost**, addressed by the *level* tiering rather than the retention tiering.
5. **Storage cost** — pennies per month at the measured 2.7 GiB.

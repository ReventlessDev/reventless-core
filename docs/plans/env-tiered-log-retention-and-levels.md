# Plan: Environment-tiered log retention and levels

Source analysis: [../analysis/log-retention-and-levels-per-environment.md](../analysis/log-retention-and-levels-per-environment.md).

**Status: code complete (2026-08-02) — managed groups now default for every
stack. Steps 1–7 done; Step 8 (operational rollout on the live `alpha` stack)
outstanding. Stays in `docs/plans/` until Step 8's on-AWS verification passes.**

## Problem

Every CloudWatch log group in an AWS deployment keeps its logs **forever**.
Lambda and AppSync auto-create their groups with no retention, and the one place
the framework can set retention (`RuntimeEnvironment_Lambda`, guarded by an
optional `~logRetentionDays`) is threaded by only three of ~25 Lambda builders
and never defaulted — so the "7-day default" in the config type is a phantom.
Three consequences:

1. **Orphan accumulation** — because nothing sets `~logRetentionDays`, Pulumi
   never creates the group, Lambda auto-creates it, and `pulumi destroy` never
   deletes it. 181 orphaned groups accrued in ~11 months.
2. **DCB metric filters are inert** — they hang off the managed log group, which
   is never created, so `AppendRetry`/`AppendConflict`/`DcbDecisionModel*` report
   nothing on every stack.
3. **No retention horizon** — unbounded storage and, more importantly, no bounded
   data-retention window for anything personal that reaches a log line.

Retention and level want opposite settings in prod (quiet, long-lived) vs. dev
(loud, short-lived), so a single global setting cannot serve both — the decision
must be environment-tiered.

## Fix

Tier retention and log level by Pulumi stack, reusing the existing
`hostUiProdStacks` prod allow-list, and apply the defaults inside the shared
`makeFromCodeAsset` factory so **all** Lambdas inherit them. Gate the
create-path-changing part (managed log groups) to disposable stacks first,
because making a group Pulumi-managed fails `ResourceAlreadyExists` on any stack
that already has Lambda's auto-created group.

Tiers:

| Tier | Stacks | Retention | `LOG_LEVEL` |
|------|--------|-----------|-------------|
| prod | `prod`, `main` | 365 days | `info` |
| staging | `beta` | 30 days | `info` |
| dev | `alpha`, unlisted | 7 days | `debug` |
| ephemeral | `pr-*` | 3 days | `debug` |

---

## Step 1 — `Util_LogRetention.res` (pure tier functions) ✅

File: `reventless/aws/src/util/Util_LogRetention.res` (new), beside
`Util_StoreLayout` / `Util_HostUiDomain`.

- `retentionDaysFor(~stack, ~prodStacks, ~configOverride=?)` — the tier table
  above; `configOverride` (from the `logRetentionDays` config key, `0` = never)
  wins.
- `logLevelFor(~stack, ~prodStacks, ~configOverride=?)` — `info` for prod/beta,
  `debug` otherwise; `configOverride` (from `logLevel`) wins.
- `managesLogGroup(~stack)` — `true` only for `alpha` and `pr-*`, the disposable
  stacks where the migration off auto-created groups is a delete-then-deploy.

Tests: `reventless/aws/tests/Util_LogRetentionTest.res` (18 cases, mirroring
`Util_StoreLayoutTest`).

## Step 2 — Log-group name fix ✅

File: `reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res`.

`Lambda.Function` has no `name` arg, so the physical name always carries Pulumi's
`-<7hex>` suffix while the group name was built from the logical `name`. Derive
the group name from the function's own output instead:

```rescript
name: lambda.name->Pulumi.Output.apply(n => `/aws/lambda/${n}`)->Pulumi.Output.asInput
```

Prerequisite for everything else — without it, enabling retention creates an
empty group beside the real one, leaves orphan accumulation unchanged, and
collides across stacks sharing an account.

## Step 3 — Default retention + `LOG_LEVEL` in `makeFromCodeAsset` ✅

File: `reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res`.

- Resolve `stack` (`Pulumi.getStackName()`), `prodStacks`
  (`Util_HostUiDomain.resolveProdStacks()`) and `unmanagedStacks`
  (`unmanagedLogGroupStacks` config) once.
- **`LOG_LEVEL`** — defaulted per tier for **every** Lambda when nothing already
  pinned it (caller `envVars` / `additionalEnvVars` win). No migration hazard.
- **Managed log group** — created when the caller pins `~logRetentionDays`
  (existing opt-in) **or** `Util_LogRetention.managesLogGroup(~stack,
  ~unmanagedStacks)` (every stack by default). Retention precedence: explicit arg
  → `logRetentionDays` config key → tier default. The `dcbMetrics` filters ride
  the same managed group, so they now begin to exist on every stack.

## Step 4 — AppSync managed log group ✅

File: `reventless/aws/src/components/Api/AppSync_Adapter.res`.

Managed `Cloudwatch.LogGroup` for `/aws/appsync/apis/<id>` (name derived from the
API id output, tier retention) on every stack by default, honouring the same
`unmanagedLogGroupStacks` escape hatch.

## Step 5 — First-class `logLevel` config field ✅

Files: `reventless/core/src/adapter/Runtime/Runtime.res` (add
`commandHandlerConfig.logLevel?: string`); the three command-handler builders
(`AggregateRuntime_Builder_Single`, `..._Single_Async`,
`StateChangeSliceRuntime_Builder_Single`) map it onto `LOG_LEVEL`, winning over a
generic `envVars` entry and over the tier default.

## Step 6 — Kill the phantom default + docs ✅

- Remove the unused `CommandHandlerDefaults.logRetentionDays = 7` constant
  (`Runtime.res`).
- Correct `packages/doc/docs-infrastructure/lambda-deployment.md` §10; add §11
  documenting the tiers, the overrides, and the create-vs-adopt hazard.

---

## Step 7 — Extend managed groups to all stacks ✅

Files: `reventless/aws/src/util/Util_LogRetention.res`, its two call sites, and
`Util_LogRetentionTest.res`.

`managesLogGroup(~stack, ~unmanagedStacks=[])` now returns `true` for **every**
stack rather than only `alpha`/`pr-*`. Rationale: a stack deployed on this
framework gets its groups from Pulumi on the first `up`, before Lambda/AppSync
auto-create them, so a **fresh** stack has nothing to adopt and no
`ResourceAlreadyExists` hazard. Every current stack is `alpha` and there is no
prod stack to migrate, so this costs nothing today.

The only case still needing care is *adopting* a stack that predates managed
groups. Rather than build import tooling for a stack that doesn't exist, the
seam is a config escape hatch: **`unmanagedLogGroupStacks`** (CSV, parsed by
`Util_LogRetention.parseUnmanagedStacks`) lists stacks kept on auto-created
groups until a `pulumi import` is done. Empty today. Turning a future prod
adoption into a config flip rather than a code edit is the whole "prepared for
the future" requirement.

## Step 8 — Operational rollout on `alpha` ⬜ (not code)

`alpha` is the only live stack, and it already has Lambda's auto-created groups,
so its first managed deploy is a delete-then-deploy — the disposable-stack path,
no import needed.

1. **Delete `alpha`'s existing auto-created groups**, then deploy — so the
   managed `CreateLogGroup` does not hit `ResourceAlreadyExists`. `alpha`'s logs
   are disposable, so this is the simple path.
2. **Verify the managed group + its `retentionInDays` actually exist** after the
   deploy — not merely that it went green (the create-vs-adopt asymmetry can hide
   a group that was silently never created).
3. **Wipe any remaining forever-logs** via Option A (retroactive
   `put-retention-policy`) for groups a redeploy doesn't replace.

Needs AWS account access + touches deploy state → operator-driven; commands can
be prepped but not run without an explicit ask.

## Verification

- `pnpm run build` in `reventless/core` and `reventless/aws` — clean, zero
  warnings.
- `Util_LogRetentionTest` (24), `Util_StoreLayoutTest`, `ComponentRuntimeDefaultsTest`,
  `AppSync_AdapterTest` — all green.
- On-AWS verification of the managed group + retention is deferred to Step 8's
  `alpha` rollout.

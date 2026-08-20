# Plan: Environment-tiered log retention and levels

Source analysis: [../analysis/log-retention-and-levels-per-environment.md](../analysis/log-retention-and-levels-per-environment.md).

**Status: code complete (2026-08-02) — Steps 1–7 + Step 9 (bespoke-builder
coverage gap) done and committed. **Step 8** (the alpha managed-group cutover)
is outstanding and is no longer "low value, deferred".**

**Re-measured on alpha 2026-08-20** (see Step 8 § Field state): the escape hatch
is still set while adoption is partial, so **48 of 83 Lambdas — 43 of them
redeployed the day before — still write to auto-created groups, and 27 groups
carry no retention at all**, the largest at 249 MB and still growing. The Option A
interim sweep was never re-run, exactly as its own caveat warned.

The deferral rested on the cutover needing a risky local `pulumi up` to beat a
recreate race. That race was removed on 2026-08-08 by
[log-group-ownership-without-a-race.md](log-group-ownership-without-a-race.md),
so the cutover is now "delete two env-var lines and let CI deploy". Step 8 is
rewritten accordingly and carries the ordered remaining work.

Stays in `docs/plans/` until that work lands and the verification passes.

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

## Step 8 — Operational rollout on `alpha` ◑ (not code)

`alpha` is the only live stack. Field finding (2026-08-02): it is a **running**
deployment whose scheduled heartbeats recreate a deleted log group within
minutes, and the CI deploy lags ~15 min — so a plain delete-then-deploy loses the
race (the managed `CreateLogGroup` still hits a recreated group). The 2026-08-02
cleanup deleted all existing alpha groups (41 real deletes; orphan groups gone,
confirmed); only the ~8 live/heartbeat groups reappear.

Chosen path — **decouple landing the code from cutting alpha over**:

1. ✅ **Escape hatch in CI** — `REVENTLESS_UNMANAGED_LOG_GROUP_STACKS: alpha` set
   in both `env:` blocks of `deploy-reventless-aws.yml`. Alpha deploys keep
   Lambda/AppSync auto-created groups (status quo), so CI stays green; alpha does
   not yet get tiered retention. `LOG_LEVEL` tiering still applies (env var only).
2. ⬜ **Deliberate cutover** — ~~remove the escape-hatch var, then run a **local
   `pulumi up`** immediately after deleting alpha's groups
   (`scratchpad/migrate-alpha-log-groups.sh APPLY=1`), so the managed creates land
   seconds later and beat the ~minute heartbeat window; re-delete + up for any
   group that races.~~ **Rewritten 2026-08-20 — the procedure is obsolete.**
   [log-group-ownership-without-a-race.md](log-group-ownership-without-a-race.md)
   (implemented 2026-08-08) removed the race this dance existed to beat: the group
   is now named by us, created **before** the function, and the function is pointed
   at it with `loggingConfig`, so there is no window for an invocation to take the
   name first. The cutover is therefore just **remove the escape-hatch var and let
   CI deploy** — no local `pulumi up`, no delete-then-race, no re-delete loop.

   **Both `env:` blocks were cleared 2026-08-20**; the var no longer appears in
   `deploy-reventless-aws.yml`. It takes effect on the next deploy, which is when
   the 43 get their managed groups — so item 3's verification is the thing that
   closes this, not the edit.
3. ⬜ **Verify** the managed group + its `retentionInDays` actually exist after
   the cutover — not merely that it went green.

Needs AWS account access + touches deploy state → operator-driven.

### Field state, measured 2026-08-20

The hatch is **still set** and adoption is **partial**, which is the one
combination `log-group-ownership-without-a-race.md` §6 says must not happen
("`unmanagedLogGroupStacks` still works for a stack that has adopted nothing, and
its documentation states that it must not be set once adoption is partial"). On
alpha:

| | count |
| --- | --- |
| Lambda functions | 83 |
| → `loggingConfig` points at a managed `<project>-<stack>-<name>` group | 35 |
| → still writing to the auto-created `/aws/lambda/<fn>-<hash>` group | **48** |
| CloudWatch groups under `/aws/lambda/` | 83 |
| → managed name, retention set | 35 / 35 |
| → auto-created, **no retention at all** | **27** |

**43 of the 48 unmanaged functions were last modified 2026-08-19** — yesterday's
deploy — so this is not drift from an old rollout. Every deploy reproduces it,
because the hatch makes `managesLogGroup` false and only the callers that pin
`~logRetentionDays` (the `retentionDaysOverride` branch, which applies even on an
unmanaged stack) get a group. That branch is why 35 groups are managed *despite*
the hatch.

The Option A caveat below came true: the sweep was never re-run, so the groups
created since drifted back to unbounded. The largest is
`/aws/lambda/CustomerPluginHeartbeat-64ae7e2` at **249 MB**, still receiving
events, with no retention.

**Five functions were leaked, not merely unmanaged** — last modified
**2025-08-28 / 2025-08-13**: `CustomerPluginHeartbeat-64ae7e2` (still invoking
daily a year on), `CustomerPluginEventColl-defdfab`,
`ProfilePictureTaskBucket-d2d3691`, `ProfilePictureTaskEventColl-c24b540`,
`CoreEventColl-84d2516`.

They were **not orphans**: they belonged to two intact Pulumi stacks,
`reventless/customer/dev` (144 resources) and `reventless/core/dev` (79). Deleting
the functions directly would have drifted those stacks, so the right remedy was
`pulumi destroy` on both — **done 2026-08-20**. Both stacks are gone, the five
functions with them (83 → 78 Lambdas), and all ten `alpha` stacks are untouched.

**One trap worth recording**, found while previewing that destroy:
`customer/dev` **owned the Cognito user pool `eu-west-1_CQTwafSeX`** — the
account's only pool, and the one live `alpha` authenticates against, with
`DeletionProtection: INACTIVE`. A destroy run without checking would have deleted
every user account. Preview the resource list before destroying any long-abandoned
stack; ownership drifts to whatever created a shared resource first.

### Remaining work, in order

1. **Remove the escape-hatch var** from both `env:` blocks and let CI deploy —
   step 2 above, in its rewritten form. Converts the 43 in one pass. Check first
   that no alarm or saved query is keyed to the old `/aws/lambda/<fn>-<hash>`
   names; the DCB metric filters, which need a managed group, start working as a
   side effect.
2. **Sweep the auto-created leftovers** once (1) has landed and nothing writes to
   them — required by `log-group-ownership-without-a-race.md` §6 and never run.
   Worth a committed script rather than a `scratchpad/` one, since it is now a
   recurring operation. **Partly done 2026-08-20:** the 9 groups whose function no
   longer exists were deleted (249.3 MB, almost all of it
   `CustomerPluginHeartbeat-64ae7e2` at 249.2 MB). The rest wait on (1), since
   their functions are still writing to them.
3. ✅ **Delete the five leaked functions**, their schedules and their groups —
   **done 2026-08-20** via `pulumi destroy` on the two stacks that owned them,
   plus the log-group sweep in (2). Log groups are not Pulumi-owned, so `destroy`
   left them behind and they had to be deleted separately.
4. **The `DeadLetterQueue` managed group** — Step 9's deferred item, confirmed
   unbounded across 7 functions.
5. **A drift guard.** This was invisible for 18 days and survived a deploy that
   touched 43 functions. A post-deploy check counting functions with no
   `loggingConfig` would have caught it the same day.

**Interim retention applied (Option A, 2026-08-02).** Rather than run the risky
cutover now, alpha's existing groups got a *retroactive* retention policy — no
Pulumi, no deploy, reversible (`scratchpad/set-alpha-retention.sh`, dry-run first).
`aws logs put-retention-policy --retention-in-days 7` was set on all **21** existing
alpha Lambda log groups (verified `retentionInDays: 7`); the other ~9 live functions
had not yet been invoked so had no group to set, and no AppSync group exists yet
(lazy creation). So alpha now has bounded 7-day retention on the logs that exist,
while the full managed-group cutover (steps 2–3 above) stays deferred. Caveats
inherent to Option A: the groups stay **unmanaged** (no Pulumi ownership, no DCB
metric filters), and a future deploy that changes a Lambda's name suffix — or a
first invocation / first AppSync field-log — creates a fresh no-retention group, so
re-running the sweep periodically is needed until the managed cutover lands.

## Step 9 — Close the bespoke-builder coverage gap ◑

Post-deploy verification (2026-08-02) found the tier policy only reached the ~22
Lambdas built via `makeFromCodeAsset`. **8 platform/service Lambdas** are built by
bespoke `Lambda.Function.make` call sites and so had `LOG_LEVEL=None` (logger
default) and no managed group: `DeadLetterQueue`, `DomainEventsApiStateTopicPublisher`,
`GeocoderService`, `UploadServiceLambda`, `PlatformUIDefinitionsLambda`,
`PlatformUIFragmentsLambda`. Not a regression, but contradicts the "all ~25
Lambdas" goal — and matters more for retention: those groups would stay unmanaged
and forever-retained even after the Step 8 cutover.

Fix — a shared helper so the policy lives in one place:

- ✅ **`Util_LambdaLogging.res`** (new) — `logLevelEntry()` / `applyLogLevelDefault`
  (the tier `LOG_LEVEL`) and `makeManagedLogGroup` (tier-retention group, name from
  the function's physical `lambda.name`, gated by `managesLogGroup`, parented via
  the caller's `~opts`). `makeFromCodeAsset` now applies `LOG_LEVEL` through it too.
- ✅ **`LOG_LEVEL` on all 7 bespoke builders** — one `logLevelEntry()` entry each
  (`Util_DeadLetterQueue`, `StateTopic_AppSync`, `Geocoder_AwsLocation`,
  `Upload_{Presign,Claim}_S3`, `Platform_{UIFragments,ComponentDefinitions}_Lambda`).
- ✅ **Managed groups on the 6 non-DLQ bespoke builders** — inert on `alpha` today
  (escape hatch), so they complete the cutover without changing current behavior.
- ⬜ **`DeadLetterQueue` managed group deferred** — its module provisions at import
  time (races Jest teardown; flagged fragile), so only `LOG_LEVEL` was added there.
  Fold its managed group into the Step 8 cutover. **Confirmed in the field
  2026-08-20:** all **7** `DeadLetterQueue-*` functions on alpha write to
  auto-created groups, three of them with no retention and receiving events the
  same day. Because the module's resources are created inside an import-time
  `apply`, the group has to be created *within* that apply rather than hoisted out
  of it.

Verified: `pnpm run build` clean/zero-warnings; 183 tests green across the affected
suites; on-AWS, the ~22 `makeFromCodeAsset` Lambdas already carry `LOG_LEVEL=debug`
on alpha (the 8 bespoke ones flip on the next deploy).

## Verification

- `pnpm run build` in `reventless/core` and `reventless/aws` — clean, zero
  warnings.
- `Util_LogRetentionTest` (24), `Util_StoreLayoutTest`, `ComponentRuntimeDefaultsTest`,
  `AppSync_AdapterTest` — all green.
- On-AWS verification of the managed group + retention is deferred to Step 8's
  `alpha` rollout.
- **Measured on alpha 2026-08-20** — see Step 8 § Field state. Where a managed
  group exists it is correct (35 / 35 carry retention), so the mechanism is
  sound; the gap is that the escape hatch keeps 48 of 83 functions off it. Re-run
  with:

  ```bash
  aws lambda list-functions --region eu-west-1 \
    --query 'Functions[].[FunctionName,LoggingConfig.LogGroup]' --output text \
    | awk -F'\t' '{ if ($2 ~ /^\/aws\/lambda\/online-shop/) m++; else u++ } END { print "managed", m, "| unmanaged", u }'

  aws logs describe-log-groups --region eu-west-1 \
    --query 'logGroups[?starts_with(logGroupName,`/aws/lambda/`)].[logGroupName,retentionInDays,storedBytes]' \
    --output text | awk -F'\t' '$2=="None"{ n++; b+=$3 } END { print n, "groups with no retention,", b/1e6, "MB" }'
  ```

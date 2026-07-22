# Plan: Stop EventBridge Schedule Rules Accumulating (and sweep the backlog)

**Status** (2026-07-22): **filed done — all five steps are done in the tree.**
1 (name symmetry), 2 (test), 3 (the sweep — executed on alpha),
4 (observability), 5 (stop the prefix rotating with the Lambda hash).

**One check is deliberately outstanding: the fix is not yet deployed, so the
leak is not yet observed closed on alpha.** The live layer runs core
`3.0.0-alpha.177`, which still has the asymmetric delete; the step-5 entry points
ship in `reventless-aws`. Both land on the next alpha release + deploy. Until
then the count keeps climbing, and the first deploy after cutover orphans
whatever rules are outstanding at that moment (one-time, ≤ ~10 rules).

**After the next alpha deploy**, run
`node scripts/eventbridge-rules.mjs --region eu-west-1`:

1. New rules should read `alpha-<pluginId>` — the signal the new bundle is live.
2. Sweep once more (`--sweep`) to clear the cutover orphans.
3. A connect/disconnect cycle should then leave the total unchanged. That is the
   last unticked box in Validation below.

The create/delete asymmetry is confirmed as the leak; the earlier "it does not
explain the rules" reading rested on a wrong assumption about `Spec.environment`
(see below).

**Discovered**: 2026-07-22, while confirming that the CommandTopic queue policy's
EventBridge grant is load-bearing — see
[`../commandtopic-queue-policy-eventbridge-source-conditions.md`](../commandtopic-queue-policy-eventbridge-source-conditions.md).

## Problem

The alpha AWS account carries **234 EventBridge rules**, of which **228 are
one-shot fixed-date crons whose fire date has already passed**. They span at
least three stacks (`alpha`, `dev`, `rescript11`) and three naming generations,
going back to `..._1.0.0-alpha.41`:

| Name shape | Count (approx) | Origin |
|---|---|---|
| `CorePluginExtPointCmdHandler-<hash>-<Plugin>_<version>` | ~172 | older handler-named generation |
| `CorePluginExtPointCmdTopic-<hash>-<Plugin>_<version>` | ~50 | older topic-named generation |
| `<stack>-<pluginId>` (`alpha-…`, `dev-…`, `rescript11-…`) | ~8 | current generation |

Nothing deletes them. Each is `ENABLED` and permanently retained.

**This is heading for a hard limit, not just untidiness.** EventBridge's default
quota is 300 rules per event bus per region; 234 is ~78% of it. Once the bus is
full, `PutRule` fails and *new* schedules stop being created — which breaks the
plugin disconnect mechanism silently, since `ScheduleOps.create` logs and throws
`ScheduleNotCreated` on a background path rather than failing a user request.

## Root cause: create and delete disagree on the rule name

[`PluginExtensionPoint_Plugin.res:105-116`](../../../reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res#L105-L116)
creates the disconnect schedule with the stack prefixed:

```rescript
| PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout) =>
  await createSchedule({
    name: Spec.environment ++ ("-" ++ id),   // "alpha-Catalog_1.0.0-alpha.169"
    ...
  })
| DeleteDisconnectSchedule(id) => await deleteSchedule(id)   // "Catalog_1.0.0-alpha.169"
```

and deletes it *without* the prefix. [`ScheduleOps.delete`](../../../reventless/core/src/util/ScheduleOps.res#L100-L123)
only runs `resourceNaming.validateName` over the name it is handed — it does not
re-apply the environment prefix, and `validateName` merely substitutes invalid
characters. So the delete targets a rule name that was never created, the real
rule survives, and every disconnect leaks one rule.

### …and `Spec.environment` is the Lambda function name, not the stack

**Open question RESOLVED 2026-07-22**, by downloading the deployed artifacts. An
earlier revision of this plan claimed the asymmetry did not explain the rules,
because `Spec.environment` was assumed to be the stack name (the EP Lambda's
`Environment` env var reads `alpha`). That assumption was wrong.

[`PluginExtensionPointEntryPoint.mjs:40-43`](../../../reventless/aws/src/adapter/Runtime/PluginExtensionPointEntryPoint.mjs#L40-L43)
— hand-written, still current in this tree — binds the field from the *function
name*, ignoring the `Environment` variable entirely:

```js
const lambdaFunctionName = process.env["AWS_LAMBDA_FUNCTION_NAME"] || "unknown";
const pluginModule = pluginEPPluginMake({ runtimeOps, environment: lambdaFunctionName, ... });
```

So `<Spec.environment>-<pluginId>` renders as
`PlatformPluginExtPointCmdHandler-8fde2e1-Catalog_1.0.0-alpha.151` — exactly the
observed shape. Confirmed against the deployed bundle: layer
`reventless-aws-alpha:207` carries core `3.0.0-alpha.177`, whose
`PluginExtensionPoint_Plugin.res.mjs` has `name: Spec.environment + ("-" + id)`
on create and a bare `deleteSchedule(directive._0)` on delete. **The asymmetry
is the leak, and the step-1 fix does address it.**

### Second leak vector: the prefix rotates with the Lambda hash

Not closed by the step-1 fix, and still live. Because the prefix is the EP
Lambda's function name — which carries a content hash — replacing that Lambda
changes the prefix. Rules created by the previous generation are then
unreachable: the new Lambda's delete computes a name the old rules do not have,
exactly the failure the symmetry fix was meant to remove, reintroduced across a
deploy boundary.

The swept backlog is the fingerprint of this, one cohort per EP-Lambda
generation:

| Generation | Orphaned rules |
|---|---|
| `CorePluginExtPointCmdHandler-f7ea764` | 107 |
| `CorePluginExtPointCmdTopic-7afca37` | 47 |
| `CorePluginExtPointCmdHandler-6579cb3` | 30 |
| `CorePluginExtPointCmdHandler-cec3b2d` | 20 |
| `CorePluginExtPointCmdHandler-b56cb78` | 9 |
| `CorePluginExtPointCmdTopic-79579b1` | 3 |
| `Customer_*` / `dev-` / `rescript11-` residue | 4 |

Two generations were live simultaneously on the day of the sweep (`8fde2e1` and
`bd85655`, each with its own `Catalog_1.0.0-alpha.151` rule), which is the same
mechanism caught in the act.

Fixing this means the prefix must be **stable across deploys and unique per
stack** — the `Environment` variable (`alpha`) is already both, and is already on
the Lambda; the entry point simply does not read it. Note the comment now at
[`PluginExtensionPoint_Plugin.res:35-37`](../../../reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res#L35-L37)
calls this "the stack prefix", which is what it *should* be but is not yet.
Changing the binding orphans every outstanding rule once, at cutover.

## Goals

- A disconnect schedule created by the plugin extension point can actually be
  deleted by the code that is supposed to delete it.
- The account is swept back to a small working set, well clear of the quota.
- Rule count is observable, so the next leak is noticed before it hits 300.

## Non-goals

- Migrating `ScheduledPublisher` to EventBridge Scheduler. Tracked separately in
  [`aws-adapters-critical-fixes.md`](../Backlog/aws-adapters-critical-fixes.md); this plan
  is about lifecycle, not about which service is used.
- Renaming rules to retire the stale `Core*` vocabulary. Those rules are
  runtime-created residue and will be deleted by the sweep, not renamed.
- Raising the quota. Fix the leak first — a higher ceiling just defers the same
  failure.

## Approach

**1 — Make the name symmetric.** Preferred fix: give the schedule name a single
owner instead of prefixing at one call site and not the other. Either

- have `ScheduleOps.create`/`delete` both apply the environment prefix (the name
  becomes an internal detail the caller never spells), or
- have `PluginExtensionPoint_Plugin` pass the same prefixed string to both.

The first is better — it makes the asymmetry unrepresentable rather than
correct-by-convention. Check for other `createSchedule` callers before changing
the shared helper: `SideEffectHandler_Builder` and `Task_Builder` also construct
schedules and must not gain a double prefix.

**2 — Cover it with a test.** A round-trip over a fake scheduler (create then
delete the same logical id, assert the adapter saw one `PutRule` and one
`DeleteRule` with *identical* names) fails today and passes after the fix.
`reventless/core/tests/extensionpoint/ExtensionPointFixtures.res` already stubs
`deleteSchedule`, so the seam exists.

**3 — Sweep the backlog.** Delete rules whose one-shot cron date has passed.
`RemoveTargets` must precede `DeleteRule`. Scope carefully — the account hosts
several stacks, and the heartbeat rules (`*PluginHeartbeat-*`, `rate(...)` not
`cron(...)`) are live and must survive. Dry-run the selection and eyeball the
list before deleting anything.

Dry run as of 2026-07-22 (234 rules total), classifying by schedule expression:

| Class | Count | Disposition |
|---|---|---|
| `cron(...)` one-shot, fire date past | 220 | delete |
| `cron(...)` one-shot, fire date today or ahead | 8 | **keep** — live disconnect schedules |
| `rate(5 minutes)` | 6 | **keep** — plugin heartbeats, all `*PluginHeartbeat-*` |

The date comparison is deliberately day-granular, so a rule scheduled earlier
*today* is classified keep-side. That errs toward retention; those few get swept
on the next pass.

**Executed 2026-07-22.** The predicate above ran against the live account and
matched the dry run exactly: **220 rules deleted, 0 errors, 14 remaining** — the
6 `rate(5 minutes)` heartbeats plus the 8 same-day disconnect schedules. Each
deletion did `ListTargetsByRule` → `RemoveTargets` → `DeleteRule`; the account
carries only the `default` event bus and no `ManagedBy` rules, so nothing was
provider-owned. Rule count is back to ~5% of the 300/bus quota. The oldest thing
removed dated to 2024-07-01 (`Customer_0.1.0-alpha.2-04427d7`); the `Customer_*`,
`dev-Customer_*` and `rescript11-Customer_*` residue from retired stacks went
with it.

**4 — Make the count visible.** A rule count is a cheap CloudWatch alarm or a
line in whatever deploy summary already exists. Without it the next leak is
found the same way this one was: by accident.

**Done.** [`scripts/eventbridge-rules.mjs`](../../../scripts/eventbridge-rules.mjs)
classifies the account's rules and, with `--sweep`, deletes the stale ones —
the same predicate used for the step-3 sweep, now a reviewable script instead of
an ad-hoc console session. EventBridge publishes no rule-count metric, so an
alarm would have meant a scheduled Lambda polling `ListRules` — a rule, to count
rules. The deploy workflow reports instead: a "Report EventBridge rule count"
step on the *platform* job (rules are account-wide; the plugin matrix would
repeat it N times), writing a markdown table to the job summary. It is
`continue-on-error` on purpose — a deploy must not fail over rule count. Run
locally the same way:

```bash
node scripts/eventbridge-rules.mjs --region eu-west-1            # report
node scripts/eventbridge-rules.mjs --region eu-west-1 --sweep    # delete stale
```

**5 — Stop the prefix rotating with the Lambda hash.** Bind `environment` from
the `Environment` variable the Lambda already carries (`alpha`) rather than from
`AWS_LAMBDA_FUNCTION_NAME`. Steps 1 and 5 are both needed: step 1 fixes the
within-generation leak, step 5 the across-deploy one.

**Done**, in both hand-written entry points —
[`PluginExtensionPointEntryPoint.mjs`](../../../reventless/aws/src/adapter/Runtime/PluginExtensionPointEntryPoint.mjs)
and
[`EventCollectorEntryPoint.mjs`](../../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint.mjs).
They instantiate the *same* admin Plugin EP module, so they had to change
together: with different function names as prefixes, a rule created by one was
undeletable by the other — a third manifestation of the same bug, independent of
the redeploy vector.

The audit the change required, for the record:

- `Spec.environment` on the plugin EP spec
  ([`PluginExtensionPoint_Plugin.res:18`](../../../reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res#L18))
  has exactly **one** consumer: `disconnectScheduleName` at line 37. Nothing else
  observes the field, so redefining it is contained.
- Deploy-time code already treats `environment` as the stack name —
  [`Plugin_Helpers.res:1747`](../../../reventless/core/src/plugin/component/Plugin_Helpers.res#L1747)
  and [`Platform.res:1414`](../../../reventless/aws/src/Platform.res#L1414) both
  set it from `Pulumi.getStackName()`. The runtime entry points were the sole
  divergence; this makes runtime agree with deploy-time rather than inventing a
  convention.
- [`RuntimeEnvironment_Lambda.res:203`](../../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L203)
  sets `Environment` = stack name on every Lambda. Verified live: all six EP
  handlers and the event-collector Lambdas carry it, and it is correctly
  per-stack (`alpha` vs `dev`).

## Validation

- ✅ Create-then-delete round trip uses one name —
  `PluginDisconnectScheduleTest` asserts `PutRule` and `DeleteRule` see identical
  strings. Full core suite green (520 tests) after the step-5 change.
- ✅ Post-sweep rule count is back to the live working set — 14 rules, all
  accounted for (6 heartbeats, 8 pending disconnect schedules). Reproducible:
  `node scripts/eventbridge-rules.mjs --region eu-west-1`.
- ⏳ A plugin connect/disconnect cycle on alpha leaves the rule count unchanged.
  **Pending deploy** — this is the check that shows the leak is actually closed,
  and it cannot run until steps 1 and 5 reach the account. After the next alpha
  deploy, re-run the report script: new rules should be named
  `alpha-<pluginId>`, and the total should stay flat across a connect/disconnect
  cycle. Any new `*PluginExtPointCmdHandler-<hash>-<Plugin>_<version>` means the
  old bundle is still live.

## Risk

The sweep is destructive and touches shared infrastructure across several
stacks. The selection predicate — past-dated one-shot crons only, never
`rate(...)` heartbeats — is the whole safety story, so it is worth being
paranoid about the dry run. The code fix itself is small and its blast radius is
the disconnect path; step 2's test is what keeps it honest.

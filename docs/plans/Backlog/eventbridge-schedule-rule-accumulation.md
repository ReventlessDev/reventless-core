# Plan: Stop EventBridge Schedule Rules Accumulating (and sweep the backlog)

**Status** (2026-07-22): step 1 (name symmetry) and step 2 (test) are **done**.
Step 3 (the sweep) is **not started** — it is destructive and needs the open
question below answered first. Step 4 (observability) is not started.

The create/delete asymmetry was found and fixed, but checking the account showed
it does **not** account for the accumulated rules — no rule matches the shape
the current code produces. See "…but it does not explain the accumulated rules".

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

### …but it does not explain the accumulated rules

**Corrected 2026-07-22 after checking the account.** The asymmetry above is real
and is now fixed (see Status), but it is *not* demonstrated to be the cause of
the 234 rules. The evidence contradicts it:

- The current source names a disconnect schedule `<Spec.environment>-<pluginId>`,
  and `Spec.environment` on the deployed EP Lambda is confirmed to be the stack
  name — `PlatformPluginExtPointCmdHandler-8fde2e1`'s `Environment` variable
  reads `alpha`.
- Yet **zero** rules on the account have the `alpha-<pluginId>` shape. Every
  disconnect-schedule rule instead looks like `<handlerName>-<pluginId>`, e.g.
  `PlatformPluginExtPointCmdHandler-8fde2e1-Catalog_1.0.0-alpha.151` — including
  ones created on the day of this investigation.
- That rule's target is `PlatformPluginExtPointCmdTopic-576b6f7`, so the name
  carries the *handler* while the target is the *topic*: the name is built from
  something other than `Spec.environment`.

Reading `ExtensionPoint_Callback`, `ExtensionPointMapping` and `ScheduleOps`
turned up no path that produces that shape — `ScheduleOps.create` only applies
`validateName`. So either the deployed Lambdas run superseded logic bundled from
an earlier published core version, or there is a naming path not yet found.

**This is the open question, and it should be answered before the sweep.** The
practical consequence cuts both ways: it means none of the 220 stale rules were
produced by the code path just fixed (so the fix alone will not stop the
accumulation), but also that all 220 come from superseded paths and are
correspondingly safe to remove.

The two older families (`CorePluginExtPointCmdHandler-*`,
`CorePluginExtPointCmdTopic-*`) predate the current naming and are residue from
deploys that had no working cleanup at all — consistent with the
previously-fixed inert plugin retire hook.

## Goals

- A disconnect schedule created by the plugin extension point can actually be
  deleted by the code that is supposed to delete it.
- The account is swept back to a small working set, well clear of the quota.
- Rule count is observable, so the next leak is noticed before it hits 300.

## Non-goals

- Migrating `ScheduledPublisher` to EventBridge Scheduler. Tracked separately in
  [`aws-adapters-critical-fixes.md`](aws-adapters-critical-fixes.md); this plan
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

**4 — Make the count visible.** A rule count is a cheap CloudWatch alarm or a
line in whatever deploy summary already exists. Without it the next leak is
found the same way this one was: by accident.

## Validation

- Create-then-delete round trip removes the rule from AWS (not just logs a
  success).
- Post-sweep rule count is back to the live working set (heartbeats plus any
  genuinely pending disconnect schedules).
- A plugin connect/disconnect cycle on alpha leaves the rule count unchanged.

## Risk

The sweep is destructive and touches shared infrastructure across several
stacks. The selection predicate — past-dated one-shot crons only, never
`rate(...)` heartbeats — is the whole safety story, so it is worth being
paranoid about the dry run. The code fix itself is small and its blast radius is
the disconnect path; step 2's test is what keeps it honest.

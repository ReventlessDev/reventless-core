# Plan: a seam that announces every execution unit, and nothing listening

**Date:** 2026-09-05
**Status:** **§1 implemented 2026-09-07** (the announcement is buffered until a backend registers).
§2 proposed. Found while tracing a dead-letter loop back to its cause and discovering that nothing
had reported the incident at any point in its 12-hour life.
**Repos:** `reventless-core` only.

> **Corrected 2026-09-07.** The first draft said no backend is registered anywhere and built its
> argument on that. Reading the estate says otherwise: **28 alarms exist**, 26 of them created
> through this seam by a deploy program outside this repo, covering command handlers, event
> collectors, projections, reactors, schedulers, tasks and query interceptors. The seam works and is
> in production use. What is true is narrower, and in two parts — §1, the one unit kind a registered
> backend cannot see; and §2, the stacks this repo deploys itself, which register nothing.

**Goal.** A stack deployed from this repo tells someone when one of its execution units stops
working, rather than being found later in a bill.

**Non-goal.** Making monitoring a framework concern. `Monitoring` is deliberately a seam — core says
*"I provisioned an execution unit of this kind"* and leaves what to do about it to a registered
backend, and [done/monitoring-hook-seam.md](done/monitoring-hook-seam.md) argues that at length. That
decision is right and this plan does not revisit it. The gap is not that core declines to alarm; it
is that **nothing in this repo ever registers a backend**, so on every stack this repo deploys the
seam's default is the one that does nothing.

---

## §1 — the announcement that arrives before anyone is listening

**Status: implemented.** `Monitoring.notify` buffers announcements made before `use` and replays them
to the first backend registered; `Monitoring.reset` restores the initial state for tests.

Of the 28 alarms on the estate, **not one covers a dead-letter sink** — on any stack, including the
ones where a backend is registered and alarming twenty-six other units. That is not the backend
declining the kind: it maps `DeadLetterSink` to `Invocations` deliberately, because on that unit an
invocation *is* the incident. It never got the chance to use the mapping.

[Util_DeadLetterQueue.res](../../reventless/aws/src/util/Util_DeadLetterQueue.res) calls `notify` as a
**top-level statement**. Every other unit announces itself from inside a function
([RuntimeEnvironment_Lambda.res:363](../../reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res#L363))
that runs during the platform build. Under ESM an imported module is evaluated to completion before
the importing module's body begins — so this one fires before the deploy program's *first statement*,
which is necessarily before its `use` call. The seam's own contract ("must run before the
platform/plugin build") is satisfied by the deploy program and still too late.

So the dead-letter sink was structurally unmonitorable: the one unit whose announcement was always
made to an empty room, and the one whose whole purpose is to be noticed.

**The fix is in the seam, not the call site.** Holding an announcement until someone registers costs
one array and fixes the class — any provisioning site that runs at import time, not just this one —
without moving resource creation out of module scope, which has bitten this file before. A backend
sees the same units in the same order; only the moment it hears about the early ones moves.

The owner is captured at `notify` rather than at delivery: a replayed announcement is delivered from
the deploy program's body, where the ambient `ResourceAttribution` is whatever the *next* construct
left behind, and a dead letter sink attributed to whichever plugin happened to build last would be
worse than one attributed to nobody.

## §2 — the stacks this repo deploys itself

**Status: proposed.** `Monitoring.use` is never called anywhere in `reventless-core` — the matches in
the source tree are a doc comment, a comparison in an unrelated seam, and the definition itself. The
26 alarms belong to stacks deployed from elsewhere; `online-shop-hybrid-platform-aws-alpha`, the
stack CI deploys from this repo on every push to `alpha` and the one that wedged, is covered by none
of them. Its only alarms would be the upload claimer's `IteratorAge`
([Upload_Claim_S3.res:347](../../reventless/aws/src/adapter/Upload/Upload_Claim_S3.res#L347)), which
was written for a specific data-loss risk and is not part of any general posture.

So for the estate this repo owns, the consequence is still exact: **no command handler, projection,
reactor, event collector, task, scheduler or dead-letter sink is alarmed on anything.**

## What it cost, in the incident that exposed it

On 2026-09-04 the platform `Plugin` aggregate on the alpha estate stopped being able to replay its
own event log — a wire-format change left already-stored events undecodable, so replay raised before
`decide` and *every* command to that aggregate failed. That includes the heartbeat each plugin sends
to stay `Connected`, so the estate was in a state where plugins could not register and the failure
renewed itself on every heartbeat interval.

What did **not** happen, in order:

1. No alarm on the command handler's `Errors`, which were continuous.
2. No alarm when messages began arriving on the dead-letter queue — the queue whose entire purpose is
   to be empty in normal operation.
3. No alarm on the dead-letter handler's own invocations, which by design fails on every one — and on
   *no* stack in the estate, monitored or not, for §1's reason.
4. The cause was fixed the same evening by an unrelated migration step. Seven stranded messages kept
   cycling for **twelve hours past the fix**, and nothing said so.

The alarm history is empty for the whole window: no state change on any of the 28 alarms between
18:00Z and 02:00Z. It was found instead by attributing a CloudWatch bill to log groups.

One trap for whoever builds §2, learned from this incident: **do not alarm a dead-letter queue on
depth.** A consumer that keeps failing keeps its messages *in flight*, so the queue read
`0 visible, 7 not visible` throughout — `ApproximateNumberOfMessagesVisible` never left zero.
`Invocations` on the handler is the metric that matches this topology, which is what the seam's
`DeadLetterSink` kind exists to let a backend choose.

This is worth separating from the two defects in
[bounded-log-lines.md](bounded-log-lines.md). Those were about the size of what gets written when
something goes wrong. This is about whether anyone finds out. Bounding the lines would have made that
incident 400× cheaper and equally silent.

## Why it is this repo's problem

The seam is designed for an out-of-repo extension to consume, and consuming it is not hard — a
backend is one `onProvisioned` function creating one provider-native alarm resource per unit. But
this repo deploys stacks of its own: CI deploys the hybrid example on every push to `alpha`, and
those stacks are precisely where framework defects surface first, because they run continuously and
unattended. A framework whose own reference estate cannot report its own failures is not in a
position to have an opinion about anyone else's.

There is a second-order cost. Every defect found on that estate is found *late* and *by accident* —
which biases the whole backlog toward things a bill makes visible (log volume, invocation count) and
away from things only an alarm makes visible (a wedged aggregate, a projection that stopped, a task
that has not run since Tuesday). Two of this repo's open plans were opened from bill evidence.

## Decided: an alert does not travel through the system it is about

Asked while §2 was being scoped: should alarm notification reuse the Notification trait, so
operational alerts reach admins through the channel the domain already has? **No — not for
delivery.** Recorded here because it will be asked again, and because the reasoning constrains what
step 1 may do.

The trait is an `OutboundTranslationSlice` on the platform: host event → slice → todo row →
`Messaging` capability. Every step is a Lambda, a queue and a projection *on the estate being
monitored*, so an alert routed through it inherits every failure mode it exists to report. Against
the incident above, concretely:

- The `Plugin` aggregate could not replay, so every command to it failed. An alert that published a
  command would have dead-lettered alongside the heartbeats — and produced an alarm about *that*,
  which would publish another command, which would dead-letter.
- The trait's delivery is retryable work with a `maxRetries`, and what happens after the last attempt
  is its own plan ([retry-exhaustion-is-not-a-state.md](retry-exhaustion-is-not-a-state.md)). An
  alert a retry policy can abandon is not an alert.

A provider-native path (alarm → topic → subscription) is worth its separateness precisely because it
shares almost nothing with the estate: it still works when the event log, the queues and the handlers
do not.

Two further mismatches, either of which would be enough on its own. The trait's recipients come from
a preference registry populated by folding **host events** — domain principals — whereas an operator
is a deployment role who may have no user record and no reason to exist in the application at all;
this repo already draws that line with `REVENTLESS_ELEVATED_GROUPS`, where who counts as an operator
is deployment configuration rather than a domain annotation. And
[done/monitoring-hook-seam.md](done/monitoring-hook-seam.md) deliberately placed monitoring *outside*
the framework; routing it through a domain trait would put it a layer further in than the position
that decision rejected.

**What the trait is right for** is operational *notices* — a plugin retired, an import finished, a
deploy completed. Those are facts produced by a working system, so the dependency is sound. The rule
binds only where the premise is that the system is broken.

**And the useful integration is the other direction:** alarm state as data the application can
*show*, not as the mechanism that delivers it. A consumer of alarm state changes (EventBridge sees
every one, independent of `alarmActions`) can project them into a read model an admin surface
queries — read-only, off the alert's critical path, giving an admin in-app context while the message
that wakes someone up still comes from the path that does not depend on us. Worth doing after step 1;
never instead of it.

What may reasonably be shared is *configuration* vocabulary — where notices go, who receives them —
which is not the same as sharing a delivery path.

## Options for §2

**A. A minimal alarm backend in `reventless-aws`, opt-in per stack.** One module implementing
`Monitoring.Backend`: an SNS topic and subscription taken from stack config, and one
`Cloudwatch.MetricAlarm` per provisioned unit — `Errors ≥ 1` for every kind, `Invocations ≥ 1` for
`DeadLetterSink` (on that unit an invocation *is* the incident). A deploy program opts in with one
line before its platform build. **A stack that sets no config key deploys byte-identical to today.**

**B. Status quo, documented.** Accept that stacks deployed from this repo are unwatched, and write
that down where someone deploying one will read it. Cheap, honest, and leaves the reference estate in
the state that produced this finding.

**C. Depend on an out-of-repo backend from the example deploy programs.** Rejected: it inverts the
dependency (an example in the framework repo reaching for a package outside it) and makes the
framework's own CI deploy contingent on something it does not release.

**Recommendation: A**, scoped as small as it will go. The seam already carries everything such a
backend needs — `~kind`, `~name`, `~plugin`/`~platform`, `~component`, `~logLocator` — so the backend
is mostly a `metricFor(kind)` table and a resource. The work is in the wiring and the config, not the
alarms.

## Steps

| # | Change | Effort | State |
|---|--------|--------|-------|
| 0 | §1 — buffer announcements made before a backend registers, replay them to the first one, capture the owner at announcement rather than at delivery; `reset` for test isolation | small | **done 2026-09-07** |

Step 0 stands alone and is worth having whatever is decided below: it is what makes a dead-letter
sink monitorable *at all*, on this repo's stacks and on anyone else's. The rest is §2.

| # | Change | Effort |
|---|--------|--------|
| 1 | `Monitoring_Alarms_Aws` in `reventless-aws`: `metricFor(kind)`, one alarm per unit, topic + subscription from stack config | ~half a day |
| 2 | Alarm description carries plugin / platform / component / kind, so the notification names the unit — the SNS message carries the description but not the alarm's tags | small |
| 3 | Opt the hybrid example's AWS deploy program in; add the config key to `Pulumi.alpha.yaml` only, so `main` is unchanged until deliberately opted in | small |
| 4 | Unit tests: a stub backend asserting one alarm per provisioned unit and the `DeadLetterSink` metric override; a no-config stack provisions no monitoring resources | small |
| 5 | Document the opt-in — what a stack gets, what it costs, and how to point it at an existing topic | small |

Steps 1–2 are one commit; 3 needs a deploy to prove.

## Verification

Not "the alarms exist" — that is what step 4 asserts. The acceptance test is the incident replayed:
**break one aggregate's decode path on the alpha stack deliberately, and measure the time from the
first failed command to a notification.** Target: minutes. Today's measurement for the same failure
is *never*, with a floor set by how long it takes someone to read a bill.

Second check, cheaper and worth having permanently: after a deploy, assert that the count of alarms
in the stack equals the count of provisioned execution units. A unit that is provisioned without an
alarm is the silent case coming back — and §1 is precisely that check failing by one, undetected for
as long as the seam has existed.

For §1 specifically, the check is a single query against a monitored stack: an alarm whose name or
description carries `kind=deadlettersink`. There were none before this change on any stack in the
estate; there should be one per platform after the next deploy that registers a backend.

## Open questions

- **Where the notification goes.** An email subscription is the least infrastructure and the least
  useful at 3 a.m.; anything better is a routing decision that belongs to whoever operates the
  estate, not to the framework. Step 1 should make the topic ARN configurable so a stack can point at
  something that already exists. Whatever it points at, it stays outside the estate — see the
  decision above.
- **Alarming a scheduler is different from alarming a handler.** A heartbeat that *stops* produces no
  errors and no invocations — the absence is the fault. `treatMissingData` and a `< 1` threshold
  invert it, but that is a per-kind decision the `metricFor` table cannot express as it stands, and it
  is exactly the case that caught this estate. Worth resolving in step 1 rather than after.

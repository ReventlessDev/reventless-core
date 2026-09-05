# Plan: a seam that announces every execution unit, and nothing listening

**Date:** 2026-09-05
**Status:** Proposed — not started. Found while tracing a dead-letter loop back to its cause and
discovering that nothing had reported the incident at any point in its 12-hour life.
**Repos:** `reventless-core` only.

**Goal.** A stack deployed from this repo tells someone when one of its execution units stops
working, rather than being found later in a bill.

**Non-goal.** Making monitoring a framework concern. `Monitoring` is deliberately a seam — core says
*"I provisioned an execution unit of this kind"* and leaves what to do about it to a registered
backend, and [done/monitoring-hook-seam.md](done/monitoring-hook-seam.md) argues that at length. That
decision is right and this plan does not revisit it. The gap is not that core declines to alarm; it
is that **nothing in this repo ever registers a backend**, so on every stack this repo deploys the
seam's default is the one that does nothing.

---

## The finding

`Monitoring.use` is never called anywhere in `reventless-core`. The three matches in the source tree
are a doc comment, a comparison in an unrelated seam, and the definition itself; no deploy program
calls it. So `Monitoring.backend` stays
[`Noop`](../../reventless/core/src/adapter/Monitoring/Monitoring.res#L98) and every `notify` — the
runtime backend's per-unit announcement, and the dead-letter sink's — is discarded at the call site.

The only CloudWatch alarm in all of `reventless-aws` is the upload claimer's `IteratorAge` lag alarm
([Upload_Claim_S3.res:347](../../reventless/aws/src/adapter/Upload/Upload_Claim_S3.res#L347)), which
was written for a specific data-loss risk and is not part of any general posture.

The consequence is exact: **no command handler, projection, reactor, event collector, task,
scheduler or dead-letter sink deployed from this repo is alarmed on anything.**

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
3. No alarm on the dead-letter handler's own invocations, which by design fails on every one.
4. The cause was fixed the same evening by an unrelated migration step. Seven stranded messages kept
   cycling for **twelve hours past the fix**, and nothing said so.

It was found by attributing a CloudWatch bill to log groups. Every signal an operator would want was
being *emitted* — `Errors`, queue depth, invocation count — and none was *subscribed to*.

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

## Options

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
alarm is the silent case coming back.

## Open questions

- **Where the notification goes.** An email subscription is the least infrastructure and the least
  useful at 3 a.m.; anything better is a routing decision that belongs to whoever operates the
  estate, not to the framework. Step 1 should make the topic ARN configurable so a stack can point at
  something that already exists.
- **Alarming a scheduler is different from alarming a handler.** A heartbeat that *stops* produces no
  errors and no invocations — the absence is the fault. `treatMissingData` and a `< 1` threshold
  invert it, but that is a per-kind decision the `metricFor` table cannot express as it stands, and it
  is exactly the case that caught this estate. Worth resolving in step 1 rather than after.

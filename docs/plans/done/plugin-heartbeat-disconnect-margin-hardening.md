# Plan: harden the plugin-lifecycle heartbeat / disconnect margin

## Problem

A plugin's liveness is tracked entirely by the scheduler: every heartbeat re-arms a
one-time disconnect schedule, and if heartbeats stop, the schedule fires and marks
the plugin `Disconnected`. The disconnect grace is computed as the heartbeat
**command interval + 2 minutes**:

```rescript
// reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res
| PluginExtensionPointSpec.Heartbeat(interval) => [
    PublishCommand(Plugin.name(id), Delegate.Heartbeat(Plugin.version(id))),
    // Re-create timeout (+2 minute to avoid toggling)
    HandleDirective(directiveHandler, CreateDisconnectSchedule(id, interval + 2)),
  ]
```

This is correct **only when two independently-wired values agree**:

1. the recurring heartbeat **schedule rate** (`HeartbeatRunner` EventRule,
   `every(timeout->Minutes)`), and
2. the **interval carried inside the `Heartbeat` command** (from the heartbeat
   handler's `timeout`), which drives `CreateDisconnectSchedule(id, interval + 2)`.

Both are meant to come from a plugin's `heartbeatInterval`
(`Plugin_Builder.res` threads it to the schedule *and* the handler). But they are
threaded through **two separate call sites**, so a build can decouple them.

### Failure mode observed

A deployed plugin ran with heartbeat **schedule `rate(60 minutes)`** but a heartbeat
**command interval of ~10 min** (disconnect grace ≈ 12 min). Result: the plugin
reconnected for ~12 min after each hourly beat, then sat `Disconnected` for the
remaining ~48 min — it **flapped**, and any consumer of its connected-only outputs
(e.g. federated UI fragments) saw them disappear for most of every hour. The
heartbeat runtime itself was healthy; the cadence was the bug.

Root of the divergence: `Heartbeat_Builder.makeHandler(~timeout=10, …)` defaults to
`10`; if a build threads `heartbeatInterval` to the schedule but lets the handler
`timeout` fall back to the default, the two diverge silently. Current `Plugin_Builder`
passes `~timeout=heartbeatInterval` to **both**, so a fresh build no longer diverges —
but nothing *prevents* the divergence or fails loudly when it happens.

### Secondary robustness gap

Even with the two values in agreement, the grace is a **fixed +2 min** regardless of
interval:

| Interval | Grace | Headroom |
|---|---|---|
| 5 min | 7 min | +40% |
| 60 min | 62 min | +3% |

EventBridge `rate()` rules are best-effort and can be delayed; add Lambda cold-start
latency and a 3% margin at a 60-min cadence can produce **spurious disconnects** from a
single late beat. The margin should scale with the interval.

## Goals

1. Make schedule-rate and disconnect-grace **impossible to diverge** (single source of
   truth), or fail loudly if they do.
2. Make the disconnect grace **scale with the interval** so large cadences keep real
   headroom.
3. Regression test: a plugin with `heartbeatInterval = N` stays `Connected` across ≥ 2
   heartbeat cycles under simulated scheduler jitter.

## Proposed changes

### 1. Single source of truth for the interval

- Remove the `~timeout=10` **default** from `Heartbeat_Builder.makeHandler` (and the
  `connect` default) so the interval is always supplied explicitly by
  `Plugin_Builder`. A missing value should be a compile error, not a silent `10`.
- Alternatively/additionally, have `Plugin_Builder` compute the interval once and pass
  the same binding to both the schedule and the handler, so the two call sites cannot
  drift.

### 2. Scale the grace

Replace the fixed `+2` with a proportional margin, e.g.:

```rescript
let disconnectGrace = interval + max(2, interval / 2)   // ≥ +2 min, ≥ +50% for large intervals
```

(Exact factor TBD — `interval * 2` is the simplest defensible choice. Keep the "round
up to whole minutes" and "one extra minute for latency" intent from the current
comment.) Apply the same formula to the `RedetectPlugin(interval)` arm, which currently
also uses `interval + 2`.

### 3. Test

- Extend the plugin-lifecycle GWT/behavior tests: heartbeat at interval `N`, advance
  the test clock by `N + jitter`, assert the plugin remains `Connected`; advance past
  the grace with no heartbeat, assert `Disconnected`.
- Add a build/regression assertion that the schedule rate and the command interval
  derive from the same `heartbeatInterval`.

## Affected files

- `reventless/core/src/plugin/connect/PluginExtensionPoint_Plugin.res` — grace formula
  (both `Heartbeat` and `RedetectPlugin` arms).
- `reventless/core/src/components/Heartbeat/Heartbeat_Builder.res` — drop the `10`
  defaults so the interval is mandatory.
- `reventless/core/src/plugin/component/Plugin_Builder.res` — confirm single-source
  threading of `heartbeatInterval` to schedule + handler.
- Plugin-lifecycle tests.

## Non-goals

- Changing the scheduler-driven liveness model (aggregates still never read time).
- Per-plugin configurable grace policy — a single scaling rule is sufficient.

## Notes

Downstream, operators should also ensure `DeleteDisconnectSchedule` prunes prior-version
disconnect schedules; stale per-version schedules were observed accumulating in at least
one environment. Track separately if it is not already covered.

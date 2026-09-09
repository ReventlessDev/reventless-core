# A stale handshake answer asks again

## The problem

A deploy publishes a synthetic re-detect so the platform re-runs the connect
handshake and stores the plugin's new structure. The EventCollector Lambda is what
*answers* that handshake, and it is being updated by the same deploy. Reached
before the new code is live, it answers with the previous deploy's definition;
`PluginBehavior.decide` sees a definition it already holds and returns `Ok([])`;
the registration keeps the old structure, and **no second re-detect is coming**.

The manifest bake then fails with the plugin `behind`, and stays that way until
some later deploy happens to win the race.

### Why the timing cannot be fixed

Two attempts gated the re-detect on the collector Lambda's outputs:

| gate | re-detect, relative to the update |
|---|---|
| `Output.apply` on the resource | 1.2s **before** the update started |
| `flatMap` to `arn` | 1.2s **before** the update started |
| `flatMap` to `lastModified` | 6.3s after it started, 6.4s **before** it completed |

`lastModified` moved it 7.5s later and still landed early. `UpdateFunctionCode`
returns a new `LastModified` when AWS *accepts* the update, while
`LastUpdateStatus` is still `InProgress`; Pulumi's remaining wait before it reports
`updated` is that status settling. The outputs describe *accepted*, and the
handshake needs *live*. No output property expresses the difference.

So this plan stops trying to win the race and makes losing it recoverable.

## The change

The deploy already knows the structure key it wrote — `structureOffloadKey`, which
the stack exports as `pluginStructureRef` and the bake compares against. Carry that
key on the re-detect, and have the aggregate check the answer against it.

1. **Carry the expectation.** `RedetectPlugin` gains the expected structure key;
   `PluginExtensionPoint_Plugin.mapIncomingCommand` threads it into
   `Delegate.Redetect`.
2. **Record it.** `Redetect` emits its `VersionDetected` as today, plus a new event
   naming the key the answer must carry and which attempt this is.
3. **Check the answer.** `Connect(def)` derives the answer's key from
   `def.structure` (`Offload.payload` → `Offloaded({key})`). When an expectation is
   outstanding for that version and the key differs, the answer is stale: emit a
   staleness event instead of today's silent `Ok([])`.
4. **Ask again.** The EP maps that event to a scheduled `RedetectPlugin` carrying
   the same expectation and `attempt + 1`, reusing the schedule directive that
   already re-arms disconnect.
5. **Stop.** After `maxRedetectAttempts`, give up and log. The bake still fails,
   which is right — at that point the cause is not the race.

## Schema safety

This is the constraint that governs the whole design. Adding a **required** field
to anything reachable from `pluginDefinition` breaks replay of every stored
`VersionConnected` / `VersionSuperseded`, and the Plugin aggregate then dies on
*every* command for that plugin, silently. Recovery is wiping the plugin's
partition from `PluginAggrEventLog-*`.

- **Events are replayed** → only *add constructors*. Never add a field to an
  existing event's payload. A new constructor is invisible to old logs.
- **State is never persisted** — `PluginBehavior.snapshot = None`, so state is
  always refolded from events. Adding fields to `state` costs nothing.
- **Commands are SQS-borne, never replayed** → changing `RedetectPlugin` /
  `Redetect` payloads risks only messages in flight across the deploy boundary.
  A decode failure there loses one re-detect and self-corrects on the next
  heartbeat; it cannot wedge an aggregate.

## Open questions

- **`Inline` structures.** A small plugin's structure may be inline rather than
  offloaded, so there is no key to compare. Treat "no key on either side" as
  today's behaviour (accept) rather than as a mismatch, or the retry never
  terminates for those plugins.
- **Delay and attempts.** A retry that fires immediately hits the same
  not-yet-live Lambda. Needs a delay comparable to the propagation window
  (observed ~6s); suggest 15s and 5 attempts, both named constants.
- **Interaction with the disconnect schedule.** Each `RedetectPlugin` re-arms
  disconnect. Repeated retries must not extend liveness indefinitely for a plugin
  that is genuinely gone.

## Verification

The unit tests can cover the decision table directly — a matching key, a differing
key with attempts left, a differing key at the limit, and an inline structure — and
that is where the logic lives.

What they cannot show is that the retry actually converges against a real
propagation delay. That needs **a deploy in which a plugin's structure changes**;
a dependency or release commit does not produce one. The evidence to look for in
that deploy's bake step is `registered: 2`, not merely `baked: true` — a bake
reporting `0/2 plugin(s) re-registered` has verified nothing, which is how the
2026-09-08 12:58 deploy passed while the gate was still broken.

## Status

Design agreed, not yet implemented.

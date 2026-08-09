# Plan: make the deploy-time re-detect actually fire

**Date:** 2026-08-09
**Status:** Implemented — verification steps 1–5 are deploy-time observations, still open.
**Repos:** `reventless-core` only.

## Why

`deployPlugin` ends by publishing one synthetic `RedetectPlugin` command for the plugin it just
built (`aws/src/Platform.res:2461-2506`). Its comment states the purpose precisely:

> Uses `RedetectPlugin` rather than a keep-alive `Heartbeat` so an already-connected version re-runs
> the handshake and refreshes its stored definition on the lifecycle row (e.g. a newly added
> `kind`) — a plain heartbeat no-ops a connected version and would never re-serialize the def.

It has never fired. Every plugin deploy logs the skip branch instead:

```
pulumi:pulumi:Stack <plugin>-aws-<stack> running
  {"level":"WARN","message":"synthetic heartbeat skipped: no EP queue URL in heartbeat config",
   "comp":"Platform:deployPlugin"}
```

Three plugins in one deploy, three skips, no exceptions.

### Why the config is empty

`heartbeatConfigRef` is written by `registerHeartbeatConfig`, called from the
`onHeartbeatEpChannelAvailable` hook (`aws/src/Platform.res:827-840`). Core fires that hook from
`Plugin_Builder.res:941` — **inside** the `applyAttributed` callback opened at
`Plugin_Builder.res:650`, whose own comment says it "runs after this construct has returned".

`deployPlugin` reads the ref at `aws/src/Platform.res:2476`, synchronously, a few statements after
`P.make()` returns. At that moment the callback has not run, so the ref still holds its initial
`{epQueueUrl: None}` (`aws/src/plugin/runtime/PluginRuntime_Builder.res:175-178`) and the publish is
skipped.

Nothing else is broken by the same ordering, which is why it went unnoticed: `forPluginHeartbeat`
(`PluginRuntime_Builder.res:802-826`) reads the very same ref and gets a populated one, because it
is called at `Plugin_Builder.res:947` — inside the callback, after the hook. The heartbeat Lambda
gets its `EP_QUEUE_URL` and the natural heartbeat works. Only the one caller that reads the ref from
outside the callback sees it empty.

`deployPlugin` already documents this exact hazard forty lines earlier
(`aws/src/Platform.res:2290-2294`), for `StateTopic_AppSync.finish`. It is the same trap, one
construct over. It is also the same shape as the deferred-`finish` attribution bug.

### What it costs

The lifecycle row's stored definition — `structure`, `kind`, `apiSchemaFragment`, `extensionPoints`
— is rewritten only by `VersionConnected` / `VersionActivated` / `VersionPromoted`
(`PluginsProjection.res`). `decide` (`PluginBehavior.res:127-155`) emits those on exactly three
paths:

| Path | Refreshes a *connected, same-version* plugin's definition? |
| --- | --- |
| `Heartbeat` | No — `Ok([])` keep-alive |
| Version the aggregate has never seen | Yes — full handshake |
| Heartbeat-timeout `Disconnect` then reconnect | Yes — `connectEvents` re-serializes the def |
| `Redetect` | Yes — this is what it is for. **Never fires.** |

A plugin whose version changes on every release is therefore healed by accident: the new version is
unknown, so the handshake runs and the definition is re-serialized. A plugin whose version does
*not* change — a private, unpublished stack package resolves the same `PackageVersion.fromCaller()`
string on every deploy — has no such accident available. Its persisted definition freezes at
whichever deploy last happened to disconnect it, and stays frozen across any number of successful
green deploys.

Observed on a deployed estate: a plugin declaring ten state-change slices had eight in its persisted
structure, missing both slices added since, plus every `writableDef` field added since. Two of its
peers, version-bumped by their release, were current. The gap had been open for six days and no
deploy narrowed it.

This is not only a staleness problem. Because the admin SDL's component types use non-null lists, a
structure that predates a required field resolves that field to null and GraphQL propagates the null
to the root — one frozen plugin answers the whole `Platform_PluginStructures` / 
`Platform_ComponentDefinitions` query with `data: null`. The read-path healing in
`Platform_ComponentDefinitions_Lambda_Ops` keeps the query answerable, but it substitutes `[]` for
data the plugin does have. It is a guard, not a fix. This plan is the fix.

## Change

**Chain the publish onto an output that resolves after the deferred callback.** No new abstraction
is needed — `Plugin.outputs` is already derived from `builderOutputs`
(`Plugin_Builder.res:989-1013`), which *is* the deferred callback's output. Anything applied to it
runs after the hook has written the ref.

In `aws/src/Platform.res`, replace the synchronous read at 2476 with a read inside an apply on the
plugin component's outputs:

```rescript
// `heartbeatConfigRef` is written from the onHeartbeatEpChannelAvailable hook, which core fires
// from inside the deferred construct callback — after `P.make()` has returned. Reading it here
// synchronously always saw the initial empty config. `pluginOutputs.heartbeat` derives from that
// same callback's output, so applying to it is the earliest point the config is populated.
let _ = pluginOutputs.heartbeat->Pulumi.Output.apply(_ => {
  let hbConfig = PluginRuntime_Builder.heartbeatConfigRef.contents
  switch (Pulumi.Pulumi.isDryRun(), hbConfig.epQueueUrl) {
  | (true, _) => ()
  | (false, Some(epQueueUrl)) => /* unchanged body */
  | (false, None) => /* unchanged warn */
  }
})
```

The publish body itself is unchanged, including its inner `epQueueUrl->Pulumi.Output.apply` and its
try/catch fallback to the next natural heartbeat.

**Keep the skip warning.** It is the only signal that distinguishes "fired" from "silently didn't",
and it is what surfaced this. Add a matching success log — `synthetic re-detect published for
<pluginId>` — so a deploy log answers the question either way rather than only on failure.

### Alternative considered: fire from inside the hook

`onHeartbeatEpChannelAvailable` already receives the EP channel, the plugin id and the interval —
everything the publish needs — and it runs at the right time by construction. Rejected: the hook's
contract is to hand core-built infrastructure to the adapter, and a deploy-time command publish is
a `deployPlugin` concern. Putting it there also moves the `isDryRun` guard into core's call path,
where the platform-vs-plugin distinction that decides whether a re-detect is even wanted is not
available. The output-chaining fix keeps the side effect where the decision lives.

### Follow-on to consider, not part of this change

This is the third construct to be bitten by the deferred callback boundary (`StateTopic_AppSync.finish`,
deploy-time attribution, this). Each was fixed locally. If a fourth appears, the boundary deserves a
named seam — an explicit `afterConstruct: Pulumi.Output.t<unit>` on `Plugin.outputs`, documented as
*the* place for post-construct deploy-time side effects — rather than each caller rediscovering
which of the existing outputs happens to be downstream of the callback.

## Verification

1. **Deploy log.** The new success line appears once per plugin stack; the skip warning does not.
2. **Lifecycle event log.** The plugin aggregate's stream gains a `VersionDetected` with
   `user = "DeployHeartbeat"` (the meta `deployPlugin` stamps), followed by `VersionConnected`
   whenever the definition actually changed — and no `VersionConnected` when it did not, since
   `decide` is idempotent on an unchanged def (`PluginBehavior.res:153`).
3. **Row freshness.** For a plugin whose version did not change but whose structure did, the
   lifecycle row's `structure` reflects the deploy rather than the last disconnect.
4. **No re-write storm.** Deploy twice with no source change; the second deploy produces a
   `VersionDetected` and no `VersionConnected`.
5. **Preview is inert.** `pulumi preview` publishes nothing — the `isDryRun` guard still short-circuits
   before the publish.

## Risk

Low, and bounded by the existing fallback. The publish is fire-and-forget with a try/catch that
degrades to the next natural heartbeat, exactly as today; the change only moves *when* it is
attempted. The one new behaviour is that a re-detect now actually reaches the aggregate on every
plugin deploy, which is the designed path (`PluginSpec.res:13-16`) and is already exercised by
`local/tests/plugin/PluginBehavior_GWT.res:47-62`. Worst case for a plugin whose definition genuinely changed is one
extra `VersionConnected` per deploy — the event the row needs and currently never gets.

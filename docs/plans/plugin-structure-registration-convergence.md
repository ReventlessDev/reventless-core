# Plan: the manifest bake's convergence check can fail forever, and cannot say why

**Date:** 2026-08-27
**Status:** §1, §4 and §5 done; §3 resolved as already-satisfied (see below); §2 partly done,
the rest left open with its reasoning.
**Repos:** `reventless-core` only.
**Relates to:** [baked-manifest-without-host-ui-bundle.md](./baked-manifest-without-host-ui-bundle.md)
(a platform that cannot bake at all — a different gap in the same feature) and
[plugin-definition-schema-evolution-guards.md](./plugin-definition-schema-evolution-guards.md)
(what happens when a persisted definition predates a field).

## What was seen

On a live estate, every stack deployed cleanly and the manifest bake then failed: one plugin of
six never satisfied the convergence check, through 20 attempts, twice — a re-run reproduced it
exactly, so it is a standing mismatch and not a slow projection.

The bake compares the structure key a plugin's stack exported (`pluginStructureRef`,
`aws/src/Platform.res`) against the key on that plugin's Plugin read-model row, and refuses to
write until they agree. Refusing was **correct**: the manifest would otherwise have described the
previous deployment, which nothing downstream could detect. The design is right; two things
around it are not.

## Defect 1 — the check is green for the wrong reason

The comment on `structureOffloadKey` states the property plainly: the equality check "passes
immediately for a plugin whose structure did not change." That is a deliberate and desirable
optimisation — but it means **a plugin whose structure is unchanged passes without exercising
the re-detect → handle → project chain at all.**

So on the run above, five of six plugins passed because they had nothing to update. Only the
sixth — the one whose structure genuinely changed — actually tested the mechanism, and it
failed. A green bake therefore says "nothing needed to converge" far more often than it says
"convergence works", and the difference is invisible in the job's output.

The consequence is the serious part: **this path can be broken for an arbitrary number of green
deploys**, and the first deploy that changes any plugin's structure is where it surfaces —
maximally far from whatever broke it.

## Defect 2 — the failure carries no evidence

When it does fail, the job reports one thing: the plugin's name. It does not report

- the key it expected (it has this — it printed `Expecting:` earlier in the same job),
- the key the read-model row actually holds,
- when that row was last written,
- which link of the chain did not happen.

Three links can each produce this identical symptom: the re-detect was never published, the
plugin never answered it, or the projection never landed. A fourth is worse — that the plugin
*did* answer and produced a **different structure than the deploy hashed**, in which case the two
keys can never converge and every retry is spent waiting for something that cannot happen.

Diagnosing which required reading the read model directly, out of band, with credentials the
deploy pipeline does not surface. That is the gap this plan exists to close: the bake already
knows both halves of the comparison and reports neither.

## The invariant nobody checks — and why it turned out to hold

Content addressing makes the key a *consequence* of the structure bytes, so convergence requires
that **the structure the deploy hashes and the structure the plugin's own registration produces
are byte-identical.**

The plan assumed those were two independent computations — the deploy program, resolved from the
deploying workspace's install, against the plugin's runtime, whose framework comes from the Lambda
layer on its own release cadence. **They are not.** There is only one computation:

- `Plugin_Builder` offloads the structure once, during `P.make()`, and the returned reference
  becomes `pluginDefinition.structure` ([Plugin_Builder.res:648](../../reventless/core/src/plugin/component/Plugin_Builder.res#L648),
  [Plugin_Helpers.res:823](../../reventless/core/src/plugin/component/Plugin_Helpers.res#L823)).
- That **same value** is serialized to `pluginDefinition.json` and shipped inside the
  EventCollector's code archive ([Plugin_Helpers.res:608](../../reventless/core/src/plugin/component/Plugin_Helpers.res#L608)).
- The runtime decodes that file at cold start and hands it straight back through the Connect
  handshake ([EventCollectorEntryPoint_Ops.res:679](../../reventless/aws/src/adapter/Runtime/EventCollectorEntryPoint_Ops.res#L679),
  [PluginConnectExtension_Mapping.res](../../reventless/core/src/plugin/connect/PluginConnectExtension_Mapping.res)).

So the key is already carried, which is exactly what §3's preferred option proposed to build. The
layer's framework version cannot move it: the runtime never derives the structure's identity, it
only relays it. Recorded as a test rather than as a change — see §3 below.

The practical consequence is that a mismatch already means "this plugin has not registered", never
"this plugin registered something else", so the ambiguity §1 was written to resolve by hand is
narrower than it looked.

## Phases

### §1 — Make the failure state its evidence — **done**

`pendingRegistrations` (a list of names) is now `registrations`, returning per plugin the key the
deploy expected, the key the row holds, the row's last-written timestamp and a classified state.
The workflow prints one line per plugin on every pending attempt and on the final failure.

The row's date is `statusChange.at`. It is the right clock: every event that moves a version's
status stamps the producing message's time onto it, and `PluginBehavior.decide` re-emits
`VersionConnected` exactly when a Connect carries a changed definition — so it advances when the
chain completes and stays put when it does not.

The invocation now also carries `since`, the instant the deploy began (the `detect-changes` job
stamps it, before any stack runs). It is what lets a matching key be told apart as re-registered
or merely never changed, which §4 needs.

### §2 — Distinguish the links — **partly done**

Reported from the read model: `behind` (the row predates this deploy — the case retrying is for),
`diverged` (the row was written by this deploy and still holds another key — retrying cannot fix
it), and `missing`.

`missing` is **a cause this plan did not list, and the one that best fits the observed symptom.**
The bake's scan filters on `contains(status, "Connected")`, so a plugin whose row is not Connected
— a version that dropped out mid-deploy, was deactivated, or was retired — leaves nothing to
compare against. Before this it was indistinguishable from a projection that had merely not landed
yet, and was waited on for the whole retry budget either way, reproducibly, forever.

Left open: the full three-link split (the re-detect published / the plugin answered / the
projection landed). The read model cannot separate the last two — both leave the row untouched —
and doing it properly means reading the Plugin aggregate's event log for `VersionDetected` and
`VersionConnected`, which the bake Lambda has neither an env var nor an IAM grant for. Worth doing
if the evidence §1 now prints turns out not to be enough; not worth the grant on speculation.

### §3 — Remove the divergence — **no work needed; the key is already carried**

See "The invariant nobody checks" above: the runtime does not recompute the structure. The deploy
offloads it once, ships the resulting reference inside `pluginDefinition.json`, and the runtime
relays that file back through the Connect handshake — which is precisely the preferred design.

So this phase became a test rather than a change. `BakeConvergenceTest` asserts it end to end: the
key the deploy's offload hook exported is the key on the row the projection writes, after the
definition has been through the same encode → decode round trip the EventCollector performs.
Nothing enforced that before, and it is the property every other phase rests on.

`Diverged` is still reported — the invariant makes a framework-version mismatch impossible, not a
concurrent stack or a reconnect replaying an older definition.

### §4 — Stop reporting an untested path as a pass — **done**

The fast path is kept and now counted apart. A successful bake's response carries an appended
summary — `registered` / `unchanged` / `matched` — and the workflow prints it, with a `::notice::`
when `registered` is zero: the manifest is current, and the chain that keeps it current was not
exercised by any plugin on this deploy.

Appended rather than merged into a file's report so `[0]` stays the first file, which is what the
workflow reads to decide whether anything was written.

### §5 — A test that would have caught it — **done**

`reventless/aws/tests/BakeConvergenceTest.res`. A plugin's structure changes between two deploys
and the bake is required to converge, driving the real chain rather than hand-built rows: the
deploy-time offload hook, the `pluginDefinition.json` round trip, `PluginBehavior.decide` on
Redetect and Connect, and `PluginsProjection.displayState`.

It pins the two facts the old coverage could not distinguish — a changed structure re-emits
`VersionConnected` and converges as `registered`; an unchanged one emits nothing, is never
rewritten, and passes as `unchanged` — which is Defect 1 stated as a test.

Still not covered: the transport between those steps (the re-detect's publication and the
plugin's answer crossing SQS/SNS). That needs a live estate or the local platform's bake, and is
the same gap §2's remaining half describes.

## Risks and notes

- **Do not "fix" this by widening the retry budget.** The re-run reproduced the failure exactly;
  more attempts would only spend longer reaching the same conclusion, and would make a standing
  divergence look like flakiness.
- **The refusal is the good part.** Whatever changes, the bake must keep declining to write a
  manifest it cannot prove is current — a well-formed manifest of the wrong deployment is the
  failure mode this check exists to prevent, and it is undetectable downstream.
- **`retainOnDelete` on the structure objects is load-bearing** and its reasoning (the read model
  points at the previous object during the async window) is adjacent to this plan: §3's first
  option shortens that window's blast radius but does not remove the need.

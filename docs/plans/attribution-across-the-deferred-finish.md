# Plan: Carry plugin attribution across the deferred builder finish

**Status.** Planned — 2026-08-08. Not started. Found when an out-of-tree runtime extension
deployed with `plugin: null` in its runtime config, and the same runtime turned out to carry an
empty `reventless:plugin` tag.

**Goal.** A resource created in a builder's deferred `finish()` is attributed to the plugin that
owns it, exactly as one created during `construct` already is.

**Non-goal.** Changing what attribution *means*, or the tag vocabulary. `ResourceAttribution` is
the right abstraction and its consumers are correct; this is about a phase in which it silently
reports nothing.

---

## §1 — The invariant, and the code that breaks it

`ResourceAttribution` publishes the plugin under construction as ambient state, so adapters far
below the builder can tag what they create without every signature carrying two strings. Its own
docstring states the invariant that makes this safe:

> Safe because deploy-time resource construction is synchronous (**the framework forbids creating
> resources inside `Pulumi.Output.apply`**), so everything built between `enter` and `restore`
> genuinely belongs to that plugin.

`Plugin_Builder.construct` honours the bracket: `enter` at `:73`, `restore` at `:1026`.

The deferred finish phase does not. `Builder_Helpers` defers runtime creation until every
registration has landed, and it does so **by waiting on outputs** — which means the finish
functions run inside an apply:

```rescript
// Builder_Helpers.res:114-121 (finishTasks); :126-136 (finishReadModels) has the same shape
taskSideEffectGates
->Pulumi.Output.all
->Pulumi.Output.apply(_ => taskSideEffectFinishFns->Array.forEach(finishFn => finishFn()))
```

Those callbacks run **after `construct` has returned**, so `restore` has already put the ambient
context back to `{platform: None, plugin: None}`. Every resource a `finish()` creates is therefore
attributed to nobody.

The deferral itself is correct and well-argued — `Builder_Helpers.res:100-103` explains that a
synchronous finish would build a shared runtime before any handler had registered. The bug is not
the deferral; it is that attribution was designed for a synchronous world the builders have since
left.

## §2 — The evidence: two resources, one deploy, one plugin

Same plugin, same deploy. A runtime built in the deferred finish, versus a resource created by a
construct-time seam (`EventLogProvisioning`, which fires while the bracket is open):

| | built in `finish()` | built during `construct` |
| --- | --- | --- |
| `reventless:plugin` | **`""`** | the plugin name |
| `reventless:scope` | `component` | `plugin` |

And the same context feeds the `RuntimeExtension` seam, which reads
`ResourceAttribution.current.contents` at `RuntimeEnvironment_Lambda.res:260-261` to build a
runtime's `RUNTIME_EXTENSIONS` config. Every command runtime observed carried:

```json
{"runtimeKind":"StateChangeSlice","component":"…DcbCmdHandler","plugin":null,"platform":null}
```

`plugin: null` is documented to mean *"provisioned outside any plugin construct"* — the correct
answer for platform substrate. Here it is a **false negative**: the runtime is a plugin's own
command handler.

## §3 — Why this is worth fixing beyond one seam

`ResourceAttribution.current` is read by `AWS_Tags.make`, `Monitoring.notify`,
`EventLogProvisioning.notify` and the `RuntimeExtension` config. So the blast radius is every
consumer that answers "which plugin owns this":

- **Cost allocation.** Provisioned resources are tagged `reventless:plugin` precisely so spend can
  be attributed. A runtime with an empty tag is spend that belongs to nobody — and runtimes are
  the expensive resources.
- **Inventory and resource maps.** Anything grouping by owning plugin drops these resources into
  an unattributed bucket, or fabricates an owner from a name.
- **Out-of-tree extensions.** An extension told `plugin: null` cannot key per-plugin state. It
  either mis-files everything under one bucket or has to re-derive the plugin by string-surgery on
  the component name — parsing suffixes the framework owns, which is exactly the coupling the seam
  exists to avoid.
- **A false negative is worse than a gap.** `None` is a *meaningful* value here — it means platform
  scope. A consumer cannot distinguish "genuinely unowned" from "owned, but built in the wrong
  phase", so it cannot even detect the problem.

## §4 — Shape of the fix

The ambient bracket cannot span an apply, so the context has to be **captured** where it is known
and **reinstated** where the work actually runs.

Preferred: capture at registration, reinstate around the call. The finish functions are already
registered through choke points (`registerTaskSideEffectHandler` and the equivalents), each called
during `construct` while the context is populated. Capturing `ResourceAttribution.current.contents`
at registration and re-entering it around `finishFn()` needs no builder signature to change and no
call site to learn anything:

```rescript
let registerTaskSideEffectHandler = (~gate, ~finish) => {
  let captured = ResourceAttribution.current.contents          // populated: inside construct
  let _ = taskSideEffectFinishFns->Array.push(() => {
    let previous = ResourceAttribution.restoreCaptured(captured) // deferred: reinstate
    finish()
    ResourceAttribution.restore(previous)
  })
}
```

This wants one addition to `ResourceAttribution`: a way to re-enter a captured `context` (today
`enter` takes two required strings, so it cannot express "restore whatever was captured, including
`None`"). Restoring afterwards keeps nesting honest — several plugins' finish functions can run
from one apply, so leaving the context set would attribute the next one wrongly.

**Rejected — thread plugin/platform through every builder signature.** This is the churn
`ResourceAttribution` was created to avoid, and it would have to reach every adapter that creates
a resource.

**Rejected — read attribution lazily inside the resource.** Same failure, later: the value is read
when the apply runs, which is the moment the context is already empty.

**Rejected — forbid resource creation in `finish()`.** The deferral exists for a stated reason
(`Builder_Helpers.res:100-103`) and removing it reintroduces the ordering bug it fixed.

## §5 — Where else to look

`finishTasks` and `finishReadModels` are the two confirmed sites, but the pattern is
"`Pulumi.Output.apply` around resource creation", and the docstring's invariant says that should
not exist at all. The audit is: **every `apply` that creates a resource**, not just the two named
here. Each is both an attribution bug and a counter-example to the documented invariant, so the
sweep should end either with the sites fixed or with the docstring corrected to describe the world
as it is.

Worth checking against known attribution symptoms before assuming they have separate causes — an
empty owner key on a provisioned resource is the signature this defect leaves.

## §6 — Acceptance

- A runtime created in a deferred `finish()` carries the same `reventless:plugin` /
  `reventless:platform` tags as one created during `construct`, for the same plugin.
- `RUNTIME_EXTENSIONS` names the owning plugin for every runtime that has one; `null` appears only
  for genuine platform substrate.
- Two plugins whose finish functions run from the same apply are attributed to themselves, not to
  whichever ran first.
- A test asserts attribution is populated *inside* a deferred finish — the regression this plan
  exists to prevent is silent, so it needs a test that fails without the fix.
- No builder or adapter signature changes.

---

## Appendix: code anchors (2026-08-08)

| Fact | Anchor |
| --- | --- |
| The invariant, stated | `reventless/core/src/ResourceAttribution.res:107-120` |
| Ambient context, default empty | `ResourceAttribution.res:123` |
| Bracket opened / closed by the plugin builder | `Plugin_Builder.res:73`; `:1026` |
| Finish deferred inside an apply (tasks) | `Builder_Helpers.res:114-121` |
| Finish deferred inside an apply (read models) | `Builder_Helpers.res:126-136` |
| Why the deferral exists | `Builder_Helpers.res:100-103` |
| Runtime-extension config reads the ambient context | `RuntimeEnvironment_Lambda.res:259-275` |
| Same context feeds tags and the deploy-time seams | `AWS_Tags.make`; `Monitoring.res:104`; `EventLogProvisioning.res:161` |

# Plan: announce a provisioned unit's owner and its diagnostics locator to the Monitoring seam

**Date:** 2026-07-24
**Status:** §1 implemented. §2 proposed.
**Repos:** `reventless-core` only.

Two rounds of the same question — *what does core have to hand a monitoring backend at provisioning
time, because nothing downstream can recover it?* §1 answered "who owns this unit" and shipped. §2
answers "where do this unit's logs live", which came out of an operator following an alert and
finding no way from the notification to the diagnostics.

## §1 — The owning plugin/platform

**Status: implemented.** `Monitoring.Backend.onProvisioned` takes `~plugin` / `~platform`, `notify`
reads them from the ambient `ResourceAttribution` context, and `MonitoringTest` asserts both the
in-scope and outside-any-scope cases.

### Why

The `Monitoring` seam (`reventless/core/src/adapter/Monitoring/Monitoring.res`) lets an extension
attach provider-native monitoring to every provisioned execution unit. Today `onProvisioned`
receives `~kind`, `~name` (the unit's static logical name — which is the owning component), and
`~component` (the deploy-time `Adapter.resource`, whose fields are `Output`s).

What it does **not** receive is the unit's owning **plugin** (and platform). A backend that names or
routes its monitoring resources per plugin therefore cannot attribute a unit to its plugin at
provisioning time. The component name alone is not enough: two plugins can own like-named components,
and any per-plugin grouping (dashboards, alert routing, a per-plugin rollup) needs the plugin.

Nothing downstream can recover it either. `~name` carries only the component; `~component`'s tags
are `Output`s (async, and not usable as a synchronous logical name); and provider monitoring
notifications generally do not carry a resource's tags. So the plugin identity has to be **present at
`onProvisioned` time** or it is lost.

### The opportunity: the ambient context already holds it

The plugin builder already publishes the owning plugin + platform for exactly this class of problem.
`Plugin_Builder.construct` calls `ResourceAttribution.enter(~platform, ~plugin=name)` around a
plugin's construction, so `ResourceAttribution.current.contents : {platform, plugin}` is populated for
every adapter that creates infrastructure below that point — which is precisely when `Monitoring.notify`
fires (the runtime backend provisions the unit inside `construct`). `AWS_Tags` already reads this same
ambient context to stamp `reventless:plugin` / `reventless:platform`.

So the seam can surface the plugin/platform **without threading a new argument through the whole
provisioning call chain** — `notify` reads the ambient context itself.

### Change

1. **`Monitoring.Backend.onProvisioned`** gains two labelled args:
   `~plugin: option<string>` and `~platform: option<string>` (both `None` outside any plugin
   construct — the correct answer for platform-scope substrate, mirroring `ResourceAttribution`).
2. **`Monitoring.notify`** reads `ResourceAttribution.current.contents` and passes `~plugin` /
   `~platform` through to the backend. Its **own** signature is unchanged, so the two call sites
   (`RuntimeEnvironment_Lambda`, `Util_DeadLetterQueue`) need no edit — the ambient read is internal.
3. **`Monitoring.Noop`** updated to the new signature (ignores the new args).
4. **`MonitoringTest`** — the `Recorder` / `Capture` stub backends updated to the new signature; add a
   case asserting that a `notify` fired inside a `ResourceAttribution.enter(~platform, ~plugin)` scope
   delivers the expected `~plugin` / `~platform`, and one outside any scope delivers `None`.

No behavioural change for a platform without a registered backend (`Noop` still swallows). The seam
stays "core only says a unit exists, its role, and now who owns it" — no monitoring policy in core.

### Acceptance

- `onProvisioned` receives `Some(plugin)` / `Some(platform)` for a unit provisioned inside a plugin
  construct, and `None` / `None` for platform substrate provisioned outside one.
- `notify`'s call sites are unchanged; the full core build is green; `MonitoringTest` passes.

### Downstream (out of scope here — noted for sequencing only)

Consumers of the seam (any monitoring extension) can, after this ships and is published, use the new
`~plugin` to attribute their per-unit monitoring resources. That work lives in each extension's own
repo/plan, not here.

## §2 — The unit's diagnostics locator

**Status: proposed.**

### Why

A monitoring backend turns each provisioned unit into a provider-native alert. When that alert
fires, the operator's very next move is always the same: *read this unit's logs*. The notification a
provider sends carries the alert's own identifiers — its name, its description, the metric and its
dimensions — and none of those is an address for the logs. So the alert announces that something
failed and then strands the reader, who has to reconstruct by hand which log stream belongs to the
unit that fired.

The backend could stamp that address into the alert at provisioning time, if it had one. It does
not, and — as in §1 — nothing downstream can recover it.

### Why a consumer cannot just compute it

This is the part that makes the gap real rather than cosmetic. On the AWS runtime a unit's log group
has **two possible shapes, chosen by stack configuration**:

- **Managed** — `Util_LambdaLogging.makeManagedLogGroup` creates the group first and points the
  function at it, named by `logGroupNameFor(~project, ~stack, ~name)`.
- **Unmanaged** — the same function returns `None` (the stack is listed in `unmanagedLogGroupStacks`
  and the caller pinned no retention override), the function carries no `loggingConfig`, and the
  provider auto-creates a group under its own default naming, keyed on the **physical** resource
  name rather than the static one.

Which branch applies is a stack-config decision that is invisible outside the runtime backend. A
consumer that derives the name therefore guesses, and guesses **wrong on precisely the stacks that
opted out** — sending an operator to a group that does not exist. A confident pointer to nothing is
worse than no pointer: it reads as "the logs are missing" instead of "look elsewhere". So the value
has to come from the site that already knows which branch it took.

Note this is the mirror image of §1's constraint, not a repeat of it. There the problem was that the
value existed but only in ambient context; here the value exists only in a local `option` at the
provisioning site, so `notify` cannot read it behind the call sites' backs.

### Change

1. **`Monitoring.Backend.onProvisioned`** gains `~logLocator: option<Pulumi.Output.t<string>>` — the
   provider-native address of the unit's logs, as an opaque string core assigns no further meaning
   to. On the AWS runtime it is the CloudWatch log group name; another runtime is free to put a
   namespace/selector there. `None` means the unit has no log stream of its own. Keeping it opaque
   is what stops provider vocabulary leaking into the seam, exactly as `unitKind` describes a role
   rather than a mechanism.
2. **`Monitoring.notify`** gains the same argument and forwards it. Unlike §1 this **does** change
   `notify`'s signature — the value is not ambient — so both call sites are edited:
   - `RuntimeEnvironment_Lambda` — passes the managed group's `name` when it created one, and
     otherwise the provider default derived from the function's physical name, so the locator is
     correct on both branches.
   - `Util_DeadLetterQueue` — passes `None`; a queue has no log stream of its own.
3. **`Util_LambdaLogging`** gains the derivation for the unmanaged default, next to `logGroupNameFor`,
   so both naming shapes stay in the one module that owns log-group naming and neither is
   reconstructed at a call site.
4. **`Monitoring.Noop`** updated to the new signature.
5. **`MonitoringTest`** — stub backends updated; add cases asserting the managed and unmanaged
   branches each deliver the locator their group actually has, and that a unit with no logs delivers
   `None`.

The locator is an `Output`, so a backend can only use it *inside* a resolution (a description, an
annotation, a tag) — never as a synchronous logical resource name. That is the same constraint §1
noted for `~component`'s fields, and it is not a limitation here: an address for a human to follow
is always resolved content, never a graph-construction-time name.

### Acceptance

- A unit on a log-group-managing stack and the same unit on an unmanaged stack each deliver a
  locator that matches the group the provider actually writes to; a unit with no logs delivers
  `None`.
- The full core build is green; `MonitoringTest` passes.

### Downstream (out of scope here — noted for sequencing only)

A monitoring extension can, once this ships and is published, put the locator into whatever its
provider carries to a human — an alert description, an annotation, a runbook link. That work lives
in the extension's own repo/plan, not here.

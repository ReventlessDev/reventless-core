# Plan: announce the owning plugin/platform to the Monitoring seam

**Date:** 2026-07-24
**Status:** Proposed.
**Repos:** `reventless-core` only.

## Why

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

## The opportunity: the ambient context already holds it

The plugin builder already publishes the owning plugin + platform for exactly this class of problem.
`Plugin_Builder.construct` calls `ResourceAttribution.enter(~platform, ~plugin=name)` around a
plugin's construction, so `ResourceAttribution.current.contents : {platform, plugin}` is populated for
every adapter that creates infrastructure below that point — which is precisely when `Monitoring.notify`
fires (the runtime backend provisions the unit inside `construct`). `AWS_Tags` already reads this same
ambient context to stamp `reventless:plugin` / `reventless:platform`.

So the seam can surface the plugin/platform **without threading a new argument through the whole
provisioning call chain** — `notify` reads the ambient context itself.

## Change

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

## Acceptance

- `onProvisioned` receives `Some(plugin)` / `Some(platform)` for a unit provisioned inside a plugin
  construct, and `None` / `None` for platform substrate provisioned outside one.
- `notify`'s call sites are unchanged; the full core build is green; `MonitoringTest` passes.

## Downstream (out of scope here — noted for sequencing only)

Consumers of the seam (any monitoring extension) can, after this ships and is published, use the new
`~plugin` to attribute their per-unit monitoring resources. That work lives in each extension's own
repo/plan, not here.

/**
Deploy-time inventory hook: every runtime backend announces the execution units
it provisions so an extension can attach provider-native monitoring to each.

No-op by default. Zero behavioral change unless an extension registers a backend
via `use` before the platform/plugin build. The seam fires once per unit at
provisioning time (inside the deploy program) — never at invocation, and it runs
no code in production. Monitoring/alerting itself is deliberately NOT a framework
concern; this only exposes the choke point through which the framework says
"I just provisioned an execution unit" and leaves what to do about it to the
listener.

See `docs/plans/done/monitoring-hook-seam.md`.
*/

/**
The ROLE of a provisioned execution unit, not its mechanism. What "failure"
means for a unit is provider-specific (a Lambda `Errors` metric vs. container
restarts vs. NATS redeliveries) and belongs in the extension's per-provider
`Backend`; core only says *that* a unit exists and *what role* it plays, which is
what keeps the contract stable across runtimes. `Other(string)` is the escape
hatch for support units and future roles (same pattern as the protocol's
`OtherKind`).
*/
type unitKind =
  | /** aggregates, state-change slices, extension points — failure = writes
       rejected/dropped (the silent-freeze class) */
  CommandHandler
  | /** state-view slices, read models — failure = silently stale reads */
  Projection
  | /** automation slices, side-effect handlers, translations — failure = missed
       side effects at boundaries */
  Reactor
  | /** cross-plugin/admin event ingestion — failure = event flow between plugins
       stops */
  EventCollector
  | /** scheduled task runners */
  Task
  | /** heartbeat/keep-alive — failure = lifecycle detection AND any staleness
       watchdog go blind (monitoring's own pulse) */
  Scheduler
  | /** receives messages that exhausted processing */
  DeadLetterSink
  | /** support units (counters, change-feed relays, migration runners, query
       resolvers, …) — providers pass their name */
  Other(string)

/**
A monitoring backend, registered by an extension (a deploy program) before the
platform builds. `onProvisioned` is called once per execution unit.

`~name` is the unit's STATIC logical name — the string the builder passed to its
provisioning call. A Pulumi-based backend derives logical resource names from it
(alarm/rule resource names must be stable and known at graph-construction time).
`~component` is the deploy-time `Adapter.resource`; its fields are `Output`s
(physical, suffix-bearing — right for a metric dimension like a CloudWatch
FunctionName or a PrometheusRule deployment selector, but unusable as a logical
resource name). Because `onProvisioned` fires during resource creation inside the
deploy program, a Pulumi-based backend can create monitoring resources in the
same stack, parented naturally.

`~plugin` / `~platform` are the OWNING plugin and platform of the unit, taken from the ambient
`ResourceAttribution` context the plugin builder publishes during construction (the same source
`AWS_Tags` uses). Both are `None` for substrate provisioned outside any plugin construct — the
correct answer for platform-scope resources. A backend that names or routes its monitoring resources
per plugin needs this: `~name` is only the component, and two plugins can own like-named components.

`~logLocator` is the provider-native address of the unit's logs — an OPAQUE string core assigns no
further meaning to (a CloudWatch log group name on one runtime, a namespace/selector on another),
and `None` for a unit with no logs of its own. It exists because an alert is only half of what an
operator needs: the notification a provider sends names the unit and the metric, never where to
read what happened. A backend cannot reconstruct the address either — where a unit's logs land can
depend on stack configuration the runtime backend resolved and did not record, so a derived guess is
wrong exactly where it differs from the default. Like `~component`'s fields this is an `Output`, so
it can only be used inside a resolution (a description, an annotation) and never as a synchronous
logical resource name — which is no limitation for an address a human is meant to follow.
*/
module type Backend = {
  let onProvisioned: (
    ~kind: unitKind,
    ~name: string,
    ~component: ReventlessInfra.Adapter.resource,
    ~plugin: option<string>,
    ~platform: option<string>,
    ~logLocator: option<Pulumi.Output.t<string>>,
  ) => unit
}

/** Default backend: does nothing. Active unless an extension calls `use`. */
module Noop: Backend = {
  let onProvisioned = (
    ~kind as _,
    ~name as _,
    ~component as _,
    ~plugin as _,
    ~platform as _,
    ~logLocator as _,
  ) => ()
}

let backend: ref<module(Backend)> = ref(module(Noop: Backend))

/** Whether `use` has run. Distinguishes "nobody is listening yet" — which is
    what the buffer below exists for — from "a backend that deliberately does
    nothing with this unit", which is the backend's decision to make, not ours. */
let registered = ref(false)

/**
An announcement made before any backend was registered, held until one is.

"Before the build" is not early enough for every provisioning site. A module that
creates its resources at import time announces them while the deploy program's own
body — including its `use` call — has not started running, because an imported
module is evaluated to completion first. The dead-letter sink is such a site, and
it was the one execution unit in a monitored estate that no alarm ever covered:
not because a backend declined to handle its kind, but because it was told at a
moment when the answer to "who is listening" was permanently no one.

Buffering makes the seam insensitive to that ordering. What a backend sees is the
same set of units in the same order; only the moment it hears about the early ones
moves, to the first instant there is anybody to hear it.
*/
type announcement = {
  kind: unitKind,
  name: string,
  component: ReventlessInfra.Adapter.resource,
  plugin: option<string>,
  platform: option<string>,
  logLocator: option<Pulumi.Output.t<string>>,
}

let pending: ref<array<announcement>> = ref([])

let deliver = (module(B: Backend), a: announcement) =>
  B.onProvisioned(
    ~kind=a.kind,
    ~name=a.name,
    ~component=a.component,
    ~plugin=a.plugin,
    ~platform=a.platform,
    ~logLocator=a.logLocator,
  )

/**
Register the monitoring backend. Must run before the platform/plugin build in the
deploy program (plain statement order — the registry is consulted lazily at each
provisioning site). Called once, by the extension, first.

Announcements from sites that ran at import time — before any statement of the
deploy program — are replayed here, in the order they were made, and the buffer is
drained so a second registration does not receive them twice.
*/
let use = (b: module(Backend)) => {
  backend := b
  registered := true
  let replay = pending.contents
  pending := []
  replay->Array.forEach(a => deliver(b, a))
}

/** Restores the registry to its initial state: no backend, nothing buffered.

    A deploy program never needs this — it registers once and runs once. Tests do,
    because the registry and the buffer are module state that outlives a single
    case, and `use(Noop)` is a *registration* rather than an undo: it would leave
    later announcements delivered-and-dropped instead of held. */
let reset = () => {
  backend := module(Noop: Backend)
  registered := false
  pending := []
}

/**
Announce a provisioned execution unit to the registered backend. Called by
runtime backends at their provisioning sites (once per unit).

Held until an extension registers a backend, rather than dropped — see
`announcement` above for why that distinction decides whether a unit provisioned
at import time is ever monitored.
*/
let notify = (
  ~kind: unitKind,
  ~name: string,
  ~component: ReventlessInfra.Adapter.resource,
  ~logLocator: option<Pulumi.Output.t<string>>=?,
) => {
  // The owning plugin/platform come from the ambient context the plugin builder publishes
  // (ResourceAttribution.enter) — populated exactly when this fires, so the call sites need not
  // thread the names. `None` outside a plugin construct (platform substrate).
  //
  // Read here rather than at delivery, because a buffered announcement is replayed from a deploy
  // program's body, where the ambient context is whatever the *next* construct left behind. The
  // owner belongs to the moment the unit was provisioned.
  let {ResourceAttribution.plugin: plugin, platform} = ResourceAttribution.current.contents
  // `~logLocator`, unlike the owner, is NOT ambient: only the provisioning site knows where it
  // pointed the unit's logs. So it is passed, and optional — a call site with nothing to say omits
  // it rather than being forced to invent an address.
  let announcement = {kind, name, component, plugin, platform, logLocator}
  if registered.contents {
    deliver(backend.contents, announcement)
  } else {
    pending := pending.contents->Array.concat([announcement])
  }
}

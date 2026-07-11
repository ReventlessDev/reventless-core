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

See `docs/plans/monitoring-hook-seam.md`.
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
*/
module type Backend = {
  let onProvisioned: (
    ~kind: unitKind,
    ~name: string,
    ~component: ReventlessInfra.Adapter.resource,
  ) => unit
}

/** Default backend: does nothing. Active unless an extension calls `use`. */
module Noop: Backend = {
  let onProvisioned = (~kind as _, ~name as _, ~component as _) => ()
}

let backend: ref<module(Backend)> = ref(module(Noop: Backend))

/**
Register the monitoring backend. Must run before the platform/plugin build in the
deploy program (plain statement order — the registry is consulted lazily at each
provisioning site). Called once, by the extension, first.
*/
let use = (b: module(Backend)) => backend := b

/**
Announce a provisioned execution unit to the registered backend. Called by
runtime backends at their provisioning sites (once per unit). No-op until an
extension registers a backend.
*/
let notify = (
  ~kind: unitKind,
  ~name: string,
  ~component: ReventlessInfra.Adapter.resource,
) => {
  module B = unpack(backend.contents)
  B.onProvisioned(~kind, ~name, ~component)
}

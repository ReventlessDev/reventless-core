/**
Deploy-time hook: every event log announces itself as it is provisioned, so an
extension can attach behaviour to it inside the program that owns it.

No-op by default. Zero behavioral change unless an extension registers a backend
via `use` before the platform/plugin build. The seam fires once per log at
provisioning time (inside the deploy program) — never at invocation, and it runs
no code in production.

What a backend does with a log is deliberately NOT a framework concern.
Aggregation, CDC export, external indexing, replication and archival all want to
react to an event log's changes; none of them belong in core, and each one added
to core is maintenance its users pay for whether or not they use it. This only
exposes the choke point through which the framework says "I just provisioned an
event log, here is everything I know about it" and leaves the reaction to the
listener.

The alternative — discovering a log's resources from outside the owning program —
is impractical on AWS: a DynamoDB stream ARN ends in a creation-time stream
label, so it cannot be synthesised, and exporting it per plugin pushes framework
internals into every deployment's stack outputs.

See `docs/plans/done/event-log-provisioned-seam.md`.
*/

/**
Which event-log family provisioned the log. The two differ in what a reader finds
on the wire — a classic log is per-aggregate and its rows carry an aggregate id;
a DCB log is per-plugin and its rows carry tags — so a backend that decodes
records needs to know which it is looking at before it looks.
*/
type logStyle =
  | /** per-aggregate log behind `EventLog_Builder` */ Classic
  | /** per-plugin tagged log behind `DcbEventLog_Builder` */ Dcb

/**
An event-log backend, registered by an extension (a deploy program) before the
platform builds. `onProvisioned` is called once per event log.

`~name` is the log's STATIC logical name — the suffixed component name the
builder passed to its storage maker (`ProductEventLog`, `CatalogDcbEventLog`). A
Pulumi-based backend derives logical resource names from it, which must be stable
and known at graph-construction time.

`~owner` is the model element the log belongs to: `{kind: Aggregate, name:
"Product"}` for a classic log, `{kind: Plugin, name: "Catalog"}` for a DCB log
(the plugin owns it, not any one slice). `~plugin` / `~platform` come from the
ambient `ResourceAttribution` context the plugin builder publishes during
construction — the same source `AWS_Tags` and `Monitoring.notify` use. Both are
`None` for a log provisioned outside any plugin construct.

`~resources` is the adapter's deploy-time resources, not a stream: a stream is a
DynamoDB-shaped idea and SQL-backed adapters have none. A backend derives
whatever its store supports and does nothing for the rest — a Postgres log
arrives with `resources: []`, and an in-memory one with nothing attachable. The
contract is uniform on purpose; filtering belongs in the backend.

`~opts` carries the log component's parent options. A backend that provisions
anything needs them, or its resources land outside the component tree.

Because `onProvisioned` fires during resource creation inside the deploy program,
a Pulumi-based backend can create its resources in the same stack, parented
naturally.

**The reader budget.** A DynamoDB table has exactly one stream, and DynamoDB
Streams throttles beyond two processes reading the same shard. Core already
spends one slot: `EventCollectorChannel_Helpers` maps every event-log stream onto
the plugin's event-collector Lambda. A backend that subscribes through this seam
is therefore reader #2 — the ceiling. A second stream consumer would throttle the
first, which is why registration is single-slot and loud (see `use`). If several
consumers are ever needed the answer is a fan-out — routing through the existing
collector, or a stream type that supports more readers — not more subscriptions.

**Snapshots share the log's table.** Classic aggregate snapshots are written to
the event-log table under `position = "SNAPSHOT"`, so a stream consumer sees them
alongside events. The seam does not filter; a backend that only wants events must
skip those rows itself.

**No ordering guarantee against other seams.** This and `Monitoring.notify` both
fire during provisioning, from different builders, in whatever order the graph is
constructed. A backend must not depend on having seen one before the other.
*/
module type Backend = {
  let onProvisioned: (
    ~logStyle: logStyle,
    ~name: string,
    ~owner: option<ResourceAttribution.owner>,
    ~plugin: option<string>,
    ~platform: option<string>,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => unit
}

/** Default backend: does nothing. Active unless an extension calls `use`. */
module Noop: Backend = {
  let onProvisioned = (
    ~logStyle as _,
    ~name as _,
    ~owner as _,
    ~plugin as _,
    ~platform as _,
    ~resources as _,
    ~opts as _,
  ) => ()
}

let backend: ref<module(Backend)> = ref(module(Noop: Backend))
let registered = ref(false)

/**
Register the event-log backend. Must run before the platform/plugin build in the
deploy program (plain statement order — the registry is consulted lazily at each
provisioning site). Called once, by the extension, first.

Single-slot and loud: a second `use` raises rather than silently winning, because
the reader budget documented on `Backend` means two registered backends is not a
last-writer-wins configuration question but two consumers competing for one
stream slot — a defect that otherwise surfaces in production as iterator-age
alarms on whichever one lost. `reset` clears the slot for tests.
*/
let use = (b: module(Backend)) => {
  if registered.contents {
    JsError.throwWithMessage(
      "EventLogProvisioning.use called twice: only one event-log backend can be registered. " ++
      "A DynamoDB stream supports two readers per shard and core's event collector already holds one, " ++
      "so a second backend would throttle the first. Compose the two backends into one, or fan out " ++
      "behind a single registration.",
    )
  }
  registered := true
  backend := b
}

/**
Restore the default `Noop` backend and clear the registration slot. Test-support
only — deploy programs never call this.
*/
let reset = () => {
  backend := module(Noop: Backend)
  registered := false
}

/**
Announce a provisioned event log to the registered backend. Called by the
`EventLog` and `DcbEventLog` builders at their storage-provisioning sites (once
per log). Firing from the builders rather than from each storage adapter is what
makes the contract uniform: every adapter — DynamoDB, Postgres, SQLite,
in-memory, and any future one — is covered by construction, with nothing to
remember when a new one is written. No-op until an extension registers a backend.
*/
let notify = (
  ~logStyle: logStyle,
  ~name: string,
  ~owner: option<ResourceAttribution.owner>,
  ~resources: array<ReventlessInfra.Adapter.resource>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => {
  module B = unpack(backend.contents)
  // The owning plugin/platform come from the ambient context the plugin builder publishes
  // (ResourceAttribution.enter) — populated exactly when this fires, so the call sites need not
  // thread the names. `None` outside a plugin construct.
  let {ResourceAttribution.plugin: plugin, platform} = ResourceAttribution.current.contents
  B.onProvisioned(~logStyle, ~name, ~owner, ~plugin, ~platform, ~resources, ~opts)
}

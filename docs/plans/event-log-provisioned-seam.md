# Plan: An event-log provisioning seam for out-of-tree consumers

**Status.** Planned — 2026-08-07. Grounded against current adapter code; anchors in the
appendix.

**Goal.** Let a package outside the framework attach behaviour to an event log **at the moment
it is provisioned**, inside the program that owns it — most importantly, a consumer of the
log's change stream — without core knowing or caring what that behaviour is.

**Non-goal.** Any particular consumer. This plan adds an extension point and nothing that uses
it.

---

## 1. Why this is needed

Anything that wants to react to an event log's changes today has exactly two options, and both
are wrong:

1. **Build it into core.** Fine for things the framework owns (event collection, topic
   publishing); wrong for everything else — aggregation, CDC export, external indexing,
   replication, archival. None of those belong in the framework, and each one added to core is
   a feature its users pay for in maintenance whether or not they use it.
2. **Discover the log's resources from outside the owning program.** Impractical on AWS: a
   DynamoDB stream ARN ends in a creation-time stream label, so it cannot be synthesised; the
   general-purpose lookup requires a data-source binding that does not exist in every consumer;
   and exporting the ARN per plugin is a per-adapter change that pushes framework internals
   into every deployment's stack outputs.

The result is that today, "react to an event log" means "modify core". That is the gap.

**The framework already solved this shape once.** `Monitoring` (`Monitoring.res:68-107`) is a
`module type Backend` with a `Noop` default, a `use` registration, and a `notify` fired once per
provisioned execution unit, enriched from `ResourceAttribution.current`. An out-of-tree package
registers a backend and reacts; a deployment that registers nothing pays nothing. This plan
applies that pattern to event-log storage.

---

## 2. The seam

Mirroring `Monitoring`:

```rescript
module type Backend = {
  let onProvisioned: (
    ~logStyle: logStyle,          // Dcb | Classic
    ~name: string,                // the log's identity
    ~component: string,
    ~plugin: string,
    ~platform: string,
    ~resources: array<ReventlessInfra.Adapter.resource>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => unit
}

module Noop: Backend
let backend: ref<module(Backend)>
let use: module(Backend) => unit
```

Fired from **both** storage families as the log is created — `DcbEventLogStorage_*` and
`EventLogStorage_*` — so a backend sees every log regardless of style or store.

Design notes:

- **Pass the resources, not a stream.** A stream is a DynamoDB-shaped idea; SQL-backed adapters
  have none. The seam hands over the adapter's resources and its attribution, and the backend
  derives whatever its store supports. A backend that only implements a DynamoDB arm simply
  does nothing for a Postgres log.
- **Pass `~opts` too.** A backend that provisions anything needs the parent options, or its
  resources land outside the component tree.
- **Attribution from `ResourceAttribution.current`**, exactly as `Monitoring.notify` does — the
  backend must not have to re-derive plugin/platform.
- **`Noop` by default.** Zero cost, zero behaviour change for any deployment that registers
  nothing. This is what makes the extension free for framework users who do not want it.

---

## 3. Unconditional streams on classic event-log tables

The seam is only useful for classic logs if there is something to attach to, and today that
depends on which adapter a deployment happens to wire:

- `EventLogStorage_DynamoDbStream.res:3-10` uses `Util.DynamoDbStream.makeTable`
  (`NEW_IMAGE`) — stream on.
- `EventLogStorage_DynamoDb.res:3-6` uses `Util.DynamoDb.makeTable` — **no stream at all**.

DCB logs have no such split: `DcbEventLogStorage_DynamoDb.res:53-59` always streams.

**Make the stream unconditional on classic tables too.** A DynamoDB stream costs nothing until
it is consumed, and the current split is a silent capability difference between two adapters
that otherwise present the same port. Part of this plan, because without it the seam works for
one log style and not the other.

---

## 4. The constraint every consumer inherits: the reader budget

DynamoDB Streams throttles beyond **two processes reading the same shard**, and a table has
exactly one stream.

**Core already spends one.** `EventCollectorChannel_Helpers.res:262-273` maps an array of
stream resources onto a single Lambda, so every event-log stream already has a consumer. A
backend attaching through this seam is **reader #2 — the ceiling.** A second out-of-tree
consumer would throttle the first.

Consequences for this plan:

- **Document the budget at the seam.** A backend author must know they are taking the last slot,
  not discover it in production through iterator-age alarms.
- **Consider whether the seam should enforce single-registration.** `Monitoring.backend` is a
  single `ref`, so it already has last-writer-wins semantics; making that explicit (and loud)
  is cheaper than debugging two silently-competing consumers. See open questions.
- If demand for multiple stream consumers ever materialises, the answer is not more readers but
  a fan-out — either routing through the existing collector, or a Kinesis-style stream that
  supports more consumers. Out of scope here; noted so the seam is not blamed later for a limit
  it did not create.

---

## 5. Open questions

1. **Naming.** `EventLogObserver`? `EventLogProvisioning`? It should not imply *what* the
   backend does — the Monitoring seam's neutrality is the model.
2. **One backend or several.** A single `ref` matches `Monitoring` and the reader budget;
   an array is more general and more dangerous. Recommend single, with a loud error on double
   registration.
3. **Does the seam fire for in-memory storage?** Consistency says yes; there is nothing useful
   to attach. Firing uniformly and letting backends ignore what they cannot use is simpler than
   a partial contract.
4. **Snapshot and fence writes.** Classic aggregate snapshots share the log's table under
   `position = "SNAPSHOT"` (`EventLogStorage_DynamoDb_Runtime.res:73-80`), so any stream
   consumer sees them. The seam does not filter — but the fact belongs in its documentation, or
   every backend rediscovers it.
5. **Ordering relative to `Monitoring.notify`.** Both fire during provisioning; if a backend
   ever needs both, an undefined order is a latent bug.

---

## 6. Acceptance

- A package outside this repo can register a backend, receive a callback for every event log as
  it is provisioned, and provision its own resources inside the owning program — with no change
  to core beyond registration.
- The callback fires for both log styles and all storage adapters, carrying attribution and the
  adapter's resources.
- A deployment registering no backend behaves exactly as before, provisions nothing extra, and
  costs nothing extra.
- Classic event-log tables stream unconditionally.
- The two-readers-per-shard budget, and the fact that core's event collector already holds one
  slot, are documented at the seam.

---

## Appendix: code anchors (verified 2026-08-07)

| Fact | Anchor |
| --- | --- |
| Seam pattern to mirror (`Backend` / `Noop` / `use` / `notify`) | `reventless/core/src/adapter/Monitoring/Monitoring.res:68-107` |
| DCB tables always stream (`NEW_IMAGE`) | `DcbEventLogStorage_DynamoDb.res:53-59` |
| Classic streams only in one of two adapters | `EventLogStorage_DynamoDb.res:3-6` vs `EventLogStorage_DynamoDbStream.res:3-10` |
| Snapshot rows share the log table | `EventLogStorage_DynamoDb_Runtime.res:73-80` |
| Stream fan-in precedent; core is already reader #1 | `EventCollectorChannel_Helpers.res:262-273` |
| ESM primitive a backend would use | `Util_EventSourceMapping.subscribe` |

External limits (AWS docs, checked 2026-08-07): ≤2 readers per stream shard before throttling;
one stream per table; Lambda processes one shard per instance (`ParallelizationFactor` ≤ 10);
no documented quota on event source mappings per function.
</content>

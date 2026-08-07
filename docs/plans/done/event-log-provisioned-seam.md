# Plan: An event-log provisioning seam for out-of-tree consumers

**Status.** Done — 2026-08-07. Shipped as `ReventlessCore.EventLogProvisioning`. §5 records the
decisions taken on what were open questions; §6 checks off acceptance; §7 lists the three
deviations from the plan as written. Sections 1–4 are left as written, so where §2's signature
sketch and §3's premise differ from what shipped, §7 is the record.

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

> **As shipped**, two details differ from this sketch: `~component: string` became
> `~owner: option<ResourceAttribution.owner>`, and the call sites are the two core builders
> rather than each storage family — same coverage, fewer places to remember. The authoritative
> signature is in `EventLogProvisioning.res`; the reasoning is in §7.

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

> **As shipped**, the premise above was wrong in one respect: the non-streaming adapter had no
> callers at all, so this was dead divergent code rather than a live split. The goal stands and
> is met — classic tables stream unconditionally — but by deletion, not by editing. See §7.

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
- **The seam enforces single-registration.** `Monitoring.backend` is a single `ref`, so it
  already has last-writer-wins semantics; making that explicit (and loud) is cheaper than
  debugging two silently-competing consumers. Decided in §5.2 — `use` raises on a second
  registration.
- If demand for multiple stream consumers ever materialises, the answer is not more readers but
  a fan-out — either routing through the existing collector, or a Kinesis-style stream that
  supports more consumers. Out of scope here; noted so the seam is not blamed later for a limit
  it did not create.

---

## 5. Decisions (raised as open questions; all resolved before implementation)

1. **Naming — `EventLogProvisioning`.** The question was what to call a seam that must not imply
   *what* the backend does, with the Monitoring seam's neutrality as the model. Chosen for naming
   the moment rather than the reaction, following `DeployBootstrap`'s noun-phrase style;
   `EventLogObserver` was rejected as implying the backend only watches, when it may provision.
2. **One backend, and loud.** A single `ref` matches `Monitoring` and the reader budget; an array
   is more general and more dangerous. Resolved further than "recommend single": `use` **raises**
   on a second registration rather than last-writer-wins, because under §4's budget two
   registered backends is not a configuration question but two consumers competing for one stream
   slot. `reset` clears the slot for tests.
3. **The seam fires for in-memory storage — uniformly, for every adapter.** Consistency said yes
   even though there is nothing useful to attach. Firing from the builders (§7) made this
   automatic rather than a rule to enforce per adapter: a Postgres or in-memory log arrives with
   `resources: []`, and a backend that only implements a provider arm ignores it. A partial
   contract was never built.
4. **Snapshot and fence writes are documented, not filtered.** Classic aggregate snapshots share
   the log's table under `position = "SNAPSHOT"`
   (`EventLogStorage_DynamoDb_Runtime.res:73-80`), so any stream consumer sees them. Stated on
   `Backend` so a backend that only wants events skips those rows knowingly instead of
   rediscovering the fact.
5. **No ordering guarantee against `Monitoring.notify` — made explicit.** Both fire during
   provisioning, from different builders, in graph-construction order. Rather than invent an
   ordering nothing needs yet, the doc comment states that a backend must not depend on having
   seen one before the other. An undefined order that is documented is a contract; the latent bug
   was the undefined order that was *not*.

---

## 6. Acceptance — all met

- ✅ A package outside this repo can register a backend, receive a callback for every event log as
  it is provisioned, and provision its own resources inside the owning program — with no change
  to core beyond registration. `use` + `Backend.onProvisioned`, which carries `~opts` so the
  backend's resources parent into the component tree.
- ✅ The callback fires for both log styles and all storage adapters, carrying attribution and the
  adapter's resources. Guaranteed by construction — the two builders are the only path to a log
  (§7) — and exercised end-to-end for both styles in `EventLogProvisioningSeamTest`.
- ✅ A deployment registering no backend behaves exactly as before, provisions nothing extra, and
  costs nothing extra. `Noop` is the default; the full suite (307 suites) passes unchanged, with
  no resource-graph difference.
- ✅ Classic event-log tables stream unconditionally — via §7's third deviation.
- ✅ The two-readers-per-shard budget, and the fact that core's event collector already holds one
  slot, are documented at the seam — on `Backend`, and enforced by §5.2's single-slot `use`.

---

## 7. Outcome

Shipped as `reventless/core/src/adapter/EventLogProvisioning/EventLogProvisioning.res` —
`module type Backend` / `Noop` / `use` / `reset` / `notify`, mirroring `Monitoring`.

The five questions §5 raised were all decided before implementation; §5 records each decision
with its rationale.

### Deviations from the plan as written

- **Fired from the two core builders, not from each storage adapter.** `EventLog_Builder` and
  `DcbEventLog_Builder` already hold `name`, `owner`, `opts` and `storage.resources` at the
  `Storage.make` call. Two call sites there cover every adapter — AWS DynamoDB and Postgres,
  local SQLite/Postgres/in-memory, the mocks — where §2's per-family approach would have meant
  ~10 sites and a new one to remember for every future adapter. Same seam, uniform by
  construction.
- **`~owner: option<ResourceAttribution.owner>` replaces §2's `~component: string`.** A bare
  string next to `~name` was ambiguous and dropped the kind; `owner` is the framework's existing
  vocabulary and carries both. Classic logs pass the aggregate (`{kind: Aggregate, name:
  "Product"}`), DCB logs the owning plugin.
- **§3 was a dead adapter, not a live split.** `EventLogStorage_DynamoDb.res` (non-streaming)
  had zero callers: all three classic aggregate builders wire `DynamoDbStream`, and `Selectable`
  routes to `DynamoDbStream` or Postgres. Rather than edit it into a byte-identical twin of the
  streaming adapter, it was deleted and `EventLogStorage.DynamoDb` aliased to
  `EventLogStorage_DynamoDbStream` — classic tables now stream unconditionally, and out-of-tree
  references to the exported name keep compiling. No live deployment changes behaviour.

### Verification

- `reventless/core/tests/adapter/EventLogProvisioningTest.res` — registry contract: `Noop`
  silence, forwarding of style/name/owner/resources, ambient attribution in and out of a
  construct scope, uniform firing for a resource-less log, and the single-slot throw.
- `reventless/local/tests/components/eventlog/EventLogProvisioningSeamTest.res` — end-to-end
  through the real builders: a backend registered before the build sees both log styles with the
  right owner and plugin attribution, and construction is unaffected.
- Full suite green (307 suites); root build clean of warnings; `check:outputs` and
  `test:projects` pass.

---

## Appendix: code anchors (verified 2026-08-07)

| Fact | Anchor |
| --- | --- |
| Seam pattern to mirror (`Backend` / `Noop` / `use` / `notify`) | `reventless/core/src/adapter/Monitoring/Monitoring.res:68-107` |
| DCB tables always stream (`NEW_IMAGE`) | `DcbEventLogStorage_DynamoDb.res:53-59` |
| Classic streams only in one of two adapters | `EventLogStorage_DynamoDb.res:3-6` (deleted by §7) vs `EventLogStorage_DynamoDbStream.res:3-10` |
| Snapshot rows share the log table | `EventLogStorage_DynamoDb_Runtime.res:73-80` |
| Stream fan-in precedent; core is already reader #1 | `EventCollectorChannel_Helpers.res:262-273` |
| ESM primitive a backend would use | `Util_EventSourceMapping.subscribe` |

External limits (AWS docs, checked 2026-08-07): ≤2 readers per stream shard before throttling;
one stream per table; Lambda processes one shard per instance (`ParallelizationFactor` ≤ 10);
no documented quota on event source mappings per function.
</content>

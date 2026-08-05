# Plan: carry state in the live-update protocol

**Status:** Done — all six work items shipped.

**Related:** `LocalStateChangeDescriptor` (local), `StateTopic_AppSync_Ops`
(deployed), `StateTopicPublish.mjs` (Postgres read models),
`QueryDbStorage_Sqlite` / `QueryDbStorage_InMemory` publish sites.

**Outcome notes** — where the implementation departed from this plan, and why:

- **Three publish sites, not two.** Postgres read models have no change stream, so
  the projection Lambda publishes the descriptor itself (`StateTopicPublish.mjs`).
  It is the same wire format and moved with the other two.
- **The sequence is monotonic, not dense.** Work item 4 assumed a gap could be made
  detectable. It cannot on the DynamoDB relay without maintaining a version on every
  read-model row — the relay is stateless per stream record and the write path is
  PutItem/BatchWriteItem, which cannot increment. `seq` is therefore an ordering
  token: it detects a stale or reordered frame, not a missing one. The full cost of
  the dense alternative, and what it would have bought, is in
  `docs/analysis/live-update-descriptor-sequencing.md`.
- **One pre-existing divergence closed.** The relay used to emit `sortKeyValue` on a
  REMOVE, which neither other publisher could produce. It now omits it, so the
  parity test covers deletes too.
- **No shared descriptor module.** Promoting the builder into core would remove two
  of the three implementations, but the relay's `_Ops` module is deliberately
  Pulumi-free and a core import risks pulling deploy-time code into its Lambda
  graph. `StateChangeDescriptorParityTest` is the guard instead.

---

## Goal

A live update currently tells a client **that** a row changed, never **what** it
changed to. Every subscriber therefore refetches to learn a value the platform
already had in hand — one round-trip per change, per client.

Carry the row's new state in the notification so a client can update its view without
refetching, while keeping the channel's current lossy-tolerant semantics.

## Why this is cheap to do

The data is already at both publish sites and is deliberately discarded:

| Path | Already has | Currently emits |
|---|---|---|
| Local | `publishSaved(~state=Some(state))` — the full new row | `{changeKind, id, sortKeyValue?}` |
| AWS | DynamoDB stream provisioned `NEW_AND_OLD_IMAGES`; the relay Lambda reads `NewImage` | the same descriptor |

So no table, stream or transport change is needed. `makeStateChangeDescriptor` uses
the state it is given only to extract `sortKeyValue`, and the relay unmarshals
`NewImage` only to derive the entity key. Both then drop the row.

The AWS stream being `NEW_AND_OLD_IMAGES` (not `NEW_IMAGE`) also means a genuine
old-vs-new diff is available on the deployed path without a provisioning change —
relevant to the "changed fields only" variant below, not to the first step.

---

## What changes

**Carry the full new row, not a field-level diff.**

- The projection returns the *resulting state*, not a delta — `Update(id, state => {...state, imageUrl})`. A true field diff means comparing old and new: free on AWS (`OldImage` is already streamed), extra work locally, where the previous row is read only to decide `Added` vs `Updated`.
- A full row is one shape for every `changeKind`, so a client has one code path rather than "patch if fields present, else refetch".
- Field-level deltas can layer on later **on top of sequencing**, if payload size turns out to be the binding constraint. Do not start there.

**Keep the payload advisory.** A client may always ignore the state and refetch. This
is what preserves the property the current protocol has for free: the channel is
best-effort, so a dropped or reordered message costs staleness until the next fetch,
never permanent corruption. A protocol that *requires* the payload to be applied is a
protocol that must be lossless, which this one is not.

**Add a sequence number.** `position` is already noted as *"omitted (Phase 3
deferred)"* in `LocalBus`. Without it a client cannot tell "I have every change for
this entity" from "I missed one", which is exactly the distinction that makes applying
a payload safe. With it, a gap is detectable and the client falls back to a refetch —
the self-healing path stays reachable rather than being replaced.

---

## Authorization

**Component-scoped, so this is a check rather than a blocker.**
`Authorization.permission` is `AllowGroups | AllowAuthenticated | AllowAnonymous |
DenyAll`, evaluated per component. There is no row-level or field-level rule anywhere
in the framework, so a subscriber authorized for a read model can already query every
row in it — receiving one over that read model's channel discloses nothing new.

Two things to confirm before relying on that:

1. **Index-level group gating.** `ReadModel.indexConfig` carries an optional
   `authorization {tableName, group}` for AppSync. If a deployment uses it to expose a
   *subset* of a table to a group through an index, then "authorized for the component"
   is coarser than "authorized for these rows", and pushing rows over one channel would
   widen it. Establish whether any real deployment does this; if so, gate the payload
   on the component having no index-scoped authorization.
2. **Subscribe-time authorization must be at least as strict as query-time** on both
   transports — AppSync Events channels on the deployed path, the yoga PubSub /
   `/default/{name}/{id}` Events channels locally. The descriptor being metadata has
   made this cheap to under-enforce so far; carrying state makes it load-bearing.
   (Related: the below-root auth granularity follow-up in the merged-API work.)

**Local dev caveat:** the in-memory auth path resolves a no-header request to
`defaultUser`. That is fine for a metadata channel and stays fine for a data channel
only because local dev is not a security boundary — worth stating in the docs rather
than discovering.

---

## What a payload still cannot answer

**List membership.** For a list or card view the question is not only "what changed"
but "does this row still belong on my page, and where". A changed filter field can
move a row out of a filtered view; a changed sort field can move its position.
`sortKeyValue` is already in the descriptor for this reason and is not sufficient on
its own.

So the client contract is: **apply the payload to rows you already hold; refetch when
membership may have changed.** The protocol should not pretend to solve pagination —
attempting to would push filter evaluation into the publisher, which does not know any
subscriber's query.

**Offloaded fields.** An `@offload` field travels as a reference, so a client still
resolves it separately. Rows dominated by offloaded content save less than the
round-trip count suggests.

**Payload size.** AppSync subscription payloads are capped (~240 KB). A row near the
limit must degrade to the metadata-only descriptor rather than fail to publish —
another reason the payload is advisory, and a reason the publisher needs a size check
with a logged downgrade rather than a silent drop.

---

## Work items

1. **Descriptor v2, shared shape.** Extend the descriptor with an optional `state` and
   a `position`. Optional, so an old client ignores them and a new client tolerates
   their absence — no version negotiation, no flag day.
2. **Local publish sites.** `makeStateChangeDescriptor` carries the state it is already
   given; `QueryDbStorage_Sqlite` / `_InMemory` supply the sequence.
3. **AWS relay.** `StateTopic_AppSync_Ops` publishes the unmarshalled `NewImage` it
   already reads, with the size check and metadata-only downgrade.
4. **Sequencing.** Decide the counter's scope — per entity is the useful unit for gap
   detection; per read model is simpler but makes every subscriber see gaps that are
   not theirs. This is the one genuinely new mechanism and should be settled first.
5. **Parity test.** The local descriptor and the relay's must be asserted identical for
   the same logical change; they are two implementations of one wire format and have
   no shared code today.
6. **Docs.** The client contract — apply to held rows, refetch on possible membership
   change, refetch on a sequence gap — belongs somewhere a UI author will find it.

## Rollout

Additive and backward-compatible: consumers that ignore the new fields keep working,
so local and AWS need not move together, and no client is forced to adopt it. Ship
local first (fast to verify against the hybrid example), then the relay.

## Risks

**The payload becomes load-bearing by accident.** Once clients apply state, a client
that skips the sequence check works fine in testing and corrupts silently under load
or reconnection. The mitigation is the docs and the gap-detection contract, and it is
worth stating that the framework cannot enforce it.

**Two implementations of one wire format drift.** Local builds the descriptor in
ReScript from a projection write; AWS builds it in a Lambda from a stream record. They
already drift-risk on `changeKind`; adding a payload widens the surface. Hence the
parity test as a work item rather than a nicety.

**Diff-shaped expectations.** "Only the changed fields" is the intuitive ask, and
shipping full rows will read as a partial answer. Worth writing down that the diff is
deliberately deferred behind sequencing, so it is not re-litigated as an oversight.

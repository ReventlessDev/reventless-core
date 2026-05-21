# Reconnect Replay: Recovering State Changes Missed While Disconnected

## Problem Statement

A browser tab subscribed to Reventless live updates (AppSync Events Source B
descriptors) currently loses any state changes that occur while its WebSocket
is not connected. The connection can drop for many reasons:

- Laptop sleeps / lid closes.
- Tab is backgrounded long enough for the browser to suspend the socket.
- Network blips (Wi-Fi roam, VPN reconnect, captive portal).
- AppSync idle close (`idleDisposeDelayMs = 30s` in `LiveConnection` —
  the *client* tears the socket down after 30s with no subscribers; AppSync
  itself also enforces an idle timeout).
- `EventsClient.backoffDelay` ramps reconnect attempts to 1s → 2s → 4s → 8s →
  16s → 30s, so a reconnect can be a long way off.

When the socket re-opens, `EventsClient.resubscribeAll` re-sends `subscribe`
frames on the same channels. AppSync Events accepts the subscriptions and
delivers descriptors from that point forward — there is no "send me what I
missed" semantic in the protocol and no replay buffer on the server. The gap
between the last `data` frame the client received and the first one after
reconnect is silently lost.

The UI's compensating behaviour today:

| View | What it does on reconnect | Outcome |
|------|---------------------------|---------|
| `AutoListView` | Surfaces a "Reconnecting…" pill via `connectionReconnecting`; once `Open`, just keeps listening | List can be stale; user only finds out by clicking around or full-page reload |
| `AutoDrillDetail` | Same | Detail can be stale; no entity-gone latch fires if the entity was deleted during the gap |
| Self-change tracker | Entries TTL at 60s | A command fired right before disconnect can be marked self-change but its `Added` descriptor lands after the TTL → row shows up via the "new items" pill instead of auto-inserting |

There is also no signal that a gap occurred — the user's view diverges silently
from the server's QueryDb state.

The realtime-change-descriptors plan calls out the gap conceptually
(§3 "DCB position exposure", §4 "BulkInvalidated") but both phases are
deferred. The descriptor today carries no `position` and there is no per-
channel high-water mark on either end.

## Goal

When a subscriber reconnects, deliver — or trigger refetch of — the set of
changes that happened on its subscribed channels during the gap, with bounded
latency and bounded server cost, and without requiring every projection to
grow new infrastructure.

"Deliver" can mean either:

1. **Replay** — push the actual missed descriptors so the existing
   `handleDescriptor` reducer applies them in order (just like normal live
   delivery).
2. **Invalidate** — push a single "everything in scope X is stale, refetch"
   signal so the client refetches the page/entity from the QueryDb (which
   already reflects the missed state).

Option 2 is much cheaper to implement and is what most read-model UIs
actually need (the list/detail views are stateless reducers over the
QueryDb's current row state, not over the descriptor stream).

## Why the Current Architecture Doesn't Support Replay

The publish path is

```
QueryDb DynamoDB Stream → StateTopic_AppSync Lambda → AppSync Events HTTP publish → fan-out
```

Three properties of this pipeline kill naive replay:

1. **AppSync Events is fire-and-forget pub/sub.** A subscriber connected at
   time T sees publishes from T onward. There is no
   `subscribe(channel, since=<token>)` operation, no server-side per-client
   buffer, no Kafka-style consumer offset. Lambda → API call → fan-out is
   one-way and stateless.

2. **DynamoDB Streams have a 24-hour TTL, are per-shard ordered (not per
   row), and are addressed by `SequenceNumber`** — a shard-local opaque
   string. There is no global "position" the client could resume from, and
   even the per-shard sequence isn't exposed to the projector handler today
   (see realtime-change-descriptors §3 — position plumbing is deferred).

3. **Descriptors carry only `{changeKind, id, sortKeyValue?}`.** They are
   intentionally small; they are not events. Replaying a descriptor is only
   meaningful as a hint to refetch — the actual state lives in the QueryDb
   row, which the client must re-read anyway. So "send me everything I
   missed" reduces to "tell me which entity ids were touched."

The conclusion: a full event-replay channel would require either
(a) the position-on-row work from realtime-change-descriptors Phase 3 plus a
deduped resumable feed, or (b) leaning on the DCB EventLog as the resume
source (the `pullEvents` query in `reventless-client-transport.md` — but
that returns *events*, not descriptors, and only DCB plugins have a global
position).

So the practical answer for the QueryDb live-update path is **descriptor-
replay scoped by what the subscriber asked for**, not "full history forever."

## Design Options

The options below trade off cost, latency, completeness, and how much
deferred infrastructure (positions, namespace handlers) they unlock.

### Option A — Refetch-on-reconnect (zero-infra fallback)

**What.** On every transition `Closed/Connecting → Open`, the client treats
the gap as "everything in scope might have changed":

- List views: refetch the current page from the QueryDb.
- Detail views: refetch the current entity. If the entity is gone, latch the
  existing entity-gone UX (the `Removed` codepath in `AutoDrillDetail`).

The signal the client uses is `EventsClient.readyState` transitions, which
`LiveConnection` already surfaces via `onStateChange`. No server change
required.

**Pros.** Ships in days. No new server state. No protocol change. Always
correct.

**Cons.** Refetches even when nothing changed (every laptop wake costs N
QueryDb reads, where N = open views). No "N changes happened, click to
refresh" affordance — the user doesn't know whether anything actually moved.
Pagination is *not* a problem in practice: AutoListView already encodes
`after`/`before` keyset cursors plus filters and sort in the URL, so the
refetch lands on the same page the user was viewing. See
[URL as Refetch State](#url-as-refetch-state-prerequisite-for-option-a-and-manual-reload)
below for the inventory of what's covered.

**Cost gating.** Add a debounce + a "skip if reconnect was under T seconds
ago" guard. The default could be: only refetch if the socket was down for
more than 2× the heartbeat / 5 seconds, whichever is larger.

This is the recommended **immediate** mitigation — it eliminates the silent
divergence without any deploy-time change.

### Option B — Server-side per-channel digest, client requests on reconnect

**What.** Introduce a small "what changed in channel X since cursor Y" query:

```graphql
extend type Query {
  catchUpChanges(channel: String!, since: String!, limit: Int = 200):
    CatchUpResult!
}

type CatchUpResult {
  descriptors: [ChangeDescriptor!]!
  cursor: String!
  hasMore: Boolean!
  truncated: Boolean!   # true when the gap exceeded the retention window
}

type ChangeDescriptor {
  changeKind: String!   # Added | Updated | Removed | BulkInvalidated
  id: String!
  sortKeyValue: String
  position: String
}
```

The server backs this with a **per-read-model change journal** — a separate
DynamoDB table or a reserved GSI on the QueryDb itself, populated by the
StateTopic Lambda before (or atomically with) the AppSync publish. Schema:

```
PK = topicRoot         (e.g. "Catalog-Products")
SK = position          (monotonic; see below)
attrs = entityKey, changeKind, sortKeyValue, ts
```

Position generation is the hard part. Three plausible sources:

1. **DDB stream `ApproximateCreationDateTime` + a per-Lambda counter** —
   monotonic per shard but not globally. Good enough for "what did THIS
   entity do since T?" but not for cross-entity ordering. Mostly fine for
   refetch semantics.
2. **DCB position** (when the source projection runs against a DcbEventLog) —
   globally monotonic but only on DCB plugins. Aggregate plugins fall back to
   #1.
3. **A fresh DDB conditional-write sequence number** stamped by the Lambda.
   Cheap (one extra `UpdateItem` per stream batch) and gives global order
   per topic.

The client persists the last `position` it observed per channel in
`sessionStorage` (or `IndexedDB` if it cares about cross-session). On
reconnect, after `connection_ack`, it calls `catchUpChanges` for each active
channel before re-arming the WebSocket subscription (or in parallel, with
de-dup on the position field).

**Pros.** Real replay. Surgical — only changed entities are touched. Cursor
is durable; survives full page reload. `truncated: true` lets the client fall
back to Option A cleanly when the gap exceeds retention.

**Cons.** A new DynamoDB table per read model (or one shared table — see
below), a new write path on the hot publish loop, a new query path, and
position-generation work. Realtime-change-descriptors Phase 3 covers part of
the position story; this can be the consumer that justifies finishing it.

**Retention.** TTL on the journal table (DDB attribute TTL). A 24h window is
the natural ceiling (matches DDB Stream retention; matches typical "I closed
my laptop overnight" use cases). Anything older triggers `truncated: true`
and Option A semantics.

**Where the table lives.** Two layouts:

- **Per read model.** Mirrors the existing per-QueryDb pattern. PK = nothing
  (single-partition) or = subId field; SK = position. Simple to wire from
  `StateTopic_AppSync.make`.
- **Per platform.** One change-journal table for the whole platform, PK =
  topicRoot, SK = position. Fewer resources, but hot-partition risk if one
  read model dominates.

Per read model is the safer first cut.

### Option C — Coalesced "scope invalidated" frame on reconnect

**What.** Combine the cheap part of A with a server hint:

The StateTopic Lambda maintains (or queries on demand) a tiny per-channel
"last publish position." When a client reconnects, it sends a *synthetic*
`subscribe` carrying the last position it observed; the server's `OnSubscribe`
handler (already a hook point — realtime-change-descriptors §8) compares
positions and:

- If the channel's last publish position is unchanged: do nothing.
- If it changed but the count of changed entities is small (≤ N): reply with a
  one-shot batch of descriptors via the existing `data` frame on the
  subscribe.
- If the count is large or the gap is older than the retention: deliver one
  `BulkInvalidated` descriptor — the AutoUI views already handle it by
  resetting and refetching (see `AutoListView` line 882).

**Pros.** Reuses the AppSync `OnSubscribe` integration point that's already
wired (Phase 7 of realtime-change-descriptors). Bounds the descriptor burst
at subscribe time, not as ongoing fanout. Co-opts existing
`BulkInvalidated` handling — no new client codepaths for the common case.

**Cons.** Requires the change-journal of Option B. Subscribe-time work means
slower `connection_ack → subscribed` (a few hundred ms of DDB queries).
`OnSubscribe` is a Lambda data source — adds cold-start cost. Doesn't survive
full page reload unless the client persists `lastPosition`.

### Option D — Bridge through the DCB EventLog (`pullEvents`)

**What.** For DCB plugins only: when reconnecting, fall back to
`pullEvents(cursor)` from `reventless-client-transport.md` Phase 2 to fetch
raw events since the last seen DCB position. Run them through the *same*
projection functions the server runs (the project-on-client path described
in `rescript-client-architecture.md`) to materialise the new descriptor set
locally.

**Pros.** No new server state — the EventLog is already the source of truth.
Naturally globally ordered. Same mechanism the offline-first client uses.

**Cons.** Heavyweight: requires shipping projection code to the browser,
matching the server's projection version, and only works for DCB plugins.
Aggregate-based plugins have no global cursor. Doesn't unblock the simple
"refresh my admin list view" case which is by far the more common reconnect
scenario.

This is the right answer for *offline-first* applications (where the client
already does projection locally) but is overkill for the AutoUI live-update
case.

## URL as Refetch State (prerequisite for Option A and manual reload)

For "refetch the same content the user is currently looking at" to work — on
reconnect, on manual reload, and on tab-restore — the view state must live
somewhere durable. The URL is the obvious place: it is shareable,
bookmarkable, restored by browser back/forward, and survives reload without
any extra storage.

**Status today.** The AutoUI views are already mostly there. `AutoListView`
reads and writes its server-affecting state through `UseSearchParams`:

| State | URL location | Where read |
|-------|--------------|------------|
| Plugin id + read-model name | path: `/:pluginId/:viewName` | `Console_Targets.listView` |
| Currently-open row (drill) | path: `/:pluginId/:viewName/<rowId>/<drillPath…>` | `Console_Targets.drillView` + `parseDrillPath` |
| Search term | `?q=…` | `AutoListView.res:431` |
| Per-column filters | `?f.<field>=…` | `AutoListView.res:423` |
| Sort field + direction | `?sort=…&dir=asc\|desc` | `AutoListView.res:439-449` |
| Keyset pagination cursor | `?after=…` or `?before=…` | `AutoListView.res:454-466` |

The fetch effect's dependency array already includes `serverParamSignature`
(line 370-403) — a sorted string of the URL params that affect the server
query. Manual reload reproduces the same page today *because* of this; a
reconnect-driven refetch gets the same behaviour by just re-firing that
effect with the current URL.

**What this means for Option A.** "Refetch the current page on reconnect"
collapses to "re-run the existing fetch effect." No new state to capture, no
new URL machinery, no per-component plumbing. The Tier 1 work is just:

1. Surface the `Closed/Connecting → Open` transition through `LiveConnection`
   (already 90% there via `onStateChange`).
2. In `AutoListView`'s fetch effect, treat a reconnect transition the same
   way it treats a `serverParamSignature` change — re-run with the current
   URL params. Debounce so brief blips don't thrash.
3. In `AutoDrillDetail`, refetch the entity addressed by the URL's `rowId`.

**Same mechanism covers manual reload.** It already works for reload; the
reconnect path just reuses it. A user paginated to `?after=c.eyJ…`
returns to that exact page after either event, because the URL is the
source of truth.

**Gaps (things NOT in the URL today).**

| State | Where it lives | Why it matters | Recommendation |
|-------|----------------|----------------|----------------|
| Scroll position within the page | Browser scroll restoration (best-effort) | Long lists lose scroll on refetch; routine for SPAs | Out of scope — fix with `history.scrollRestoration = 'manual'` + `sessionStorage` if it becomes a problem |
| `internalSelectedRowId` (non-console mode) | Component state | When AutoUI is rendered standalone (no `pluginId` prop), row selection isn't in the URL | Promote to URL even in standalone mode, or accept the divergence — standalone embedders own their routing |
| Self-change marker (`selfChangeIds`) | Component ref, 60s TTL | A page reload loses the self-change marker; a freshly-fetched row that was added by *this* tab pre-reload looks like "other" | Acceptable. The marker exists to differentiate auto-insert vs pill; after a reload the row is already in the fresh result set, so the pill never fires for it anyway |
| `newItemsCount` pill counter | Component state | Resets to 0 on reload | Correct — the counter measures "things since you last saw the page," and you just refreshed |
| `pendingRefetchIds` / debounce timer | Component refs | In-flight work | Discarded on reload/reconnect — fine |
| Detail cache (`detailCache`) | Component state | Empty after reload; re-fetched on demand | Fine |
| Open drill stack (multiple drills deep) | URL path (`drillPath`) | Already in URL | Done |

The only meaningful gap is `internalSelectedRowId` for the standalone case,
and that's a deliberate split: when there's no `pluginId`, the embedder
controls navigation.

**Keyset-cursor edge case.** A cursor in the URL points to a row by its
(sort-value, id) tuple. If that row was deleted during the gap, the cursor
still produces a valid result set — the keyset query says "rows after
(sortValue, id)" which is well-defined even when the anchor row no longer
exists. The user lands on the correct page boundary, just without the anchor
row visible. Acceptable. The "first/last cursor was the page's first/last
row that itself got deleted" case is the only one that looks slightly odd,
and it self-heals on the next pagination click.

**Implication for Tier 2.** Tier 2's `catchUpChanges(channel, since)` is
independent of URL state — it tells the client *which rows* changed during
the gap. Tier 1 + URL-driven refetch decides *which rows the client is
looking at*. They compose: Tier 2 lets the client apply surgical updates to
the URL-derived page rather than refetching the whole thing.

## Recommendation

A two-tier plan:

### Tier 1 — Ship Option A now (refetch on reconnect)

This eliminates the silent-divergence bug with zero server cost and unblocks
the user-visible symptom. Concretely:

1. **`LiveConnection`** — already exposes `statusFor(api)`. Add a per-channel
   `onReconnect` hook (or surface the state transition through the existing
   `subscribe` API).
2. **`AutoLive.useSubscription`** — accept an optional
   `~onReconnect: unit => unit` callback, fired on `Closed/Connecting → Open`
   *after* the resubscribe completes.
3. **`AutoListView`** — refetch the current page on reconnect, but only if
   the disconnect lasted longer than a debounce window (default 5s, so brief
   network blips don't thrash). If a self-change marker is still live for an
   id in the page, preserve it across the refetch.
4. **`AutoDrillDetail`** — refetch the current entity on reconnect; latch the
   entity-gone UX if it's now missing.
5. **`config.json`** — gate behind `liveReconnectRefetch: true` (default on
   for new platforms; the override exists so degraded networks can disable
   the extra read pressure).

This is < 200 LoC in the UI repo; no server change. Estimated effort:
half a day.

### Tier 2 — Option B: per-read-model change journal

Build the surgical replay path when the cost of indiscriminate refetch
becomes painful (large lists, low-bandwidth clients, or expensive QueryDb
reads). Phasing:

1. **Position generation in the StateTopic Lambda.** Use the conditional-
   `UpdateItem` counter approach (#3 above). This is independent of the
   bigger "position on every QueryDb row" story in realtime-change-
   descriptors §3 — it only needs a per-topic monotonic counter.
2. **`<plugin>ChangeJournal` table per read model.** Single-partition (PK =
   topicRoot constant) with TTL = 24h. Write from the Lambda in the same
   loop that publishes to AppSync Events; one `BatchWriteItem` per stream
   record batch.
3. **`catchUpChanges` resolver.** AppSync GraphQL resolver against the
   journal table. Returns batches up to `limit`, with a follow-up cursor.
4. **Subscriber wiring in `EventsClient` / `LiveConnection`.** Persist
   `lastPosition` per channel in `sessionStorage`. On reconnect (after
   `connection_ack`), call `catchUpChanges` for each active channel before
   processing any new `data` frame. Use a small in-memory "seen positions"
   set so a descriptor delivered via both paths during the race window is
   deduped.
5. **Truncation fallback.** When `truncated: true`, fire the same refetch
   path as Tier 1.

This naturally complements realtime-change-descriptors §3 (descriptor-level
position) — that plan supplies the position field, this plan supplies the
journal that makes positions queryable.

### Option C as a Tier-2.5 optimisation

Once Option B is shipped, the synthetic `subscribe`-time delivery via the
`OnSubscribe` handler (realtime-change-descriptors §8) can replace the
client-driven `catchUpChanges` round-trip for the common small-gap case. It
removes one network round-trip on reconnect at the cost of more
infrastructure complexity. Defer until profiling shows the round-trip
matters.

## Edge Cases and Non-Goals

- **Across full page reload.** Tier 1 loses its position (no persisted
  state). Tier 2 needs `sessionStorage` to survive reload but not `localStorage`
  — cross-tab state divergence is a separate concern. Cross-tab broadcast
  channels (BroadcastChannel API) could share the journal cursor among open
  tabs but are out of scope.
- **Authentication churn during the gap.** A Cognito IdToken expiry while
  disconnected manifests today as a permanent reconnect failure;
  `EventsClient.getToken` already polls the ref, so a refreshed token is
  picked up on the next attempt. Catch-up replay must use the *current*
  identity — if scope changes (user switched tenants), the gap descriptors
  may include rows the user no longer has access to; the journal query must
  honour subscribe-time authorisation, not publish-time. Practically:
  `catchUpChanges` runs through the standard resolver auth context.
- **Self-change tracking across the gap.** The 60s TTL on `selfChangeIds`
  can expire mid-disconnect. The replay descriptor for the user's own pre-
  disconnect command then arrives as "other" and goes behind the new-items
  pill. Acceptable; surfacing this differently is a UX question, not a
  protocol one.
- **`BulkInvalidated` already exists in the descriptor enum and the UI
  reducer.** Tier 2 can emit it as a truncation signal without new client
  work (modulo testing the path — it's currently unreachable per the source
  comment).
- **Source A (raw event stream).** Same gap exists for any subscriber on
  `/default/<eventLogDisplayName>/*`. The natural Source-A catch-up is
  `pullEvents` (Option D), since Source A descriptors *are* events. Out of
  scope for this analysis — the live-update UX driver is Source B.
- **Out of scope for this analysis.** Offline-first command queueing,
  conflict resolution against the server, LiveStore-style local rebase.
  Those need the full client-side event store (see
  `rescript-client-architecture.md` §3 and `reventless-livestore-integration.md`).

## Open Questions

1. **Per-read-model vs per-platform journal table.** Per-RM is simpler to
   wire and isolate; per-platform is one fewer resource. Recommendation:
   per-RM, mirroring the existing per-QueryDb pattern.
2. **Journal write coupling to AppSync publish.** Write-before-publish (so a
   reconnect always sees what the live stream sent) or write-after-publish
   (so the journal can't outrun the live channel)? Recommendation:
   write-then-publish in the same Lambda invocation; if the publish fails
   the journal entry is still valid for catch-up.
3. **Cursor persistence layer.** `sessionStorage` is enough for the
   common case but loses on hard reload; `IndexedDB` is more durable but
   adds complexity. Start with `sessionStorage`; promote to `IndexedDB`
   only if the UX requires it.
4. **Cross-tab dedup.** If three tabs open the same list view and reconnect
   together, they all run `catchUpChanges` independently. A `BroadcastChannel`
   could share one query's result, but this is an optimisation — defer.

## File Reference Map

**Touched on the server** (Tier 2):

- `reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res` —
  write to change journal alongside AppSync publish.
- New: `reventless/reventless-aws/src/adapter/ChangeJournal/ChangeJournal_DynamoDb.res` —
  Pulumi table + per-topic counter.
- New: `reventless/reventless-aws/src/adapter/ChangeJournal/CatchUpChanges_AppSync.res` —
  AppSync GraphQL resolver against the journal table.
- `reventless/reventless-core/src/components/Plugin/Plugin_SubscriptionSchema.res` —
  emit `catchUpChanges` SDL field.
- `reventless/reventless-in-memory/src/InMemory_Bus.res` — in-memory journal
  (small array; same TTL semantics).

**Touched on the client** (Tiers 1 and 2):

- `src/live/EventsClient.res` — surface the `Closed/Connecting → Open`
  transition as an event other than `onStateChange`; record per-subscription
  last-seen position.
- `src/live/LiveConnection.res` — call `catchUpChanges` on reconnect; dedup
  with the live stream.
- `src/live/AutoLive.res` — accept `~onReconnect` callback; thread it
  through.
- `src/auto/AutoListView.res` — refetch page on reconnect (Tier 1);
  consume catch-up descriptors via the existing `handleDescriptor` (Tier 2).
- `src/auto/AutoDrillDetail.res` — refetch entity on reconnect; latch
  entity-gone if missing.

## Cross-References

- [`docs/guides/appsync-events-live-updates.md`](../guides/appsync-events-live-updates.md) — current live-update wire contract.
- [`docs/plans/realtime-change-descriptors.md`](../plans/realtime-change-descriptors.md) — §3 (position), §4 (BulkInvalidated coalescer), §8 (OnSubscribe hook) — supplies infrastructure this plan can build on.
- [`docs/plans/Backlog/reventless-client-transport.md`](../plans/Backlog/reventless-client-transport.md) — `pullEvents` (Option D substrate; useful for DCB plugins).
- [`docs/analysis/rescript-client-architecture.md`](rescript-client-architecture.md) — online-first vs offline-first; the latter sidesteps this problem by treating disconnect as the normal mode.
- [`docs/analysis/reventless-livestore-integration.md`](reventless-livestore-integration.md) — full client-side event log alternative.

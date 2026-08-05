# Plan: `seed:reset` for the local platform — selective wipe, AWS-shaped

**Status:** Complete

| Item | Status | Notes |
|---|---|---|
| 1 — per-store key prefixes locally | ✅ done | `StoreLayout` in core (one definition, AWS + local delegate); local mints under `uploads/{plugin}/{store}` — **nested under the served prefix, see below**; `servedKey` matches multi-segment prefixes |
| 2 — the reset itself | ✅ done | `LocalSeedReset` in `reventless-local` (**not** a separate `seed-local` package — see "Where it lives"); discovery-first classification |
| 3 — scope menu and confirmation | ✅ done | AWS vocabulary (`domain` default, plugin label, `platform`, `everything`), `SEED_RESET_SCOPE`, printed plan + y/N, `SEED_RESET_CONFIRM=1` |
| 4 — documentation | ✅ done | `docs/guides/local-dev.md` § Resetting the store |

Verified end-to-end on 2026-08-05 against a running hybrid platform: a `domain` reset
emptied the domain read models, DCB log and the plugin's objects while the plugin
registry, its event log and the offload store stayed intact; the server served the
change immediately and kept accepting writes, with no restart. 13 tests.

## Where it lives

`reventless-local`, not a separate `seed-local` package. `seed-aws` is separate for a
concrete reason — the Lambda layer is built from `reventless-aws`'s published
dependency closure (`layer-builder/src/Main.res`), so folding the seed harness in
would ship a CLI into every layer. Nothing analogous constrains `reventless-local`: it
is never layer-bundled, and `reventless-seed` is one small dev-only dependency. A
separate package would have bought symmetry and paid a build-chain entry, a jest
project and a publish surface.

**Related:** `reventless/seed-aws/src/ReventlessSeedAws_Reset.res` (the deployed
counterpart this mirrors), commit `f37e4a1a` (the filesystem object-store arm this
builds on).

---

## Goal

Give the local platform a `seed:reset` with the same shape as the deployed one:
empty a chosen **scope** of the store so it is re-seedable, leaving everything
outside that scope intact. Two properties the deployed script has that the local
platform currently cannot offer:

1. **It does not destroy the store, it empties it.** Deleting `.reventless/local.db`
   is not the local analogue of the AWS reset — AWS never deletes a table, it
   deletes rows. Deleting the file is also actively wrong while the platform runs:
   the process holds the file open, so the unlink leaves it on the orphaned inode
   still serving every row it had. The delete looks like it worked and the seed then
   fails against the untouched server with "the target store is not empty".

2. **It is scoped.** `domain` (default), a single plugin, `platform`, or
   `everything` — so wiping domain data leaves the plugin registry intact and a
   re-seed just works, exactly as on AWS.

Object-store files are handled the same way S3 objects are: attributed to the plugin
that declared the store and wiped by key prefix, never wholesale.

### Verified premises

Both established experimentally on 2026-08-05 against a running hybrid platform:

- **A `DELETE FROM` through a second connection is immediately visible to the running
  server, which keeps accepting writes afterwards.** Read models under the SQLite
  backend read through `QueryDbStorage_Sqlite` on every query — there is no in-process
  cache to invalidate. So a content-wipe needs no guard, no process kill, and no
  restart: `seed:reset` then `seed` works with the platform up. This is the premise the
  whole plan rests on; re-verify it first if any of it stops working.
- **Filesystem object entries can be removed under a running server** for the same
  reason — the filesystem arm reads per request and holds nothing.

---

## What the store actually looks like

From a live `.reventless/local.db` (hybrid example, both plugins connected):

| Table | Key column | Holds |
|---|---|---|
| `qdb_<Component>` | `partition_key`, `sub_key` | one table per read model / state-view slice — `qdb_Categories`, `qdb_Orders`, `qdb_Plugins`, `qdb_UiFragments` |
| `event_log` | `log_name` | aggregate events; `PluginAggrEventLog` is the platform's own |
| `snapshot` | `log_name` | aggregate snapshots |
| `dcb_event`, `dcb_tag` | `log_name` | DCB events and their tag index |
| `projection_checkpoint` | `read_model` | `<Name>EventColl` and `dcb:<Name>EventColl` per collector |
| `task_object` | `bucket` | task bucket payloads |

**Table names are unqualified** — `qdb_Categories`, not `qdb_Catalog_Categories`.
Nothing in a name says which plugin owns it, so the mapping has to come from
somewhere else.

### Where the mapping comes from

`qdb_Plugins` holds one row per connected plugin, keyed by plugin name, carrying a
`structure` field. Since the offload work that field is `{$offload: {store, key, …}}`
resolving to `.reventless/offload/sha256/<hash>` — readable offline, which is what
makes an out-of-process reset tool possible at all.

`Plugin.pluginStructure` already carries everything needed:

| Field | Yields |
|---|---|
| `readModels`, `stateViewSlices` (`queryableDef.name`) | the `qdb_<name>` tables |
| `aggregates`, `stateChangeSlices` (`writableDef.name`) | `event_log` / `snapshot` / `dcb_event` / `dcb_tag` `log_name`s |
| `readModels` + `stateViewSlices` names | `projection_checkpoint` rows (`<Name>EventColl`, `dcb:<Name>EventColl`) |
| `requiredStores` (`array<"{plugin}.{store}">`) | the object stores this plugin declared |

This is the direct analogue of the AWS reset reading the platform stack's
`objectStores` output to attribute objects to plugins — same idea, different
transport.

**Platform scope** is then everything a reset can see that no connected plugin's
structure claims: `qdb_Plugins`, `qdb_UiFragments`, `event_log`/`snapshot` under
`PluginAggrEventLog`, their checkpoints, and the `pluginStructures` offload store.
Deriving it by subtraction rather than by a hardcoded list is what keeps it from
drifting when `Platform_Admin` gains a component.

> **Superseded — see "Attribution, corrected" below.** Measured against a live store,
> structures do not describe every table, so neither "domain = union of the plugin
> structures" nor "platform = the remainder" holds.

---

## Attribution, corrected

Measured 2026-08-05 against a live hybrid store, both halves of the assumption above
are false:

- **Plugin structures do not list every table they own.** Catalog and Ordering between
  them account for `qdb_Categories`, `qdb_Products`, `qdb_ProductDemand`,
  `qdb_AvailableProducts`, `qdb_Orders`, `qdb_Customers` — but the store also holds
  `qdb_ImportProductAudit`, `qdb_AutoShipOrderTodo`, `qdb_GeocodeCustomerAddressTodo`
  and `qdb_SendOrderConfirmationTodo`, which appear in no structure's arrays. A domain
  wipe built from structures would leave audit and todo rows behind and report success.
- **The platform's own structure is equally incomplete.** `Platform_Admin_Structure.structure`
  lists the Plugin aggregate and the Plugins read model, and does not mention
  `qdb_UiFragments`. So "platform = what no plugin claims" would not have claimed it either.
- **Checkpoint names are not derivable from component names.** All four shapes occur:
  `CategoriesEventColl`, `CustomersReadModelEventColl`, `UiFragmentsEventColl`,
  `PluginsReadModelEventColl` — the `ReadModel` infix is present for some components
  and absent for others.

### Revised model

**Discover, then classify — and make the open-ended side the default.**

1. **Discover** what is actually there: `qdb_*` from `sqlite_master`, `DISTINCT log_name`
   from `event_log`/`snapshot`/`dcb_event`/`dcb_tag`, `read_model` from
   `projection_checkpoint`, `bucket` from `task_object`, key prefixes from `objects/`.
2. **Platform is a closed allowlist** owned by the reset module, built from core
   constants where they exist (`PluginSpec.name` → `PluginAggrEventLog`, the plugin read
   model, the UI fragment registry) and the `pluginStructures` offload store. Small,
   framework-owned, and changes only when core does.
3. **Domain is everything else** — so a component no structure mentions is wiped by a
   domain reset rather than missed by it. This polarity is the point: a reset that
   misses domain rows fails the re-seed it exists to enable, while one that includes an
   unexpected domain table does what the operator asked.
4. **Per-plugin scope attributes positively** from that plugin's structure, and anything
   it cannot attribute is **reported, never silently included or excluded** — the same
   refusal-over-guessing stance `validateStores` takes on AWS.
5. **Checkpoints follow their component**: strip a leading `dcb:`, a trailing
   `EventColl`, then a trailing `ReadModel`, and match the remainder against the
   component names being wiped. Covers all four observed shapes; unmatched checkpoints
   are reported rather than assumed.

**A test must pin the platform allowlist**: boot the hybrid example, and fail if any
discovered table, log name or checkpoint is classified as neither platform nor a
connected plugin's. That is what stops the allowlist silently rotting when core gains a
component — the failure mode this section exists to document.

---

## The object-store gap (blocking, must be closed first)

The deployed platform roots every store's keys at its own prefix:
`ReventlessInfra.Platform.objectStore.keyPrefix`, defaulting to
`Upload_Presign_S3.defaultServedPrefix`. That prefix is what makes an S3 wipe
attributable — and `ReventlessSeedAws_Reset.validateStores` **refuses** a store set
whose prefixes cannot be told apart, rather than over-deleting.

Locally there is no such prefix. `LocalUploadResolvers.mintRef` mints
`/uploads/<uuid>/<fileName>` from `LocalObjectStore.defaultUploadPrefix`, ignoring the
`store` argument the presign mutation already receives, and `registerServedPrefix` has
no callers. Every plugin's uploads therefore land in one undifferentiated space, and no
prefix-scoped wipe can separate them.

The local platform already computes the right prefix for a different purpose:
`Platform.res` derives `{plugin}/{store}` from each structure's `requiredStores` to
warn about collisions (`ReventlessCore.StorePrefixCollision`), restating the deployed
rule. Closing the gap means *using* it:

- mint under `/{plugin}/{store}/<uuid>/<fileName>`, mirroring the S3 layout, so a
  stored ref is independent of whether the store got its own bucket or a prefix in a
  shared one — the property `keyPrefix`'s own doc comment calls out;
- register each declared store's prefix as a served prefix, so the mint side and the
  serve side cannot disagree (same invariant AWS gets from writing `keyPrefix` once);
- keep `uploads` served, since refs already minted under it are in dev stores today.

**This changes minted refs.** Refs live in an append-only log, so existing local refs
keep pointing at `uploads/…` and must keep resolving — hence keeping the old prefix
served rather than migrating. Worth confirming no fixture or seed asserts the
`/uploads/` shape before starting.

### The prefix must nest under `uploads/` — found the hard way

Minting at the root (`/Catalog/productImages/…`, matching the deployed key layout
exactly) **broke every image in the dev UI**, and did so silently. The host shell's
Vite config forwards exactly one path to the platform:

```js
"/uploads": "http://localhost:4000",
```

A ref outside that path is requested from the UI dev server (`:5180`), which answers
with the SPA shell rather than a 404 — so the image renders as nothing, with a 200 in
the network tab and no error anywhere. The platform had the bytes the whole time.

So the local prefix is `uploads/{plugin}/{store}` (`LocalObjectStore.localPrefixFor`):
the attribution segments the reset needs, kept inside the one path a UI dev server
already forwards. The alternative — a generic proxy rule — lives in the UI repo and
would need a republish and a pin, making the local serve path something every UI dev
server has to be told about rather than a property of the platform.

---

## Work items

### 1. Per-store key prefixes locally

Mint under the declared store's `{plugin}/{store}` prefix; register declared prefixes
as served; keep `uploads` served for already-minted refs. Port the AWS
`validateStores` refusal (unusable, duplicate, or enclosing prefixes) so a store set a
prefix-scoped wipe cannot separate is refused rather than over-deleted.

*Blocks item 3's object handling. Independently useful — it is the local/AWS parity
the ref shape is supposed to have.*

### 2. The reset itself, in `reventless-local`

A ReScript module — scope resolution, structure reading, table and prefix planning,
execution — with the entry point per example mirroring the `SeedAws.res` /
`SeedAwsReset.res` pair (`SeedLocalReset.res`, `pnpm run seed:reset`).

It opens `.reventless/local.db` as a second connection (`busy_timeout` already set by
`SqliteDriver.openDb`), reads `qdb_Plugins`, resolves each `structure.$offload` from
`.reventless/offload/`, and plans:

- `DELETE FROM qdb_<name>` per in-scope component — **contents, never `DROP TABLE`**,
  so the running server's prepared statements and indexes stay valid;
- `DELETE FROM event_log|snapshot|dcb_event|dcb_tag WHERE log_name = ?` per in-scope
  write side;
- `DELETE FROM projection_checkpoint WHERE read_model IN (…)`;
- object-store entries under each in-scope `{plugin}/{store}` prefix;
- `offload/` only when `platform` is in scope.

**`snapshot` and `projection_checkpoint` are not optional.** Leaving snapshots strands
aggregates on stale state after their events are gone; leaving checkpoints stops
projections replaying what is re-seeded. Both are easy to forget because neither is
visible in a GraphQL query.

### 3. Scope menu and confirmation

Reuse the AWS vocabulary verbatim — `domain` (default), a plugin label, `platform`,
`everything` — and `SEED_RESET_SCOPE` for non-interactive selection, so switching
between local and deployed does not mean learning a second vocabulary.

**Open question:** whether to keep AWS's dry-run default and typed confirm. The gates
there exist because the target is remote, shared, and irreversible; locally it is a
file in a git-ignored directory that `serve:reset` already wipes without ceremony.
Suggest a printed plan plus a single y/N — not a dry run, not a typed stack name — but
this is a judgement call worth making explicitly rather than by default.

### 4. Documentation

`docs/guides/local-dev.md` § Storage backend: the script, the scopes, and that it works
against a running platform. State the relationship to `serve:reset` — that one wipes
everything as it starts, this one wipes a scope in place — since having both otherwise
reads as redundancy.

---

## Not in scope

- **Memory backend.** Nothing persists, so a restart is the reset. The script should
  say so rather than appear to work.
- **Postgres backend.** Event logs live off-machine and read models are in-memory,
  rebuilt by replay; a local file-oriented reset does not fit. Refuse with the reason.
- **`runner.db`.** Created by tooling outside this repo. Not ours to delete.

---

## Risks

**A wipe is visible to a running server mid-request.** A command in flight can read a
pre-wipe state and write a post-wipe event. Dev-only and self-inflicted, but the
consequence (an aggregate rebuilt from a partially-wiped log) is confusing enough to be
worth a note in the output rather than a silent success.

**`qdb_Plugins` is the source of truth for the mapping.** A plugin that never connected
has no row, so its tables look like platform scope by subtraction and a `platform`-scoped
wipe would take them. Reading the registry after a full connect handshake is the normal
case; the failure mode is worth an explicit check (a `qdb_<name>` table with no claimant
is reported, not silently assigned).

**Offload resolution is now a dependency of the reset path.** If `structure` is offloaded
and `offload/` was wiped without the database — reachable today by hand, since the two
are separate trees — the mapping cannot be read. Fail with that as the message rather
than falling back to a wholesale wipe.

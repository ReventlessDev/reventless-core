# Plan: stop annotating every optional field

**Status.** IN PROGRESS 2026-09-04. Step 1 done and green, and now verified live
against a fresh local store; steps 2–3 are the operational half — step 2's local
arm is measured and its guidance corrected below, its AWS arm and step 3 wait on a
push. Re-scoped once before execution after measuring through the repo's own
emitter rather than sury's; then corrected again *during* execution, because one of
the three blockers §6 of the analysis disproved turns out to be half real — see
"What execution changed" below.

**What execution changed**

- **§6.1 is right for scalars and wrong for records.** The healer's `anyOf` branch
  reaches `return undefined` only after two arms above it: an enum's first const,
  and an object member filled with zeros. `S.option(S.string)` — the shape §6.1
  measured — passes both and heals to `None`. `option<record>` does not. Measured
  on the real `pluginDefinitionSchema`, `dcbEventLog` healed to
  `Some({name: "", eventTopicArn: ""})`, which `manageSubscriptions` would have
  read as a peer to subscribe to. Fixed by one line mirroring the existing
  `has.null` guard, in `Message.res`, covered by `MessageHealTest`.
- **The tripwire's walker had the same blind spot.** `PluginDefinitionScalars`
  defined optional as `has.null`, so after the change it reported 16 optional
  fields as newly-added bare required scalars. Taught it both encodings; the
  golden list is then unchanged, as step 4 predicted.
- **48 annotation sites, not 47** — `PluginsReadModelSpec.dcbEventLog` carries a
  49th via `Plugin.dcbEventLogOptionSchema`. And 13 helper bindings, not four.
- **The frozen lifecycle corpus is old data too.** Five real payloads carrying the
  null encoding. Null-valued keys were stripped mechanically and the README's
  Provenance section records it as a second transformation; see the note there for
  why that is not a regeneration.
- **`check:graphql` did not move**, confirming §6.2.
- **The stale-store failure is loud, and it is not the healer's to catch.**
  `fillMissingDefaults` fills keys that are *absent*; a key present with `null` is
  not absent, so no heal is attempted and the original error is re-thrown. Measured
  by booting the hybrid platform against a copy of a real pre-change SQLite store:
  every domain event replayed fine, all four servers printed `listening`, and then
  the Plugin aggregate's replay killed the process with an uncaught
  `SuryError: Failed at ["_0"]["apiTarget"]: Expected string | undefined, received null`
  out of `EventLog_Operations.decodeEvent`. Fail-loud, seconds after the process
  looks healthy — which is the behaviour to want, but it means step 2 is not
  optional anywhere the old payloads survive.

**Goal.** One optional encoding across the repo, with **no sury annotation of any
kind** — not per-field, not per-type, not per-file. Sury's default for
`option<'a>` already *is* that encoding, so the goal is reached by deleting the 47
`@s.matches(...OptionSchema)` annotations and their four helper bindings rather
than by adding a feature. The repo becomes internally consistent at the same time:
53 optional-schema constructions already use the default form against 15 that do
not.

**Relates to:**

- [`sury-per-field-optional-annotation.md`](../analysis/sury-per-field-optional-annotation.md)
  — the analysis this plan executes, with every measurement, the three false
  blockers, and the method note explaining how they arose
- [`plugin-definition-schema-evolution-wedge.md`](../analysis/plugin-definition-schema-evolution-wedge.md)
  — the incident behind the guidance step 4 rewrites
- [`clearing-aws-eventlog-querydb-tables.md`](../analysis/clearing-aws-eventlog-querydb-tables.md)
  — the Pulumi-targeted alternative to step 2's wipe, for when tables must be
  recreated rather than emptied

---

## Why — the annotations survive a bug that no longer exists

The rationale at [`Plugin.res:76-77`](../../reventless/spec/src/components/Plugin.res#L76-L77),
duplicated verbatim at [`Resource.res:5-10`](../../reventless/interop/src/Resource.res#L5-L10),
says an undefined-based optional fails sury's jsonable validation inside a union
variant payload. Measured on `sury@11.0.0-rc.2`, reproducing that exact shape, all
twenty cells pass. The failure was real on alpha.10 and was fixed by #311 in
alpha.11.

There is no configuration anywhere in sury or sury-ppx that would change the
default encoding instead, so keeping the null form forces per-field annotation.
Dropping it removes the question — and the default is what the rest of this repo
already uses, including `Message.meta` on every message and `storedEvent.tags?` on
every EventLog row.

**One thing genuinely blocks it:** the two encodings are mutually unreadable on the
wire, so stored payloads and already-deployed plugins have to go. That is step 2.

**What does not block it**: the emitted JSON Schema is byte-identical either way,
because `SchemaType.fromSury` collapses `Null` and `Undefined` to the same
`Nullable` — so no UI change, no deploy ordering constraint, and no golden refresh.
Confirmed in execution: `check:graphql` did not move.

**What half-blocks it**: the healer, but only on `option<record>` and
`option<enum>` — see "What execution changed" above. One line, landed with step 1.

## Step 1 — delete the annotations ✅ DONE

- [`Plugin.res`](../../reventless/spec/src/components/Plugin.res): removed 45
  `@s.matches(...)` and 12 helper bindings; `uiFragmentManifestOptionSchema` is
  used as a value elsewhere, so it stayed as a binding and moved to `S.option`.
- **Left the two `Offload` fields alone** — those carry the inline-or-reference
  union codec, not an optional wrapper, and `Offload.optionSchema` builds both
  arms. It keeps `nullAsOption`, so its fields keep writing `null`.
- [`PluginsReadModelSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res):
  the 48th site, reached through `Plugin.dcbEventLogOptionSchema`.
- [`Resource.res`](../../reventless/interop/src/Resource.res): its single site.
- Rewrote the stale comment in both files, plus the schema-evolution guidance on
  `pluginStructure` and in `pluginDefinitionRequiredScalars.txt` (step 4), which
  told an author to reach for `js_nullable`.
- [`Message.res`](../../reventless/spec/src/types/Message.res): the healer guard,
  and [`PluginDefinitionScalars.res`](../../reventless/core/tests/plugin/PluginDefinitionScalars.res):
  the matching one in the tripwire's walker.
- Test-side wire goldens that moved with the encoding: `LogFormatTest`'s encoded
  `Connect`, two `Platform_PluginStructuresApiTest` decode cases, and the five
  lifecycle corpus fixtures.

Verified: the emitted `.res.mjs` shows `Sury.$option(...)`, no `nullAsOption`
remains outside `Offload.res`, `pnpm run build` is warning-free, `pnpm test` and
`pnpm run test:projects` are green, and `check:graphql` is unchanged.

## Step 2 — the wire migration

The blast radius is narrow: only stores carrying `pluginDefinition` /
`pluginStructure`. Domain plugin data is untouched.

1. **Wipe the platform scope.** `SEED_RESET_SCOPE=platform` on
   `ReventlessSeedAws_Reset` selects exactly the platform target
   (`{projectDir: ".", label: "platform", group: Platform}`) — the Plugin
   lifecycle EventLog, the Plugins QueryDb table, and the platform-qualified
   object stores (`pluginStructures`, `pluginApiFragments`). Prefer it to
   hand-deleting tables: it discovers by tag, is fail-closed, wipes shared-layout
   buckets by key prefix, and offers a dry run plus typed confirmation.
2. **Let the quiesce run.** A truncate is not durable while runtimes hold
   module-level state and re-save it each invocation; `ReventlessSeedAws_Quiesce`
   performs the hold-and-recycle, and in-flight SQS `Connect` messages must drain.
3. **Redeploy the whole fleet from one commit**, so no deployed plugin is left
   registering in the old format.
4. **Local platforms.** Start each example app once with `?reset` — `pnpm run
   serve:reset` (or `dev:full:reset`), i.e. `REVENTLESS_LOCAL_BACKEND=
   'sqlite:./.reventless/local.db?reset'`. **Do not delete the file**, which is
   what an earlier draft of this step said: `LocalSeedReset`'s own header records
   why — while the platform runs, the unlink leaves it on an orphaned inode still
   serving every row it had, so the delete looks like it worked and nothing
   changes. `?reset` wipes at `Platform.Make` time, before anything reads, and
   `LocalObjectStore.reset` runs with it, so `objects/`, `object-meta/` and
   `offload/` go too — a full wipe, not just the rows. The memory backend needs
   nothing. `.reventless/` is gitignored, but `users.yaml` and `token-secret` live
   beside the db and must survive, which is why the directory is never cleared
   wholesale.

   **Find the carriers by reading them, not by listing the apps.** Two of this
   repo's three local stores carried the old encoding and the third did not, and
   the split was not the one the app names suggest: `hybrid/.reventless/local.db`
   and `hybrid/.reventless/runner.db` both did, while `dcb/.reventless/runner.db`
   had an empty `event_log` and no `qdb_Plugins` at all — it had never registered
   a plugin. `select payload from event_log where log_name='PluginAggrEventLog'`
   and look for null-valued keys; that is the whole test.

   **One object store per directory, and upload keys are not deterministic.**
   `BackendState.getObjectStoreRoot` is `dirname(<sqlite path>)`, so two db files
   in one `.reventless/` share `objects/` — and `?reset` on either wipes it for
   both. Since an upload key carries a random UUID segment
   (`uploads/Catalog/productImages/<uuid>/prd-013.svg`), a reseed does not
   reproduce the keys the other store's rows point at. So a directory holding two
   stores can only have **one** of them reseeded with working image references;
   the other has to be cleared, not reseeded. `runner.db` is the one to give up:
   it belongs to the VS Code runner (tooling outside this repo), which recreates
   it empty and re-registers on its next start. Delete it directly rather than
   `?reset`-ing it — the orphaned-inode hazard applies only while a process holds
   the file, and deleting the file alone leaves the shared object store intact.

Domain plugins' own `pluginStructures` / `pluginApiFragments` prefixes survive a
platform-scoped wipe, since object stores are qualified `{plugin}.{store}`. That is
acceptable: the blobs are content-addressed, each plugin re-offloads under a new
hash, and nothing references the old keys once the aggregate is wiped.

### Verified locally, 2026-09-04

Against a **fresh** SQLite store on an isolated port set (per
`reference_live_local_graphql_roundtrip`: never point a `?reset` run at a
`.reventless/` another process may hold):

- Both plugins registered and reached `Connected`; `Platform_Plugins` reads back
  their status, `statusChange`, extension points and extensions.
- `Platform_PluginStructures` resolves every offloaded structure in full — the
  path that froze in the incident behind step 4's guidance — including the
  `requiredStores` / `requiredStoreDeclarations` / `requiredCapabilities` /
  `traitDeclarations` fields that were the wedge. On the platform's own entry the
  absent ones read back as `null` through GraphQL, unchanged, since the emitted
  schema still calls them `Nullable`.
- The persisted `VersionConnected` payloads and both offloaded blobs carry **zero**
  null-valued keys, at any depth: absent optionals are omitted, which is the whole
  change.
- Domain round-trip green (`Catalog_AddCategory` → `Catalog_Categories`).

The stale-store probe in "What execution changed" above ran against a **copy** of
the real dev store, so no local data was touched by that.

### Local stores migrated, 2026-09-04

Step 2's local arm is done for this working copy:

- `hybrid/.reventless/local.db` — full `?reset` wipe (rows and object store), then
  reseeded with the `sample` set, which is what it had held (40 orders). Both
  plugins re-register with **no** null-valued keys, and all 30 image references in
  `Catalog_Products` / `Catalog_Categories` resolve to files on disk.
- `hybrid/.reventless/runner.db` — deleted. It carried the old encoding, and per
  the shared-object-store note above it could not be reseeded without breaking
  `local.db`'s images.
- `dcb/.reventless/runner.db` — deleted; it held three stray DCB events from June
  and no plugin registrations. The app has no `seed` script, so there is nothing
  to reseed. Booted once to create `local.db` fresh: both plugins register clean.

## Step 3 — release and downstream consumers

`feat!` — `reventless-spec` is published on every alpha push, so external consumers
compile against whichever shape they installed.

**Nothing downstream has annotations to remove** (zero `nullAsOption` outside this
repo). Exposure is rebuild-and-repin only: consumers of the published core packages
must be rebuilt against the release, and any that pin published core deps in
release-mode CI move that pin with it. The `@reventlessdev/reventless-ui` package
needs nothing — no sury dependency, and the schema shape it reads does not change.

## Step 4 — the guidance that has to move with it ✅ DONE

`pluginDefinitionRequiredScalars.txt`'s advice — *"If your new field can be absent,
give it the `js_nullable` (`T | null`) shape"* — becomes wrong; the answer is now
"make it optional". The tripwire itself still works: optional fields are not
required scalars and stay off the list either way. Check whether the golden list
moves and regenerate only if it should.

Expect `pnpm run check:graphql` **not** to move. If it does, the reasoning in §6.2
of the analysis is wrong somewhere and the change should stop until that is
understood.

## Step 5 (follow-on, separate) — `option<'a>` fields → optional (`?:`) fields

**Identical on the wire.** Both spellings derive `S.option(...)`;
[`StoredEvent.res:25`](../../reventless/spec/src/types/StoredEvent.res#L25) already
demonstrates it. Reads are unaffected (`r.foo` still yields an `option`); only
construction changes — `{foo: None}` becomes an omitted field and
`{foo: someOption}` becomes `{foo: ?someOption}`. There are ~137 `: None` sites
across framework `src`, concentrated in `Platform_Admin_Structure` (11),
`PluginRuntime_Builder` (9), `Plugin_Builder` (7) and `Dcb_Builder` (7).

**Do not bundle this with steps 1–4.** It touches every construction site of every
converted record across core, aws, spec, local, examples and tests, and buys
ergonomics only. Landing it with the wire migration makes a mistake in the wide
mechanical sweep indistinguishable from a migration problem.

**Verify first:** that the ppx handles `?:` fields identically inside *variant
payloads*. These records travel as `Connect(pluginDefinition)`, and `Message.meta`
is nested rather than a variant arm, so it is not the same evidence. A
compile-and-diff on one type settles it.

## Verification

- `pnpm run build` with zero warnings (`2>&1 | grep -E "Warning|warning|error|Error"`)
- `pnpm test`, plus `pnpm run test:projects` so no declared jest project silently
  discovers 0 suites
- `pnpm run check:graphql` — expected unchanged; a diff here is a stop signal, not
  a golden to refresh
- A live local GraphQL round-trip against a **fresh** store, since a stale SQLite
  file is exactly the failure this migration creates — done, see "Verified
  locally" under step 2
- After deploy: a plugin registers, reaches `Connected`, and its structure is
  readable through the admin — the path that froze for two days in the incident
  behind step 4's guidance. The local run exercises the same three steps, so a
  failure here would be an AWS-adapter difference, not an encoding one.

## What would stop this

- **A `check:graphql` diff.** Per §6.2 of the analysis the emitted schema is
  byte-identical; a moved golden means that measurement does not hold for some
  field shape in the real specs, and the difference has to be understood before
  proceeding.
- **A carrier of `pluginStructure` outside the platform scope.** Step 2 assumes
  domain stores hold no `pluginDefinition`. If one does, its store joins the wipe.
- **A published consumer that cannot be rebuilt in step with the release.** The
  wire change is not backward compatible; there is no dual-read path, and adding
  one would cost more than the annotations do.

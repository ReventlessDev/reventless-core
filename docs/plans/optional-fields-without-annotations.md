# Plan: stop annotating every optional field

**Status.** PLAN 2026-09-04. Not started. Four steps, the first of which is a
correctness fix that stands on its own and must land before the others. Sized
from measurements in the companion analysis — no new mechanism is invented here,
and no upstream change is required.

**Goal.** One optional encoding across the repo, with **no sury annotation of any
kind** — not per-field, not per-type, not per-file. Sury's default for
`option<'a>` already *is* that encoding, so the goal is reached by deleting the 47
`@s.matches(...OptionSchema)` annotations and their four helper bindings rather
than by adding a feature. The repo becomes internally consistent at the same time:
53 optional-schema constructions already use the default form against 15 that do
not.

**Relates to:**

- [`sury-per-field-optional-annotation.md`](../analysis/sury-per-field-optional-annotation.md)
  — the analysis this plan executes, with every measurement and the two probes
- [`plugin-definition-schema-evolution-wedge.md`](../analysis/plugin-definition-schema-evolution-wedge.md)
  — the incident behind the rule step 4 rewrites
- [`clearing-aws-eventlog-querydb-tables.md`](../analysis/clearing-aws-eventlog-querydb-tables.md)
  — the Pulumi-targeted alternative to step 3's wipe, for when tables must be
  recreated rather than emptied

---

## Why — the annotations survive a bug that no longer exists

The rationale written at [`Plugin.res:76-77`](../../reventless/spec/src/components/Plugin.res#L76-L77),
and duplicated verbatim at [`Resource.res:5-10`](../../reventless/interop/src/Resource.res#L5-L10),
says an undefined-based optional fails sury's jsonable validation inside a union
variant payload. Measured on `sury@11.0.0-rc.2`, reproducing the exact shape — a
bare `S.option(S.string)` field inside a positional variant payload mirroring
`PluginSpec.command = | Connect(pluginDefinition)` — all twenty cells pass. That
failure was real on alpha.10 and was fixed by #311 in alpha.11.

Two things do still hold, and they are what this plan handles rather than waves
past:

1. **The wire format differs.** `nullAsOption` writes `"field": null`; the default
   omits the key, and neither can parse the other. Only relevant while old data
   and old deployments exist — hence step 3.
2. **The healer cannot distinguish absent from empty under the default
   encoding.** `S.option` emits a bare `{"type":"string"}`, so
   `fillMissingDefaults` invents `""` for an absent optional, turning `None` into
   `Some("")`. This one is *not* fixed by a wipe, and it is the real work the null
   shape was doing — hence step 1.

There is no configuration anywhere in sury or sury-ppx that would change the
default instead (`S.global` carries two unrelated knobs; sury-ppx takes no
arguments and its API is nine field-level attributes). If the null encoding were
kept, per-field annotation would be unavoidable. Dropping it removes the question.

## Step 1 — make the healer `required`-aware

**Land this alone, first, and verify it.** It is a correctness fix under *either*
encoding, it touches no wire format, and it is what makes step 2 safe. If it is
bundled with step 2, a failure cannot be attributed to one or the other.

`fillMissingDefaults` is hand-written `%raw` JS in
[`Message.res:181`](../../reventless/spec/src/types/Message.res#L181). Its object
branch fills every declared property without consulting `required`:

```js
var props=schema.properties||{};
var names=Object.keys(props);
for(var i=0;i<names.length;i++){ var n=names[i]; value[n]=fill(props[n], value[n], path+"."+n); }
```

The emitted JSON Schema already carries `required` with optional fields correctly
excluded (measured: `required:["name"]` with the optional field absent from it).
Skip filling a property that is absent **and** not listed in `schema.required`.

Afterwards:

- absent **optional** → stays absent → decodes to `None`
- absent **required scalar** → filled and reported in `scalarFills`, unchanged —
  this is what `PluginDefinitionRequiredScalarsTest` and its golden exist to police

**Tests.** Add cases to the `Message` suite covering both arms: an absent optional
survives a heal as `None`, and a missing required scalar still fills and warns.
Confirm the existing `anyOf` / `has.null` path is untouched, since the 15
null-encoded sites still run through it until step 2.

## Step 2 — delete the annotations

- [`Plugin.res`](../../reventless/spec/src/components/Plugin.res): remove the 47
  `@s.matches(...)` and the four helper bindings (`stringOptionSchema`,
  `stringArrayOptionSchema`, `boolOptionSchema`, `dcbEventLogOptionSchema`).
- **Leave the two `Offload` fields alone** ([:496](../../reventless/spec/src/components/Plugin.res#L496),
  [:502](../../reventless/spec/src/components/Plugin.res#L502)) — those carry the
  inline-or-reference union codec, not an optional wrapper, and
  `Offload.optionSchema` builds both arms.
- [`Resource.res`](../../reventless/interop/src/Resource.res): the same removal for
  its single site.
- Rewrite the stale comment in **both** files. It should state the current reason
  for the encoding choice, not the fixed bug.

Verify the emitted `.res.mjs` shows `Sury.$option(...)` where the helpers used to
be, and that no `nullAsOption` construction remains outside `Offload.res`.

## Step 3 — the wire migration

The blast radius is narrow: only stores carrying `pluginDefinition` /
`pluginStructure`. Domain plugin data is untouched.

1. **Wipe the platform scope.** `SEED_RESET_SCOPE=platform` on
   `ReventlessSeedAws_Reset` selects exactly the platform target
   (`{projectDir: ".", label: "platform", group: Platform}`) — the Plugin
   lifecycle EventLog, the Plugins QueryDb table, and the platform-qualified
   object stores. Prefer it to hand-deleting tables: it discovers by tag, is
   fail-closed, and offers a dry run plus typed confirmation.
2. **Let the quiesce run.** A truncate is not durable while runtimes hold
   module-level state and re-save it each invocation; `ReventlessSeedAws_Quiesce`
   performs the hold-and-recycle, and in-flight SQS `Connect` messages must drain.
3. **Redeploy the whole fleet from one commit**, so no deployed plugin is left
   registering in the old format.
4. **Local platforms.** Delete each app's SQLite file — `./.reventless/local.db`
   by default, or wherever `REVENTLESS_LOCAL_BACKEND` points. The path is relative
   to each app, so this is one file per example app. The memory backend needs
   nothing.

Domain plugins' own `pluginStructures` / `pluginApiFragments` prefixes survive a
platform-scoped wipe, since object stores are qualified `{plugin}.{store}`. That
is acceptable: the blobs are content-addressed, each plugin re-offloads under a
new hash, and nothing references the old keys once the aggregate is wiped. They
are orphans, not a correctness problem.

## Step 4 — the paperwork that has to move with it

- **GraphQL goldens.** The JSON Schema shape changes (`anyOf:[T,null]` + required
  → plain `T`, not required), so `pnpm run check:graphql` will move. Refresh in
  the same commit as the change that moved it.
- **`pluginDefinitionRequiredScalars.txt`.** Its guidance — *"If your new field can
  be absent, give it the `js_nullable` (`T | null`) shape"* — becomes wrong; the
  answer is now "make it optional". The tripwire itself still works: optional
  fields are not required scalars and stay off the list either way. Check whether
  the golden list moves and regenerate only if the analysis says it should.
- **`feat!`** — `reventless-spec` is published on every alpha push, so external
  consumers compile against whichever shape they installed.

## Step 5 (follow-on, separate) — `option<'a>` fields → optional (`?:`) fields

**Identical on the wire.** Both spellings derive `S.option(...)`;
[`StoredEvent.res:25`](../../reventless/spec/src/types/StoredEvent.res#L25) already
demonstrates it, and the encode probe confirms sury normalises an own-property
`undefined` and an absent key to the same output. Reads are unaffected
(`r.foo` still yields an `option`); only construction changes — `{foo: None}`
becomes an omitted field and `{foo: someOption}` becomes `{foo: ?someOption}`.

There are ~137 `: None` sites across framework `src`, concentrated in
`Platform_Admin_Structure` (11), `PluginRuntime_Builder` (9), `Plugin_Builder` (7)
and `Dcb_Builder` (7).

**Do not bundle this with steps 1–4.** It touches every construction site of every
converted record across core, aws, spec, local, examples and tests, and buys
ergonomics only. Landing it with the wire migration makes a mistake in the wide
mechanical sweep indistinguishable from a migration problem. Package by package,
afterwards.

**Verify first:** that the ppx handles `?:` fields identically inside *variant
payloads*. These records travel as `Connect(pluginDefinition)`, and `Message.meta`
is nested rather than a variant arm, so it is not the same evidence. A
compile-and-diff on one type settles it.

## Verification

- `pnpm run build` with zero warnings (`2>&1 | grep -E "Warning|warning|error|Error"`)
- `pnpm test`, plus `pnpm run test:projects` so no declared jest project silently
  discovers 0 suites
- `pnpm run check:graphql` after refreshing goldens
- A live local GraphQL round-trip against a **fresh** store, since a stale SQLite
  file is exactly the failure this migration creates
- After deploy: a plugin registers, reaches `Connected`, and its structure is
  readable through the admin — the path that froze for two days in the incident
  behind step 4's rule

## What would stop this

- **Step 1's guard changes the `anyOf` path.** It must not: the 15 null-encoded
  sites still depend on it until step 2, and `Offload` depends on it permanently.
  If the guard cannot be made to leave that branch alone, stop and reconsider.
- **A carrier of `pluginStructure` outside the platform scope.** Step 3 assumes
  domain stores hold no `pluginDefinition`. If one does, its store joins the wipe
  and the "domain data is untouched" claim in the analysis needs revising.
- **The healer turns out to run more often than assumed.** It fires only on a
  first parse failure; if profiling shows it on a hot path, the guard's cost is
  worth measuring before step 2 widens what reaches it.

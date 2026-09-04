# Removing the Per-Field Optional Annotations — One Real Blocker, and Three That Were Not (One Half Was)

**Scope.** Why every optional field on `pluginDefinition` / `pluginStructure` carries an
`@s.matches(...OptionSchema)` annotation, whether sury or sury-ppx can be configured to avoid
that (they cannot), and what actually stands in the way of deleting all 47. Answer: the wire
format, and one line of the schema healer. Written 2026-09-04 against `sury@11.0.0-rc.2`; §6
records three blockers this analysis first claimed and then disproved, because the instrument
that produced them is an easy one to reach for again — and, since execution, how the first of
those disproofs was itself half wrong.

**Files reviewed**
- [`Plugin.res`](../../reventless/spec/src/components/Plugin.res) — the annotated sites (47 here, plus one in `PluginsReadModelSpec.res`) and the helper bindings
- [`Resource.res`](../../reventless/interop/src/Resource.res) — the same rationale, duplicated, one site
- [`Message.res`](../../reventless/spec/src/types/Message.res) — `fillMissingDefaults`, `parseJsonTolerant`
- [`SuryToJsonSchema.res`](../../reventless/core/src/components/Api/SuryToJsonSchema.res) + [`SchemaType.res`](../../reventless/core/src/components/Api/SchemaType.res) — the repo's **own** JSON Schema emitter, which is what consumers actually see
- [`StoredEvent.res`](../../reventless/spec/src/types/StoredEvent.res) — `storedEvent.tags?`, an unannotated optional on the EventLog row
- [`PluginSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginSpec.res) — `| Connect(pluginDefinition)`, the variant payload these records travel in
- [`ReventlessSeedAws_Reset.res`](../../reventless/seed-aws/src/ReventlessSeedAws_Reset.res) — scope selection for the wipe
- `node_modules/sury-ppx/README.md`, `node_modules/sury/index.mjs` — the configuration surface

---

## 1. The requirement

Annotations should be minimal, and ideally absent. Writing `@s.matches(stringOptionSchema)` on
every optional field — 47 times in one file — is repetition the tooling should absorb. The
preference is one globally consistent approach with no per-field, per-type or per-file
annotation of any kind.

## 2. Verdict

**Reachable today, with the current sury, and with no upstream request.** Sury's *default* for
`option<'a>` already **is** the annotation-free encoding, so the goal is met by deleting the 47
annotations and their four helper bindings rather than by adding a feature. It also makes the
repo internally consistent: 53 optional-schema constructions already use the default form
against 15 that do not.

**Exactly one thing blocks it: the wire format** (§5). Stored payloads carry explicit `null`,
which the default encoding cannot parse. Discarding alpha data and redeploying the fleet removes
it.

Nothing else does. In particular there is **no** UI work and **no** golden refresh (§6) — verified
in execution, `check:graphql` did not move. A one-line healer fix *was* required after all, for
`option<record>` and `option<enum>` only; §6.1 records what the first measurement missed.

If the null encoding were instead kept, per-field annotation would be unavoidable — there is no
configuration at any level (§3).

## 3. There is no sury configuration — three places checked

**sury's global config.** `S.global` exists and accepts exactly two knobs:

```js
(override) => {
  globalConfig.a = override.defaultAdditionalItems !== U ? … : initialOnAdditionalItems;
  globalConfig.f = override.disableNanNumberValidation === true ? … : initialDefaultFlag;
}
```

Neither concerns optional encoding. It is also a **runtime** override while schemas are
constructed at module-init time, so any such knob would have to be set before every import in
every Lambda entry point, test file and CLI tool — one miss producing a silent wire-format
divergence. Even if it existed, this is the wrong mechanism for this data.

**sury-ppx configuration.** There is none. Install is `"ppx-flags": ["sury-ppx/bin"]` with no
arguments, and the binary exposes only generic ppxlib driver flags. ReScript's `ppx-flags` *does*
accept an array form, so a compile-time flag would be a valid shape — sury-ppx simply doesn't
read one.

**sury-ppx's API surface.** Nine attributes: `@schema`, `@s.matches`, `@s.null`, `@s.nullable`,
`@s.default`, `@s.defaultWith`, `@s.meta`, `@s.with`, and the `@s.strict` / `@s.strip` /
`@s.deepStrict` / `@s.deepStrip` / `@s.noValidation` group. `@s.null` — which emits exactly what
the helper bindings emit — applies to "option type expressions, optional record fields", i.e.
field level only. There is no file-, module- or project-level default.

## 4. The rationale in the file is stale

[`Plugin.res:76-77`](../../reventless/spec/src/components/Plugin.res#L76-L77), duplicated verbatim
at [`Resource.res:5-10`](../../reventless/interop/src/Resource.res#L5-L10):

> js_nullable (T | null) is the only optional that passes jsonableValidation inside union
> variant payloads; nullableAsOption adds `undefined` and fails it.

**No longer true.** Measured on rc.2, reproducing the exact shape — a bare `S.option(S.string)`
field inside a positional variant payload mirroring
`PluginSpec.command = | Connect(pluginDefinition)`, encoded through `Util_Sury`'s own path:

```
=== bare S.option (ppx-derived) ===
  record   absent   -> json      : ok  {"name":"p"}
  variant  absent   -> json      : ok  {"TAG":"Connect","_0":{"name":"p"}}
  variant  absent   -> jsonString: ok  "{\"TAG\":\"Connect\",\"_0\":{\"name\":\"p\"}}"
  variant  absent   round-trip  : ok  {"TAG":"Connect","_0":{"name":"p"}}
```

All twenty cells pass. The failure was real on alpha.10 and was fixed by #311 in alpha.11. Both
comments should be rewritten whichever way the decision goes.

Supporting evidence that the default form is fine on the wire: the repo already ships it on its
two most-travelled types. [`Message.res:35`](../../reventless/spec/src/types/Message.res#L35)
(`meta`, on every message) and
[`StoredEvent.res:25`](../../reventless/spec/src/types/StoredEvent.res#L25) (`tags?`, on every
EventLog row) use unannotated optionals. `Plugin.res` is the outlier, not the rule.

## 5. The one real blocker — wire format

The two encodings are mutually unreadable. Measured:

```
PARSE stored payloads back into ReScript values
  bare   <- legacy (null)   : FAIL Failed at ["requiredAccess"]: Expected string | undefined, received null
  bare   <- omitted         : ok   {"name":"p"}
  nullAs <- legacy (null)   : ok   {"name":"p"}
  nullAs <- omitted         : FAIL Failed at ["requiredAccess"]: Expected string | null, received undefined
```

Everything reachable from `pluginDefinition` is persisted in the Plugin lifecycle aggregate's
event log and replayed, and `pluginDefinition` also travels in the `ConnectPlugin` handshake
between separately deployed plugins and the admin. `reventless-spec` is published on every alpha
push, so external consumers compile against whichever shape they installed.

This blocks the change **only** while old data and old deployments exist. See §7 for what has to
go.

## 6. Three blockers that are not real (and the half of one that is)

All three were claimed in an earlier draft of this analysis and then disproved. They share one
cause: they were measured with **`Sury.toJSONSchema` on a hand-built schema**, which no part of
this repo uses. Measure through the repo's own emitter and through the real functions instead.

Execution then found the disproof in 6.1 too narrow: right about the branch, wrong that the
branch had one answer.

### 6.1 The healer does NOT fabricate `""` for absent optionals — but it did invent for `option<record>`

**Half real. Corrected during execution; read the second half before relying on this section.**

The original claim was that `S.option` emits a bare `{"type":"string"}`, so `fillMissingDefaults`
takes its scalar branch and invents `""`, turning `None` into `Some("")`.

**That much is wrong — the healer reads sury's *internal* schema object, not the emitted JSON
Schema.** Internally:

```
S.option(string)       type="anyOf"  anyOf=["string","undefined"]  has={"string":true,"undefined":true}
S.nullAsOption(string) type="anyOf"  anyOf=["string","null"]       has={"string":true,"null":true}
```

Both are `anyOf`, so neither reaches the scalar branch and no `""` is invented.

**But `anyOf` was not a single answer.** `return undefined` sits at the *bottom* of that branch,
below two arms that fire first:

```js
if(has.null) return null;
var c=firstConst(schema.anyOf); if(c!==undefined) return c;                  // option<enum>   → first variant
var obj=(schema.anyOf||[]).find(s=>s.type==="object"); if(obj) return fill(obj,{},path);  // option<record> → zero-filled {}
return undefined;                                                            // scalars and arrays only
```

`S.option(S.string)` — the one shape measured above — passes both arms and heals to `None`. An
optional **record** or **enum** does not. On the real `pluginDefinitionSchema`, with the
annotations removed:

```
option<string>  apiTarget    -> undefined  (None)  ✓
option<record>  dcbEventLog  -> {"name":"","eventTopicArn":""}   invented 2 scalars  ✗
```

`dcbEventLog` is what `manageSubscriptions` reads to wire cross-plugin SNS subscriptions, so
`Some({eventTopicArn: ""})` would have named a topic that does not exist — the failure mode the
`""` claim described, arriving through a different branch.

Fixed by one line mirroring the `has.null` guard — `if(has.undefined) return undefined;` — placed
above the two guessing arms. The `required`-aware guard an earlier draft proposed would still have
been a solution to nothing, and is not implementable besides: sury's internal `required` lists
every declared property, optionals included (`["name","opt"]` for both encodings above).

The same blind spot lived in `PluginDefinitionScalars`, whose walker also defined optional as
`has.null`; it now reads both. **Lesson for §10:** measuring through the real function was
necessary but not sufficient — the input has to cover the type shapes the change actually reaches,
and `S.option(S.string)` was one probe standing in for four.

### 6.2 The emitted JSON Schema does NOT change

The repo does not use `Sury.toJSONSchema`. Queryable schemas are emitted by
[`SuryToJsonSchema.deriveObjectSchema`](../../reventless/core/src/components/Api/SuryToJsonSchema.res),
and [`SchemaType.fromSury`](../../reventless/core/src/components/Api/SchemaType.res#L144-L156)
filters `Null(_) | Undefined(_)` **identically** — both collapse to `Nullable(...)`, which renders
as `oneOf:[T, {type:"null"}]`. `optionalFieldNames` likewise matches both. Run through the real
emitter:

```
S.option      : {"type":"object","properties":{"name":{"type":"string"},
                 "opt":{"oneOf":[{"type":"string"},{"type":"null"}]}},"required":["name"]}
nullAsOption  : {"type":"object","properties":{"name":{"type":"string"},
                 "opt":{"oneOf":[{"type":"string"},{"type":"null"}]}},"required":["name"]}
IDENTICAL
```

### 6.3 No UI work, and no golden refresh

Both follow from 6.2. `reventless-ui` reads schemas at runtime and
[`SchemaShape.res`](../../../reventless-ui/reventless/ui/src/auto/SchemaShape.res) is built on
"sury renders an optional field as a composition rather than a type" — which stays true, because
the composition is produced by *core's emitter*, not by sury's raw encoding. `AutoUI.res:452`
names the Plugin read model's `dcbEventLog` as its worked example of `anyOf:[<object>, null]`;
that field keeps its shape. The five readers keying off `required` see no change either.

Consequently `pnpm run check:graphql` should not move. If it does, something in this section is
wrong and the change should stop until it is understood.

## 7. What has to be wiped

**Narrower than "all data".** Only the 15 null-encoded constructions change: `Plugin.res` (13,
serving the 47 fields), `Offload.res` (1 — stays; it is the union codec, not an optional wrapper)
and `interop/Resource.res` (1). Domain plugin data is untouched.

### 7.1 Must be emptied

| Store | What it holds |
|---|---|
| **Platform EventLog** (DynamoDB) | Plugin lifecycle aggregate — `Connect(pluginDefinition)`, `VersionConnected(pluginDefinition)`, … |
| **Plugins QueryDb table** (DynamoDB) | `PluginsReadModelSpec` rows, incl. `structure` as untagged offload wire JSON |
| **S3 `pluginStructures`** | Content-addressed offloaded `pluginStructure` blobs |
| **S3 `pluginApiFragments`** | Content-addressed offloaded `apiSchemaFragment` blobs |

`SEED_RESET_SCOPE=platform` on `ReventlessSeedAws_Reset` selects exactly this scope — the
platform target is already declared (`{projectDir: ".", label: "platform", group: Platform}`).
The S3 stores live in **shared-layout buckets**, so they are wiped by key prefix; the tool
encodes that and refuses when declared prefixes overlap.

### 7.2 Must be drained, not emptied

In-flight SQS `Connect` messages, and warm Lambda execution environments —
`ReventlessSeedAws_Quiesce` documents why a truncate is not durable on its own: a slice runtime
keeps its TODO list in a module-level dict and re-saves every row at the end of each invocation.

### 7.3 Not affected

Domain plugin EventLogs, the DcbEventLog, and domain QueryDb tables carry domain events, not
`pluginDefinition`. This holds only while the change is confined to `Plugin.res`; the §9 sweep
would pull them in.

Domain plugins' own `pluginStructures` / `pluginApiFragments` prefixes survive a platform-scoped
wipe, since object stores are qualified `{plugin}.{store}`. Acceptable: the blobs are
content-addressed, each plugin re-offloads under a new hash, and nothing references the old keys
once the aggregate is wiped. Orphans, not a correctness problem.

### 7.4 Redeploy, not wipe

`interop/Resource.res`'s `resourceInfo` is `Output.t`-free stack-export metadata read through
StackReference — Pulumi state, not stored data. The plugin definition baked into the
EventCollector Lambda asset is rebuilt by redeploy.

### 7.5 Local platforms

SQLite: `./.reventless/local.db` by default, or wherever `REVENTLESS_LOCAL_BACKEND` points —
relative to each app, so **one file per example app**. Memory backend: nothing to do.

## 8. Downstream consumers

**No annotations to remove anywhere else.** Zero `nullAsOption` outside this repo. The
`@s.matches` sites downstream are unrelated to optional encoding: tuple-arrays
(`array<(string, exampleValue)>`) and recursive types sury cannot derive, one
`@s.matches(S.option(S.json))` already on the default encoding, and some `DcbTag.string` on
ppx-less test fixtures.

Exposure is rebuild-and-repin only: consumers depending on published core packages must be
rebuilt against the `feat!` release, and any that pin published core deps in release-mode CI
move that pin with it. The `@reventlessdev/reventless-ui` package needs nothing — it has no
sury dependency, and per §6.3 the schema shape it reads does not change, so there is no UI
change and no deploy ordering constraint.

## 9. Follow-on: `option<'a>` fields → optional (`?:`) fields

Separate change, **identical on the wire**. Both spellings derive `S.option(...)`;
`StoredEvent.res` already demonstrates it, and the encode probe confirms sury normalises an
own-property `undefined` and an absent key to the same output. Reads are unaffected (`r.foo`
still yields an `option`); only construction changes — `{foo: None}` becomes an omitted field,
`{foo: someOption}` becomes `{foo: ?someOption}`. There are ~137 `: None` sites across framework
`src`, concentrated in `Platform_Admin_Structure` (11), `PluginRuntime_Builder` (9),
`Plugin_Builder` (7) and `Dcb_Builder` (7).

Sequence it afterwards, package by package: it touches every construction site of every converted
record across core, aws, spec, local, examples and tests, and buys ergonomics only.

Verify first that the ppx handles `?:` fields identically inside **variant payloads** — these
records travel as `Connect(pluginDefinition)`, and `Message.meta` is nested rather than a variant
arm, so it is not the same evidence.

## 10. Method note — measure through the repo's own path

Every false blocker in §6 came from measuring a hand-built schema with `Sury.toJSONSchema`, a
function this repo never calls. The corrections came from importing the real
`fillMissingDefaults` and the real `deriveObjectSchema` and running both encodings through them.

The probes used here are small standalone `.mjs` files needing no ReScript build, and are worth
re-running on the next sury bump:

- **Encode probe** — bare `S.option` vs `S.nullAsOption` vs `S.nullableAsOption`, as a record
  field and inside a positional variant payload, absent and present, to `S.json` and
  `S.jsonString`, plus round-trip. Establishes §4.
- **Wire-compat probe** — cross-parsing a legacy `null`-carrying payload and an omitted-key
  payload against both schemas. Establishes §5.
- **Emitter probe** — `deriveObjectSchema` and `fillMissingDefaults` imported from the built
  `.res.mjs`, both encodings compared. Establishes §6.

# Removing the Per-Field Optional Annotations — What Blocks It, and Why the Fix Is Ours Not Sury's

**Scope.** Why every optional field on `pluginDefinition` / `pluginStructure` carries an
`@s.matches(...OptionSchema)` annotation, whether sury or sury-ppx can be configured to avoid
that (they cannot), and — given a willingness to discard stored alpha data — how to reach **zero
annotations with the current sury version and no upstream request**. The remaining blocker turns
out to be a missing guard in this repo's own schema healer, not a sury limitation. Written
2026-09-04 against `sury@11.0.0-rc.2`.

**Files reviewed**
- [`Plugin.res`](../../reventless/spec/src/components/Plugin.res) — the 47 annotated sites and the four helper bindings
- [`Message.res`](../../reventless/spec/src/types/Message.res) — `meta` (unannotated optionals), `fillMissingDefaults`, `parseJsonTolerant`
- [`StoredEvent.res`](../../reventless/spec/src/types/StoredEvent.res) — `storedEvent.tags?` (unannotated optional field)
- [`PluginSpec.res`](../../reventless/core/src/plugin/lifecycle/PluginSpec.res) — `| Connect(pluginDefinition)`, the variant payload these records travel in
- [`Util_Sury.res`](../../reventless/spec/src/util/Util_Sury.res) — the encode/decode path everything goes through
- [`PluginDefinitionRequiredScalarsTest.res`](../../reventless/core/tests/plugin/PluginDefinitionRequiredScalarsTest.res) + `pluginDefinitionRequiredScalars.txt` — the schema-evolution rule
- [`plugin-definition-schema-evolution-wedge.md`](./plugin-definition-schema-evolution-wedge.md) — the incident the rule came from
- `node_modules/sury-ppx/README.md`, `node_modules/sury/index.mjs` — the configuration surface

---

## 1. The requirement

Annotations should be minimal, and ideally absent. Writing `@s.matches(stringOptionSchema)` on
every optional field — 47 times in one file — is repetition the tooling should absorb. The
preference is one globally consistent approach with no per-field, per-type or per-file
annotation of any kind.

## 2. Verdict

**Reachable today, with the current sury, and with no upstream request** — provided the
null-encoded wire format is abandoned and stored alpha data is discarded.

Sury's *default* for `option<'a>` is already the annotation-free form. So the goal is reached by
**deleting** the 47 annotations and the four helper bindings, not by adding a feature. It also
makes the repo internally consistent: 53 optional-schema constructions already use the default
form against only 15 that do not (§4.1).

Two blockers stand between here and there. One is removed by a data wipe (§4.2). The other is
**not** — but it lives in this repo's own healer, and is a ~2-line fix (§4.3, §5).

If the null-encoded format is instead kept, per-field annotation is unavoidable: there is no
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
divergence. Even if the knob existed, this is the wrong mechanism for this data.

**sury-ppx configuration.** There is none. Install is `"ppx-flags": ["sury-ppx/bin"]` with no
arguments, and the binary exposes only generic ppxlib driver flags (`-apply`, `-dont-apply`,
`-cookie`, `-loc-filename`, `-no-merge`, …). ReScript's `ppx-flags` *does* accept an array form
(`"ppx-specs": {"items": {"oneOf": [{"type":"string"}, {"type":"array", …}]}}`), so a compile-time
flag would be a valid shape — sury-ppx simply doesn't read one.

**sury-ppx's API surface.** The complete reference is nine attributes: `@schema`, `@s.matches`,
`@s.null`, `@s.nullable`, `@s.default`, `@s.defaultWith`, `@s.meta`, `@s.with`, and the
`@s.strict` / `@s.strip` / `@s.deepStrict` / `@s.deepStrip` / `@s.noValidation` group. `@s.null`
— which emits exactly what the helper bindings emit — is documented as applying to "option type
expressions, optional record fields", i.e. field level only. There is no file-, module- or
project-level default.

## 4. The two blockers

### 4.1 The repo is already mostly annotation-free

Constructions in committed `src` output:

| | sites |
|---|---|
| undefined-encoded (`Sury.$option`) | **53** |
| null-encoded (`nullAsOption`) | **15** |

and the split runs *through* `reventless/spec/src`:

```
null-encoded:      Plugin.res (13), Offload.res (1)
undefined-encoded: Message.res (7), StoredEvent.res, Identity.res,
                   Owner.res, Sensitive.res, CapabilityManifest.res, CaptionedImage.res
```

`meta` is on every message and `storedEvent` *is* the EventLog row, so the annotation-free form
demonstrably works on the wire in this codebase today. `Plugin.res` is the outlier, not the rule.

### 4.2 Wire format — removed by a data wipe

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
between separately deployed plugins and the admin. So this blocks the change **only** while old
data and old deployments exist. Discarding alpha data and redeploying the fleet from one commit
removes it. See the migration checklist in §7.

### 4.3 The healer fabricates `""` for absent optionals — NOT removed by a wipe

This is the blocker that survives the wipe, and the real work the null shape was doing.
`fillMissingDefaults` walks the JSON Schema, and the two encodings land in different branches:

```js
case "anyOf": {                          // what nullAsOption emits
  var has=schema.has||{};
  if(value===undefined){
    if(has.null) return null;            // absent → null → decodes to None ✓
default: {                               // what bare S.option emits: {"type":"string"}
  if(value!==undefined) return value;
  var d=scalarDefault(schema);           // "" / 0 / false
  scalarFills.push(path + " := " + JSON.stringify(d));
  return d;                              // absent → "" → decodes to Some("") ✗
```

Because `S.option` emits a bare `{"type":"string"}`, the healer cannot distinguish an **absent
optional** from a **missing required scalar**, and invents `""`. `None` silently becomes
`Some("")` — on fields like `retiredField`, `ownerField` and `requiredAccess`, where empty and
absent mean different things to the resolvers.

The healer only runs after a first parse failure (`parseJsonTolerant`), but it then walks the
*whole* message — so any one evolved field drags every absent optional in the payload through
this branch. In an actively evolving framework that is routine, which is why this hazard is
permanent rather than a legacy-data artifact.

The JSON Schema difference that causes it:

```
bare         : "requiredAccess":{"type":"string"}
               required:["name"]
nullAsOption : "requiredAccess":{"anyOf":[{"type":"string"},{"type":"null"}]}
               required:["name","requiredAccess"]
```

## 5. The fix is ours, not sury's

`fillMissingDefaults` is hand-written `%raw` JS in this repo, and the JSON Schema **already
carries `required`** with the optional field correctly excluded. The object branch simply
doesn't consult it:

```js
case "object": {
  …
  var props=schema.properties||{};
  var names=Object.keys(props);
  for(var i=0;i<names.length;i++){ var n=names[i]; value[n]=fill(props[n], value[n], path+"."+n); }
  return value;
}
```

Making it `required`-aware — skip filling a property that is absent and not listed in
`schema.required` — restores the distinction:

- absent **optional** → stays absent → decodes to `None` ✓
- absent **required scalar** → filled and reported in `scalarFills` ✓ (unchanged; this is what
  `PluginDefinitionRequiredScalarsTest` and its golden exist to police)

With that guard in place the annotation-free form is safe, and no sury change is needed.

## 6. What this means for an upstream request

**Nothing needs to be requested.** Earlier drafts of this analysis proposed a file-level
`@@s.nullOptionals`, a type-declaration-level `@s.deepNull`, or a ppx build flag. All three were
solving "how do we keep the null encoding cheaply". Dropping the null encoding makes sury's
existing default the globally consistent, zero-annotation approach, and the only thing that made
that default unsafe here was the missing guard in §5.

Retain the option to file it only if the decision goes the other way — i.e. if the null-encoded
format is kept for `pluginDefinition`, in which case §3 shows per-field annotation is forced and
a file-level default is the smallest ask that fixes it.

## 7. Migration checklist

1. Make `fillMissingDefaults` `required`-aware (§5). **Do this first and independently** — it is
   a correctness fix on its own terms and is safe under either encoding.
2. Delete the 47 `@s.matches` annotations and the four helper bindings (`stringOptionSchema`,
   `stringArrayOptionSchema`, `boolOptionSchema`, `dcbEventLogOptionSchema`) from `Plugin.res`.
   Leave the two `Offload` fields alone — those need the union codec, not an optional wrapper.
3. Wipe the stores listed in §8; redeploy the whole fleet from one commit so no deployed
   plugin is left registering in the old format.
4. `feat!` — `reventless-spec` is published on every alpha push, so external consumers compile
   against whichever shape they installed.
5. Refresh the GraphQL contract goldens: the JSON Schema shape changes (`anyOf:[T,null]` +
   required → plain `T`, not required), so `pnpm run check:graphql` will move.
6. Rewrite `pluginDefinitionRequiredScalars.txt`'s guidance. Its current advice — *"If your new
   field can be absent, give it the `js_nullable` (`T | null`) shape"* — becomes obsolete;
   under the new rule the answer is "make it optional". The tripwire itself still works: optional
   fields are not required scalars and stay off the list either way.
7. Rewrite the stale comment at [`Plugin.res:76-77`](../../reventless/spec/src/components/Plugin.res#L76-L77) and its duplicate in [`Resource.res:5-10`](../../reventless/interop/src/Resource.res#L5-L10) (§10).

## 8. What has to be wiped

**The blast radius is narrower than "all data".** Only the 15 null-encoded constructions change:
`Plugin.res` (13, serving the 47 fields), `Offload.res` (1 — stays, it is the union codec, not an
optional wrapper) and `interop/Resource.res` (1). So only stores carrying `pluginDefinition` /
`pluginStructure` are affected; **domain** plugin data is untouched.

### 8.1 Must be emptied

| Store | What it holds | Why |
|---|---|---|
| **Platform EventLog** (DynamoDB) | Plugin lifecycle aggregate — `Connect(pluginDefinition)`, `VersionConnected(pluginDefinition)`, … | Every event payload embeds the changed record |
| **Plugins QueryDb table** (DynamoDB) | `PluginsReadModelSpec` rows, incl. `structure` as untagged offload wire JSON | Projected from the above; rows carry the old encoding |
| **S3 `pluginStructures`** | Content-addressed offloaded `pluginStructure` blobs | The offloaded blob's *inner* schema is the changed record |
| **S3 `pluginApiFragments`** | Content-addressed offloaded `apiSchemaFragment` blobs | Same field group ([Plugin.res:496](../../reventless/spec/src/components/Plugin.res#L496), [:502](../../reventless/spec/src/components/Plugin.res#L502)) |

Both S3 stores live in **shared-layout buckets** — one bucket holds several plugins' stores under
distinct key prefixes — so they must be wiped **by key prefix**, not by bucket.
`ReventlessSeedAws_Reset` already encodes this and refuses when two declared stores' prefixes
overlap or enclose one another.

### 8.2 Must be drained, not emptied

- **In-flight SQS messages** carrying `Connect(pluginDefinition)` — a queued command written in
  the old encoding will fail to decode after the change.
- **Warm Lambda execution environments.** `ReventlessSeedAws_Quiesce` documents why a truncate is
  not durable on its own: a slice runtime keeps its TODO list in a module-level dict and re-saves
  every row it holds at the end of each invocation, so an emptied table is restored byte for byte
  by the next sweep. The hold-then-recycle sequence there is required, not optional.

### 8.3 Not affected — no wipe

- **Domain plugin EventLogs, the DcbEventLog, and domain QueryDb tables.** They carry domain
  events and projections, not `pluginDefinition`. *Caveat:* this holds only while the change is
  confined to `Plugin.res`. If the §9 `?:` sweep or a wider annotation removal reaches domain
  specs, their stores come into scope and this row no longer applies.

### 8.4 Redeploy, not wipe

- **`interop/Resource.res`'s `resourceInfo`** is `Output.t`-free stack-export metadata resolved at
  deploy time, read by consumers through StackReference — Pulumi stack state, not stored data.
  `pulumi up` refreshes it.
- **The plugin definition baked into the EventCollector Lambda asset** is rebuilt by redeploy.

### 8.5 Local platforms

- **SQLite backend** — `./.reventless/local.db` by default, or wherever `REVENTLESS_LOCAL_BACKEND`
  points. The path is relative to each app, so this is **one file per example app**, not one
  shared store.
- **Memory backend** — nothing to do; a restart clears it.

### 8.6 Tooling

Prefer `seed:reset` (`ReventlessSeedAws_Reset`) over hand-deleting tables: it discovers every
DynamoDB table and S3 bucket for a stack by tag, is fail-closed, and offers a dry run plus a typed
confirmation. `_Quiesce` performs the hold/recycle of §8.2 and `_Reconcile` verifies the result.
[`clearing-aws-eventlog-querydb-tables.md`](./clearing-aws-eventlog-querydb-tables.md) covers the
`pulumi destroy --target` alternative, which is the right tool when tables must be **recreated**
(changed keys or GSIs) rather than emptied — not the case here.

Given that alpha data is disposable and a targeted wipe risks missing a carrier, wiping
everything in scope is the cheaper mistake.

## 9. Follow-on: `option<'a>` fields → optional (`?:`) fields

Separate change, **identical on the wire**. Both spellings derive `S.option(...)`; the `?` only
changes the ReScript-side representation. `StoredEvent.res` already demonstrates it
(`tags?: array<DcbTag.tag>` → `s.f("tags", Sury.$option(...))`), and the encode probe confirms
sury normalises an own-property `undefined` and an absent key to the same output.

Reads are unaffected (`r.foo` still yields an `option`); only construction changes —
`{foo: None}` becomes an omitted field, `{foo: someOption}` becomes `{foo: ?someOption}`. There
are ~137 `: None` sites across framework `src`, concentrated in `Platform_Admin_Structure` (11),
`PluginRuntime_Builder` (9), `Plugin_Builder` (7) and `Dcb_Builder` (7), so the readability win
is real.

**Sequence it after §7, not with it.** The conversion touches every construction site of every
converted record across core, aws, spec, local, examples and tests, and buys ergonomics only. If
it lands in the same commit as the wire migration, a mistake in the wide mechanical sweep becomes
indistinguishable from a problem with the migration.

One thing to verify first: that the ppx handles `?:` fields identically inside **variant
payloads** — these records travel as `Connect(pluginDefinition)`, and `Message.meta` is nested
rather than a variant arm, so it is not quite the same evidence. A compile-and-diff on one type
settles it.

## 10. The rationale currently in the file is stale

[`Plugin.res:76-77`](../../reventless/spec/src/components/Plugin.res#L76-L77) says:

> js_nullable (T | null) is the only optional that passes jsonableValidation inside union
> variant payloads; nullableAsOption adds `undefined` and fails it.

**No longer true.** Measured on rc.2, reproducing the exact shape — a record with a bare
`S.option(S.string)` field inside a positional variant payload mirroring
`PluginSpec.command = | Connect(pluginDefinition)`, encoded through `Util_Sury`'s own path:

```
=== bare S.option (ppx-derived) ===
  record   absent   -> json      : ok  {"name":"p"}
  record   absent   -> jsonString: ok  "{\"name\":\"p\"}"
  variant  absent   -> json      : ok  {"TAG":"Connect","_0":{"name":"p"}}
  variant  absent   -> jsonString: ok  "{\"TAG\":\"Connect\",\"_0\":{\"name\":\"p\"}}"
  variant  absent   round-trip  : ok  {"TAG":"Connect","_0":{"name":"p"}}
```

All twenty cells pass. The failure was real on alpha.10 and was fixed by #311 in alpha.11; the
comment outlived its cause. It should be rewritten whichever way the decision goes — it
currently documents a fixed bug as the reason for a constraint that holds for the different
reason in §4.3.

## 11. Reproduction

Two probes, both run against `sury@11.0.0-rc.2` with the encode path taken verbatim from
`Util_Sury` (`S.decodeOrThrow(value, schema, Sury.json | Sury.jsonString)`):

- **Encode probe** — bare `S.option` vs `S.nullAsOption` vs `S.nullableAsOption`, each as a
  record field and inside a positional variant payload, absent and present, to `S.json` and
  `S.jsonString`, plus round-trip. Establishes §10.
- **Wire-compat probe** — cross-parsing a legacy `null`-carrying payload and an omitted-key
  payload against both schemas, plus `Sury.toJSONSchema` on each. Establishes §4.2 and §4.3.

Both are small standalone `.mjs` files importing sury directly; they need no ReScript build and
are worth re-running on the next sury bump.

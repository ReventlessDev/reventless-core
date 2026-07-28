# Plan: generic semantic marker + `StorageRef` as the first semantic type

**Date:** 2026-07-28
**Status:** DONE 2026-07-28 (`aa18afcf0` foundation, `44f15c37d` StorageRef) — all six steps landed.
Build clean, suite 2240/2240. The re-expression met its acceptance criterion: `SuryToJsonSchemaTest`,
`PluginStructureTest` and `GraphQL_FragmentGeneratorTest` pass untouched. The command-field proof
holds — `ChangeProductImage.imageUrl` carries `x-reventless-semantic` on a *command*, which the
annotation path structurally cannot reach.

Two departures from the sketch, both forced by the same fact — that the marker refines an existing
`string` field rather than replacing it, which is what lets it be retrofitted with no stored value
changing. (1) `StorageRef.t` is transparent, not abstract: `@s.matches` requires the schema's type to
match the field's, so sealing it would change the field's runtime type. The `StringPure` mitigation
is therefore moot. (2) The empty string is admitted as the no-object sentinel — these fields are
non-optional and producers with nothing to reference already write `""`; rejecting it would force the
event-schema change this plan exists to avoid. `fromString` stays exact. Making those fields properly
optional is what retires the sentinel.

Step 5's open question resolved: the injection site is *not* gated on `type state`. `ReferenceInference`
(not `StateAnnotations.ml`, as this plan guessed) is the model, and it walks every type declaration —
so `@storageRef` reaches commands and events with no gate needing to move.

The step-1 payload is a typed variant rather than `option<JSON.t>`: the vocabulary is framework-owned
and closed, and it keeps `Reference.getTarget` total instead of a decode that can fail at runtime.

Not done here: the per-platform PPX binary packages must be republished by CI before any downstream
repo can use `@storageRef`.
**Repos:** `reventless-core` (this plan) — `reventless-ui` ships the reader half under its own plan.
**Analysis:** [platform-main-capability-provisioning.md](../../analysis/platform-main-capability-provisioning.md)
§5.1, §5.6, §7 Stages 0.5–1.

## Why

Two typed markers ship today and each is bespoke. `DateTime` sets its own `dateTimeId`
([DateTime.res](../../../reventless/spec/src/types/DateTime.res)); `Reference` sets its own
`referenceId` ([Reference.res](../../../reventless/spec/src/components/Reference.res)); and
`SchemaType.fromSury` detects both by hardcoded special case
([SchemaType.res:15](../../../reventless/core/src/components/Api/SchemaType.res#L15) and `:30`). There
is no generic "this field's type carries a semantic" machinery, so **every new typed marker is new
detection code**.

That is the gap blocking the capability declaration. `@storageRef("productImages")` is specified to
inject `@s.matches(Reventless.StorageRef.forStore(…))` — a type refinement, not a string annotation
— so the store identity rides on the field's *type*, and nothing reads type-carried semantics
during the schema walk today.

The decisive detail (§5.6): `x-reventless-semantic` is emitted **only** by `mergeAnnotations`
([SuryToJsonSchema.res:14-90](../../../reventless/core/src/components/Api/SuryToJsonSchema.res#L14-L90),
key set at `:71-73`), which is fed by the PPX-collected `spec.semantic` array and therefore reaches
**read-model `state` records only** — the PPX gates every injection site on
`ptype_name.txt = "state"` (11 sites in
[StateAnnotations.ml](../../../packages/reventless-ppx/src/ppx/StateAnnotations.ml)). The *other* path
— `toJsonSchema` → `deriveObjectSchema` → `fromSchemaType` (`:91-162`) — is schema-shape-driven,
never consults `spec`, and walks **any** schema including commands and events.

So teaching the generic walk to read one shared marker is both cheaper than the 11-site PPX
ungating and strictly more capable: it reaches command fields, which is where the upload
declaration has to live.

## Scope boundary

**In:** one generic marker in `reventless/spec`; a generic read + emit in the schema walk;
`DateTime` and `Reference` re-expressed on it (no behavior change); `StorageRef` as the first real
semantic type; the `@storageRef` PPX shorthand; annotating the example plugin's fields.

**Out:** provisioning anything (Stage 2), capability collection into `Plugin_Structure` (Stage 2),
inference and `generate-platform` (Stage 3), the wider value-type library — `Money`, `GeoPoint`,
`DateRange` and the rest (Stage 5). Ungating `@semantic` from `type state` is explicitly **not**
here (§5.6): it buys the string annotation on commands, which the type path already covers for the
declared case.

**No infrastructure and no event-schema change.** After this plan the requirement is *stated* and
malformed refs are *rejected*; nothing new is deployed.

## Steps

### 1. `Semantic.mark` — one marker for all typed semantics

New `reventless/spec/src/semantic/Semantic.res`:

```rescript
/** The shared sury metadata id every semantic type marks itself with. */
let semanticId: S.Metadata.Id.t<string> = S.Metadata.Id.make(~namespace="reventless", ~name="semantic")

let mark = (schema, id) => schema->S.Metadata.set(~id=semanticId, id)
let get = (fieldSchema: S.t<unknown>) => S.Metadata.get(fieldSchema, ~id=semanticId)
```

The payload is the semantic id string — the same vocabulary the wire key already carries, so the
type path and the existing annotation path converge on one wire format rather than two.

Some semantics need more than an id (a `StorageRef` carries `{plugin, store}`; `Reference` already
carries `{entity, plugin}`). Decide the shape **now**, before three types make it expensive:
either a second metadata id for per-type payloads, or make `semanticId` carry
`{id: string, payload: option<JSON.t>}`. Recommendation: the latter, so one `get` answers both
questions and the walk has one thing to read.

### 2. Read it generically in the schema walk

- `SchemaType.fromSury` — read `Semantic.get` generically. The two existing special cases become
  consumers of the generic read rather than independent branches.
- `SuryToJsonSchema` — emit `x-reventless-semantic` (and the payload, where present) from the
  generic walk in `deriveObjectSchema` / `fromSchemaType`, **not** from `mergeAnnotations`. This is
  the one genuinely new piece of code in the plan.

Precedence when both a type marker and a `spec.semantic` annotation name the same field: **the type
wins**, and the conflict is worth surfacing as a build-time warning rather than silently resolving —
it means the domain says two things about one field.

### 3. Re-express `DateTime` and `Reference` on the generic marker

Retire `dateTimeId` and `referenceId`. The acceptance criterion is **zero behavior change**:
`format: "date-time"` and `format: "uuid"` still emit, the DCB tag still routes, the existing
`SuryToJsonSchemaTest` and `PluginStructureTest` expectations still pass unchanged.

Note the coupling at `SchemaType.res:30`: `Reference` detection is bundled with `isTagged` in one
condition. Decouple carefully — reference-ness and DCB-tagged-ness are separate facts that happen
to co-occur, and conflating them here is what would make a later `StorageRef` (marked, *not*
DCB-tagged) misclassify.

### 4. `StorageRef` — the first new semantic type

`reventless/spec/src/semantic/StorageRef.res`, following the `Id.T` shape
([Id.res](../../../reventless/spec/src/types/Id.res)) rather than inventing a convention:

```rescript
type t                                            // abstract — the invariant is unbypassable
let forStore: (~plugin: string, ~store: string) => S.t<t>
let fromString: string => result<t, string>       // primary — says why it failed
let unsafe: string => t                           // trusted-decode path (already-validated rows)
let toString: t => string
```

Decisions, each following the analysis:

- **Abstract `t`.** `Id.T` already seals its `t` "so IDs from different aggregates cannot be
  mixed", and ships a transparent `StringPure` alongside the sealed `String` for test ergonomics.
  Mirror both — the transparent flavor is what keeps tests writable without casts.
- **Derive the validator from the schema** (`schema->S.parseOrThrow`), never a second hand-rolled
  check, so the constructor and the sury validation cannot drift.
- **The format is a framework decision, not an app one.** A ref must be recognizable as belonging
  to *this* store — that is what closes §3.4, where today any external `https://…` URL or `data:`
  URI can be appended to the event log permanently. Pin the ref grammar in this module's doc
  comment; the presign service mints refs in exactly that form.

### 5. The `@storageRef("<store>")` PPX shorthand

Injects `@s.matches(StorageRef.forStore(~plugin, ~store))` onto the field's type. The `@partitionTag`
handling in [StateAnnotations.ml](../../../packages/reventless-ppx/src/ppx/StateAnnotations.ml) is the
model — it already injects `@s.matches(Reventless.DcbTag.string)`.

Unlike `@semantic`, this must work on **command and event** records, not just `type state`. The
injection is a type refinement on the field, so it does not need the annotation-collection
machinery the 11 state gates guard — verify that during implementation; if the injection site
itself turns out to be gated, that gate (and only that one) has to move.

The `plugin` argument is ambient at construction time, the way `ResourceAttribution` already
supplies plugin/platform to `AWS_Tags`. Prefer reading it from there over threading it through the
annotation.

### 6. Annotate the example plugin

`ChangeProductImage.imageUrl`, `AddProduct.imageUrl`, `Products.state.imageUrl`. This is the proof
the declaration reaches a command field — the case `@semantic` structurally cannot express.

## Verification

- **The command-field proof.** `ChangeProductImage`'s emitted JSON Schema carries
  `x-reventless-semantic` with the store identity. This single assertion is the plan's reason to
  exist; nothing before step 5 demonstrates it.
- **No-regression on the re-expression.** `SuryToJsonSchemaTest` and `PluginStructureTest` pass
  **unchanged** after step 3 — if either needs editing, the re-expression changed behavior and the
  diff needs explaining.
- A malformed `imageUrl` is rejected by the schema *before* `decide` runs. Assert in a GWT spec —
  no I/O, so it holds identically on local and AWS.
- Full root build green, and no `.res.mjs` churn beyond the intended files
  (`git status | grep 'D.*res.mjs'` before committing).

## Risks

| Risk | Mitigation |
|---|---|
| **The `Reference`/`isTagged` decoupling at `SchemaType.res:30` silently changes DCB routing.** This is the highest-consequence step in the plan — routing failures are not visible in a schema diff. | Land step 3 as its own commit with the existing tests untouched. If DCB routing tests do not currently cover the distinction, add coverage *before* the refactor, not after. |
| Payload shape (step 1) chosen wrong, discovered at the third semantic type. | Decide it in step 1 with `StorageRef` (`{plugin, store}`) and `Reference` (`{entity, plugin}`) both in hand — two payload-bearing cases is enough signal. |
| **Abstract `t` breaks existing test code** that writes `imageUrl` as a plain string literal. | Ship the transparent `StringPure`-equivalent alongside, exactly as `Id` does. |
| The ref grammar is pinned wrong and a later store layout cannot express it. | Stage 2 moves stores into plugin stacks with per-store prefixes; sketch that path shape now and make sure the grammar admits it, even though Stage 2 is out of scope. |
| Retrofitting `StorageRef` onto an existing field changes an event schema. | It does not — the annotation refines the *type* of an existing `string` field; the runtime representation is unchanged. This is exactly why the annotation lands before the fuller `UploadableFile.t` migration. |

## Sequencing note

Independent of [platform-capability-provisioning-stage-0.md](./platform-capability-provisioning-stage-0.md)
— neither blocks the other, and they can run in parallel. Stage 0 repairs live operational defects,
so it should not queue behind this plan.

# Plan: derive the admin API SDL from the schemas it already has

**Status.** Step 0 **built 2026-08-27** (`reventless/core/tests/admin/AdminApiSchemaDriftTest.res`).
Steps 1–5 are unbuilt. Read "When to stop" before starting step 2 — step 0 alone
buys most of the safety, and the remaining steps are only worth it if step 1
lands for reasons of its own.

## The thing

Three modules publish a GraphQL surface as hand-written SDL strings beside
hand-written JSON encoders:

| Module | Query | Types |
| --- | --- | --- |
| `Platform_ComponentDefinitionsApi.res` | `Platform_ComponentDefinitions` | 12 |
| `Platform_PluginStructuresApi.res` | `Platform_PluginStructures` | 4 |
| `Platform_UIFragmentsApi.res` | `Platform_UIFragments` | 4 |

Each field is therefore stated three times: on the `@schema` record in
`reventless/spec/src/components/Plugin.res`, in an SDL string, and in an encoder.
The strings are not an oversight — they were lifted verbatim out of the in-memory
adapter when the AWS resolver was added (`docs/plans/done/aws-platform-uidefinitions-resolver.md`),
which deduplicated them *across adapters*. Deduplicating them *against the types*
was never attempted.

The failure mode is one-directional and silent: a field added to the record and
the encoder but not the SDL is encoded on every response and selectable by
nobody. `chapter` and `externalSystem` were in that state for months.

## Step 0 — the drift guard (built)

`AdminApiSchemaDriftTest.res` reads, for each of the 20 GraphQL types, three
field-name sets — the sury schema (`SchemaType.fromSuryObject`), the SDL block,
and the encoder's output keys — and asserts they agree modulo two explicit
allowlists per type (`wireOnly`, `recordOnly`). 101 tests.

Two facts it records that were previously only implicit:

- `Platform_ComponentDefinitionEntry` deliberately drops `extensionPoints`,
  `requiredStores` and `requiredStoreDeclarations` — those are the
  `Platform_PluginStructures` contract.
- `derivedPages` is emitted by `encodePluginStructureEntry` only when
  `~derived` is passed, which only `Platform_BakedManifest` does. It is
  correctly absent from the SDL; the guard pins that rather than leaving it
  looking like the bug it resembles.

This closes the silent half. What it does not do is remove the third statement of
each field — a new field still has to be written in three places, and the guard
only says so after the fact.

## Step 1 — object types can carry their own name

This is the load-bearing step, and it is not really about the admin API.

`SchemaType.shapeOf` names a nested object by the path that reached it:
`parentName ++ Capitalize(fieldName)`. So one record used by two fields is
emitted as **two identical types under two names**, and a shared type has no way
to name itself. The generator already has two special cases working around this —
`semanticCompositeNames` / `canonicalName` for `Money`, `DateRange`, `GeoPoint`
(the comment there records six copies of ISO 4217 in one example schema), and
`Reventless.TaggedUnion.named` for unions, which reads the name off the schema
for exactly this reason.

Generalise it: a marker that puts a GraphQL type name on any record schema, read
in `shapeOf`'s `Object` branch ahead of the path-derived name, with the
path-derived name as the fallback. The union precedent settles the shape — the
name lives on the schema, because the SDL emitter and the write-time `__typename`
stamp both reach a field by different routes and must agree.

Independent of this plan, that closes a real generality gap in domain SDL: today
any read model with two fields of the same nested record ships two definitions of
it, and merged-API composition unions types only when they are *identically
named*.

## Step 2 — wire records for the leaf component defs

`pluginStructureSchema` is **not** a candidate source. It is the persistence
format: `pluginStructure` is carried offloaded inside a Plugin lifecycle event
(`Plugin.res`, `pluginStructureOffloadSchema`), replayed before every
registration decision. Reshaping it to suit GraphQL rewrites the event log, and
adding a required field to it has wedged registration once already.

So the source is a **new `@schema` record per GraphQL type**, declared in the
admin API module, plus a total mapping function from the persisted record to it.
That drops three statements of a field to two, and the second one is
compiler-checked: an unmapped field is a missing-field error at a record literal,
not an omission nobody sees.

Derive the SDL from those records via
`GraphQL_FragmentGenerator.deriveObjectTypeWithNested(~includeIdParam=false)`,
and **keep the hand-written encoders**. Step 0's "every declared field is
encoded" test then compares the derived SDL against the encoders that have been
serving the current SDL — which is the cheapest available proof that the
derivation reproduces the contract.

### The wire deltas a naive derivation produces

Every one of these is a breaking change on a published, merged AppSync surface,
and each needs a deliberate answer before the strings come out:

| Today | Derived | Cause |
| --- | --- | --- |
| `pluginId: String!` | `pluginId: ID!` | `isIdFieldName` promotes any `*Id` string to `EntityId` |
| `fragmentId: String!` | `fragmentId: ID!` | same |
| `sortOrder: Int!` | `sortOrder: Float!` | `Number(_) => ScalarNumber`; sury's `int` is not distinguished |
| `level: String!` | `level: <enum>!` + a new `enum` definition | all-const `AnyOf` → `Enum` |
| `namedWhenRetired: Boolean!` | `namedWhenRetired: Boolean` | the record field is `option<bool>`; the encoder defaults it to `false` |
| `readModels: [Platform_ReadSideDef!]!` | `[Platform_ComponentDefinitionEntryReadModels!]!` | step 1 |
| `menuEntry: Platform_UIMenuEntry!` | `Platform_UIPageMenuEntry!` | step 1 |

Nullability itself is *not* a delta: `S.nullAsOption` reaches the walk as an
`AnyOf` with one non-null arm → `Nullable` → no `!`, which is what the strings
already say. That is the good news in this table — the 100-odd ordinary fields
land byte-identically.

The first five are settled by shaping the **wire record** rather than by adding
switches to the generator: name the field so `isIdFieldName` does not fire (or
accept `ID!` as an improvement and take the breaking change once), declare
`namedWhenRetired: bool` and default in the mapping, declare `level: string` and
render the variant in the mapping. Each is a line in one place instead of a
generator flag every caller inherits.

## Step 3 — encoders from sury

With a wire record whose shape *is* the wire, the encoder is
`S.reverseConvertToJsonOrThrow`. Two things to check first:

- **Key order changes.** `queryableDef` declares `ownerField`/`retiredField`/…
  before `visibility`; the encoder emits them after. Several sibling tests assert
  multi-key substrings of `JSON.stringify` output (`Platform_ComponentDefinitionsApiTest.res`
  around the translation-slice cases). Those assertions have to become key-wise.
- **`Plugin.name(pluginId)`** is a computed value, not a field copy — it belongs
  in the mapping function, not the schema.

## Step 4 — the two entry types

`Platform_ComponentDefinitionEntry` and `Platform_PluginStructureEntry` are views
over `pluginStructure`, not the structure itself: `pluginId` is computed,
`internalQueryables` is the complement of the Internal filter, and the AutoUI
entry drops three fields the tooling entry keeps. Under step 2 each becomes its
own wire record with its own mapping — which is where the filtering already lives
anyway, just typed.

`derivedPages` stays outside the schema. It is a baked-manifest key with an
absent-vs-`[]` distinction sury's option encoding cannot express, so
`encodePluginStructureEntry`'s `~derived` arm survives as a post-hoc
`Dict.set` on the derived object.

## Step 5 — remove the strings, refresh the goldens

`pnpm run check:graphql` will move. Refresh in the same commit — the schema diff
is the review artifact for this whole plan, and it is the only place the deltas
in step 2's table become visible as a single reviewable thing.

Note the stitcher dedupes definitions by leading name
(`GraphQL_Stitcher.extractLeadingName`), so the component-level types shared
between the two queries continue to be emitted once — provided step 1 makes both
modules name them identically. Without step 1 they would not, and the merged
document would carry two definitions of the same thing.

## When to stop

Step 0 removes the silence; steps 1–5 remove the duplication. They are not the
same value, and the second is much more expensive:

- **Stop after step 0** if nothing else wants step 1. The remaining cost is that
  a new field is written three times, and a guard tells you within one test run
  when you wrote it twice.
- **Do step 1 regardless** if any domain read model needs a shared nested record
  named once — it is a generator gap on its own terms, and this plan is then a
  consumer of it rather than the reason for it.
- **Do not do steps 2–5** while the delta table is still growing. Every entry in
  it is a breaking change to a live merged API, and a derivation that needs seven
  hand-written exceptions has not removed the hand-writing, only moved it
  somewhere less visible than a string that says what it means.

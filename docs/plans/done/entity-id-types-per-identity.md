# Plan: one Id type per identity

**Status:** Done (2026-09-21).<br/>
**Analysis:** [entity-id-types-per-identity.md](../../analysis/entity-id-types-per-identity.md). The
findings (F1–F6), the design and the recommendations are there; this plan only orders the work.<br/>
**Touches:** `reventless-spec` (`Id`, `Semantic`, `Reference`, `DcbTag`, `DcbScopeInference`,
`Projection`, `StateViewSlice`, `StateChangeSlice`), `reventless-core` (`SchemaType`,
`SuryToJsonSchema`, `GraphQL_FragmentGenerator`, `Plugin_Structure`, projection builders),
the local and AWS query resolvers (Phase 0 only), `reventless-ppx`, `scripts/check-dcb-scope.mjs`,
and the online-shop examples.

## Goal

Two ids of different entities have different types, so the compiler rejects a mix-up. The
framework recognises an identity from its type rather than its field name, and derives a
reference whenever exactly one view is keyed by that identity.

## Hard constraints (every phase)

- **A spec that does not adopt identities compiles unchanged and behaves unchanged.**
  Adoption is opt-in per plugin. Each phase's validation includes building every example
  *before* it is migrated. **One intended exception (Phase 6):** a read-model projection is
  typed by its source's and target's `Id`, so one that keys a row by a payload `string`, or
  stores the envelope id into a `string` field, now converts explicitly. It still *behaves*
  unchanged.
- **No wire change for an existing field.** JSON, stored events, tags and the SDL of every
  field that is not retyped stay byte-identical.
- **No DCB slice may carry a typed id before Phase 4 is released.** Until then a typed field
  silently loses its DCB tag (analysis F4).

## Order

| Phase | What | Depends on | Released as |
|---|---|---|---|
| 0 | Stop publishing an aggregate read model's foreign id as its key | — | independent patch |
| 1 | Spike: `Make` against sury and the PPX, on one real spec | — | nothing (decision) |
| 2 | `Id.Make`, the `identity` semantic, JSON Schema and SDL typing | 1 | **Checkpoint A** |
| 3 | The runtime reads identities (tags, partitions, read-model key) | 2 | with 4 |
| 4 | The PPX accepts identity-typed fields; spec packages skip `module Id` | 3 | **Checkpoint B** |
| 5 | Derived and checked references; identity checks beside `check:dcb-scope` | 4 | minor |
| 6 | Typed projections and row keys; drop `StateChangeSlice.Spec.Id` | 4 | minor |
| 7 | Migrate the aggregates example, including a cross-plugin identity | 5, 6 | example |
| 8 | Migrate the DCB example; document | 7 | example + docs |

**Checkpoint A** is the first release in which the identity semantic exists on the wire; clients
that read semantics can build against it. **Checkpoint B** is the first release in which
editor tooling may *write* a typed id into a DCB slice.

---

## Phase 0: an aggregate read model is not keyed by a foreign id

Analysis F6. Independent of everything else; it can ship first or at any time.

**Done (2026-09-21).** Only `classifyKeyField` / `resolveKeyField` take the kind.
`deriveServerCapability` does not: it always reads the state-field ladder, because its
output must stay byte-identical, and so the local and AWS resolvers are untouched. For a
read model, several foreign `*Id` fields are `NoCandidate` rather than `Ambiguous`, since the
sole rung never gave it a key to lose. Only the aggregates example's `Orders` changed.

**Change.** Pass the component's kind to the key rule so it can tell a read model (row keyed by
the envelope id) from a StateViewSlice (row keyed by a state field). For a read model, the
"sole `*Id`" rung does not name the key.

- [`GraphQL_FragmentGenerator.res`](../../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res):
  `classifyKeyField` / `resolveKeyField` take the kind as a real variant (e.g.
  `RowKeyedByEnvelope | RowKeyedByStateField`), not a boolean, and not a default.
  `deriveServerCapability` takes it too.
- **Keep the filter and order-by the sole field produced.** `deriveServerCapability` still
  pushes the sole field as filterable and sortable for a read model; only the *published key*
  changes. Removing a generated filter is an SDL break. Rewrite the comment in
  `Plugin_Structure` that says the published key and the filter key "cannot disagree" to the
  weaker invariant: the key is always filterable, not every filterable field is the key.
- Call sites to thread the kind through: `Plugin_Structure.res` (read models ~1430, state
  views ~1473, `queryableDefFromSpec` ~991), `GraphQL_FragmentGenerator.res:978`,
  `local/.../QueryDbResolvers_GraphQL.res:577`, `aws/.../QueryDbResolvers_AppSync.res:254`,
  `aws/.../PgQueryResolverEntryPoint_Ops.res:147`.

**Validation.**
- The aggregates example: `Orders` publishes no key field; the `Orders` connection SDL is
  byte-identical to before (the `customerId` filter and order-by remain).
- The DCB and hybrid examples: every StateViewSlice's key is unchanged (`AvailableProducts`
  still resolves `productId` via the sole rung).
- The key-field gap warning for `Orders` changes from none to "no key", which is correct.

---

## Phase 1: spike, and the API decision

The scratch compile in the analysis proved distinct types without sury. Two things are unproven.

1. **Does a consumer record find the identity's schema?** `@schema type state = {orderId: OrderId.t}`
   makes sury-ppx reference `OrderId.schema`. `Make` defines `schema` without the PPX:
   `let schema: S.t<t> = S.string->Semantic.mark(~id=Semantic.Id.identity, ~payload=…)`, which
   typechecks inside the functor because `t = string` there.
2. **Does the reventless-ppx leave a `Make` application alone** in a file under a chapter
   folder, and in a `*-spec` package?

**Do.** Add `Make` and the semantic on a branch; compile one aggregate spec, one read model, one
StateViewSlice and one DCB slice from the aggregates and DCB examples against it; encode and
decode an event; print the derived JSON Schema.

**Decide.** If both hold, the API in the analysis stands. If sury-ppx cannot resolve `M.schema`
for a functor-produced module, fall back to an `include`d module per identity file generated by
a helper (`Id.Make` returns a module with `schema` declared by hand), and record the decision in
the analysis before Phase 2.

**Output:** a short note appended to the analysis, and the branch discarded.

**Done (2026-09-21).** Both hold; the API stands (analysis § Spike result). The spike ran in
the tree rather than on a branch; the example edits were reverted, and `Make` is kept as
Phase 2's.

---

## Phase 2: `Id.Make` and the `identity` semantic → Checkpoint A

Additive. Nothing uses it yet.

- [`Id.res`](../../../reventless/spec/src/types/Id.res): `module type Identity = { include T with
  type input = string; let key: string }` and `module Make`. Correct the `Id.T` doc comment
  (analysis F1).
- [`Semantic.res`](../../../reventless/spec/src/semantic/Semantic.res): add `Id.identity` and
  `IdentityOf({key: string})`; extend `referenceTarget` with `identity: option<string>`.
  `Reference.to_` sets it when wrapping an identity schema (analysis open question 2).
- [`SuryToJsonSchema.withSemantic`](../../../reventless/core/src/components/Api/SuryToJsonSchema.res):
  emit `x-reventless-semantic: "identity"` with `x-reventless-semantic-target: {key}`; add
  `identity` to a reference's target.
- [`SchemaType.shapeOf`](../../../reventless/core/src/components/Api/SchemaType.res): an identity
  is `EntityId`, for scalars and array elements.

**Validation.** Unit tests: two `Make` applications are distinct types (a compile-fail fixture
if the suite has one, otherwise the Phase 1 program as a test); schema round-trip; JSON Schema
carries the semantic and target; SDL renders an identity field named `buyer` as `ID!`. All
examples build unchanged.

**Done (2026-09-21).** Two departures:
- `Reference.to_` does not set the reference's identity. It builds its own `S.string`, so
  there is no identity schema for it to wrap; the type-preserving helpers of Phase 3 are
  where a reference meets one. `referenceTarget.identity` is an optional field, so existing
  constructions are unchanged.
- A reference's target never reaches the JSON Schema: `SchemaType.fromSury` excludes the
  reference semantic from its wrapper, and clients read references from `extractReferences`.
  The identity on a reference is therefore published in Phase 5, not here.

An optional identity stays nullable in the SDL (`previous: ID`). `shapeOf` reads the marker
on the schema itself, not through the optional as tags and references do.

**Release → Checkpoint A.**

---

## Phase 3: the runtime reads identities

Additive for specs without identities.

- [`DcbTag.res`](../../../reventless/spec/src/components/DcbTag.res): type-preserving helpers
  (`S.t<'a> => S.t<'a>`) beside `string` / `stringForKey` / `partition` / `crossPartition`;
  the tag key comes from the identity semantic unless `dcbTagKeyOverrideId` is set (so
  `@dcbTag("k")` wins). `idFieldsOfProperties` (~1085) and `sliceShapeFromSchemas` read the
  identity semantic before names.
- [`DcbScopeInference.res`](../../../reventless/spec/src/components/DcbScopeInference.res): no
  logic change; it receives identity-keyed shapes.
- Read-model key: `Plugin_Structure` passes a read model's `Spec.Id.schema` to the key rule; if
  it carries an identity, that identity is the row key and state fields of other identities are
  never candidates.

**Validation.** `check:dcb-scope` goldens unchanged for every example. New tests: a slice whose
typed field is named `buyer` is tagged `customerId`; `@dcbTag("sellerId")` on a typed field
keeps `sellerId`; a read model with `module Id = OrderId` publishes the identity as its key.

**Done (2026-09-21).** Beyond the plan:
- **`Reference.mark` / `markWithoutDcbTag`**, the type-preserving `@ref` helpers Phase 4 wraps
  with. They carry the field's identity onto `ReferenceTo`, and `Semantic.identityKey` reads
  it from there, so an `@ref` on a typed field keeps both facts.
- **`extractTaggedFields` returns resolved tag keys, not field names.** It names the DynamoDB
  GSIs (`tag_<key>`), so a typed `buyer` would otherwise get an index its tags never land in.
  It changes nothing in the tree: no example has a scalar tag-key override. The partition
  hint is resolved the same way.
- **`DcbScopeInference.idField` gains an optional `key`**, which `tagKeyOf` prefers. That is
  the one logic change there, since a typed field's key is not derivable from its name.

One departure: **the read-model key does not consult `Spec.Id`.** The key has to stay
filterable, and the capability deriver behind the SDL and the local, AWS and Postgres
resolvers sees only the state schema. Threading `Spec.Id` to all of them would add a
registry per path. Instead a key candidate's key is its identity when it is typed, so
`Orders` is keyed by `order: OrderId.t` and never by `orderId: CustomerId.t`. A read model
whose name does not match its identity (`OrderSummaries` over `OrderId`) still needs `@id`,
which Phase 4 makes accept a typed field.

Released together with Phase 4, because nothing can produce a typed field before it.

---

## Phase 4: the PPX accepts identity-typed fields → Checkpoint B

- One recognition helper in [`Util.ml`](../../../packages/reventless-ppx/src/ppx/Util.ml): a type
  constructor whose path ends in `<M>Id.t`, through `option<…>` and `array<…>`.
- Accept it at every string-only site (analysis F4): `DcbTagInference` (auto-tag,
  `@partitionTag`, `@crossPartition`, `@dcbTag`), `ReferenceInference`, `OwnerInference`,
  `StateAnnotations` (`@id` family), `SidecarEmit` (`dcbRole`, kind). Wrap with the Phase 3
  type-preserving helpers.
- `ReventlessPpx.ml` (~796): skip `module Id` injection in a spec-namespace package, as
  authorization and read-consistency injection already do (`is_spec_namespace_pkg`).
- Follow the PPX release procedure: rebuild and copy the binary, wipe every `lib/`, one commit.

**Validation.** PPX tests for each accepted site with a typed field, including `array<ProductId.t>`
and `option<CustomerId.t>`; a `*-spec` package with a `reventless-spec` dependency compiles its
extension-point spec with no injected `module Id`. `check:dcb-scope` goldens unchanged. Every
example builds.

**Done (2026-09-21).** Every accepted site composes onto `M.schema` through the Phase 3
helpers. Beyond the plan:
- **`option<M.t>` is not auto-tagged**, matching `option<string>` today. An optional tag
  would be a new behaviour for both, not part of this change.
- **An identity-typed `@compositePartitionTag` is a compile error.** The member stays
  `string` (open question 1). Left to the string-only pass, it would have dropped out of
  the key silently.
- **The sidecar stays inside its role vocabulary.** The tools repo's `Model.dcbRoleFromJson`
  rejects an unknown role, so a typed id is `customKey` with the key its module name gives
  by convention, and a `@partitionTag` on one adds that key beside `partition`. The field
  kind stays `custom` (`CustomerId.t`), which is accurate.
- **The `module Id` skip reached one package already.** `online-shop-hybrid-catalog-spec`
  depends on `reventless-spec`, and its extension-point contract loses an `Id` export that
  nothing read. Every other compiled file in the tree is byte-identical.

**Release → Checkpoint B.**

---

## Phase 5: derived and checked references, identity checks

- `Plugin_Structure.extractReferences`: for an identity field with no `@ref`, find the views in
  the plugin keyed by that identity (read models through `module Id`, StateViewSlices through
  their key field). Exactly one → emit the reference. Several → no reference, and a report
  asking for `@ref`. None → a report that nothing lists the identity. With `@ref`, check the
  named view is keyed by the field's identity.
- Beside `check:dcb-scope` ([`scripts/check-dcb-scope.mjs`](../../../scripts/check-dcb-scope.mjs)):
  a field named after *another* declared identity's key (`orderId: CustomerId.t`); an untyped
  `*Id: string` whose key has a declared identity in scope (analysis open question 3); a slice
  whose partition identity is declared outside its own chapter.

**Validation.** Tests for each case; the examples report nothing until migrated.

**Done (2026-09-21).**
- A view counts as keyed by an identity through a read model's `Spec.Id`, else its key
  field's type, else its key field's *name*. That lets a typed id derive a reference to a
  view whose key is still an untyped `productId`, so a plugin can migrate its commands
  before its views.
- Derived references and the `@ref` check are warnings at structure assembly (like the
  key-field gap), deduplicated per plugin; the field still decodes.
- The identity checks live in [`IdentityCheck`](../../../reventless/spec/src/components/IdentityCheck.res),
  a pure module `check:dcb-scope` calls, and they fail the check like a `@partitionTag`
  issue. "Declared" means some field in the plugin is typed with the identity, so a plugin
  that types nothing is never reported.
- **The chapter check reads the declaring file from source.** Nothing at runtime knows
  where `Id.Make` was applied, so the script scans `src/<Chapter>/*.res` for
  `Id.Make({let key = …})`, and `IdentityCheck.checkChapters` compares that with each
  slice's inferred partition. An identity from another package (`CatalogSpec.ProductId`)
  has no chapter and is not checked.
- Scope: DCB slices only, since the script reads `dcbSliceSchemas`. An aggregates-only
  plugin gets the derived references but not the name checks.

---

## Phase 6: typed projections and row keys

- [`Projection.res`](../../../reventless/spec/src/types/Projection.res): `action` generic in its key;
  `Mapping.project` takes `event'<SourceId.t, _>` and returns `action<Target.Id.t, _>` for read
  models. [`StateViewSlice.res:117`](../../../reventless/spec/src/components/StateViewSlice.res#L117):
  the key type is the view's declared identity, or `string` for a view that declares none (the
  hard constraint).
- Builders: `ProjectionMapper.res`, `StateViewSlice_Builder.res` convert at the storage edge
  with `toString`, per the F5 rule.
- Remove `module Id` from `StateChangeSlice.Spec` and the PPX's injection for slices.

**Validation.** All examples build unchanged; a projection that keys a read model by the wrong
identity fails to compile (fixture).

**Done (2026-09-21), as a breaking change** (decided against the hard constraint, above):
- **Read models:** `Mapping.project` is `event'<SourceId.t, _> => action<targetId, _>`, and
  `Mapping` carries `targetIdToString` / `targetIdFromString`. `ProjectionMapper` decodes the
  envelope with `SourceId.schema` and converts the action back to string keys with the new
  `Projection.mapActionId`, the F5 storage edge. The tree needed 7 conversions in examples
  (`CategoryActivity` keys rows by two payload ids; hybrid `Customers` by one, and stores its
  envelope id in a `string` field), plus test fixtures, which moved to `Id.StringPure`.
- **StateViewSlices:** the spec gains `module Key: Id.T`, which the PPX defaults to
  `Id.StringPure` in a `StateView/` folder, so a view that declares no identity keeps
  `string` keys and compiles unchanged. `module Key = OrderId` types it. Six hand-written
  inline test specs needed the default by hand.
- **`module Id` is gone from `StateChangeSlice.Spec`, but not from the PPX's injection.**
  A slice that is an extension point's `Delegate` must satisfy the delegate signature,
  which requires `Id` (`UiFragmentRegistry`), so the injected `Id` stays on slice files. It
  is no longer part of the slice contract.
- **Other repos:** `reventless-sovereign` (k8s runtime fixtures, the minimal-k8s example) and
  `reventless-tools` (codegen synthesis, vscode authoring) have read-model mappings that need
  the same conversions when they take this release.

---

## Phase 7: migrate the aggregates example

The safe first adopter: no DCB tags (analysis § Aggregates and read models).

- Declare `OrderId`, `CustomerId`, `CategoryId` in their chapters; `ProductId` in
  `catalog-spec`, which gains a `reventless-spec` dependency (open question 5).
- Aggregates and read models write `module Id = <Identity>`; payload and state fields use the
  identities; `Orders` gets `module Id = OrderId` and its key back from Phase 3.
- Event mappings, side effects and GWT tests adjusted.

**Validation.** GWT suites green; SDL diff shows only intended changes; the local platform runs
the shop; record the churn (files, conversions added) in the analysis before Phase 8.

**Done (2026-09-21).** Churn recorded in the analysis (§ Churn): 8 conversions, all at string-
routed seams. Beyond the plan, `Order.Place` drops its `@ref` for the derived reference.
Orders publishes no key: its state holds no field typed `OrderId` (see the Phase 3 departure),
and that is the shape an aggregate read model has.

---

## Phase 8: migrate the DCB example; document

- The DCB online shop, including `CatalogSpec.ProductId` across the extension point.
  `check:dcb-scope` goldens unchanged.
- `packages/doc/docs-app`: an identities section in `dcb-usage.md` and
  `aggregate-vs-dcb-decision-guide.md`; the F5 conversion rule (schema inside JSON documents,
  `toString` for infrastructure keys) where ids are documented.

**Done (2026-09-21).** Both DCB plugins are typed throughout; the catalog keeps `orderId` a
string, since it cannot see ordering's identity, and the identity check asks only for keys a
plugin declares. `check:dcb-scope` reports nothing and its golden did not move. Conversions
landed at the same kinds of seam as in the aggregates example, plus the automation and outbound
to-do keys, the extension routing ids and the imported SKU. `PlaceOrder`'s
`ProductsNotAvailable.missing` is typed rather than converted.

One framework fix it needed: **the GWT sidecar read a typed id as no value at all.**
`oid("o1")` is a call, not a literal, so the lifecycle harvest could no longer relate a
scenario's given events to its command, and `PlaceOrder` flipped from creating an order to
acting on a placed one. `SidecarEmit.example_of_expr` now reads a single-literal call as that
string, recording the function as `constructor` so a writer can reproduce it.
`common-modules/Id.md` was rewritten too: it recommended `Id.String` for keeping ids apart,
which F1 disproved.

## Out of scope

Composite partitions as identities (open question 1); per-identity validation (open
question 2); making untyped ids an error.

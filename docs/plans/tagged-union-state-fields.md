# Plan: tagged-union fields in queryable state

**Date:** 2026-08-20
**Status:** Implemented (steps 1–6), 2026-08-20. Unreleased; no view declares a union yet, so every
SDL golden and every stored row is byte-identical to before. Step 7 (the reader half) is
`reventless-ui`'s to plan. What is **not** proved here is a deployed read — see *Verification*.
**Scope:** the **mechanism** only — the framework learning to express, emit and store a
tagged-union field. No view adopts one here. The first adopter, and the semantic type it adopts, are
[semantic-geolocation.md](./semantic-geolocation.md), which is where the deployment proof lives.
**Repos:** `reventless-core`, with a reader half in `reventless-ui` planned there. Unlike `Money` and
`DateRange`, this one changes the *SDL shape* a consumer selects against, so the two halves carry a
hard sequencing constraint (below).
**Builds on:** [done/semantic-money-and-currency.md](./done/semantic-money-and-currency.md) and
[semantic-geo-point.md](./semantic-geo-point.md) — the composite template, and the read model whose
shape motivates this.

## What this replaces: one fact spread across three fields

`Customers` spends three fields on one three-state fact
([Customers.res:57-75](../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers.res#L57-L75)):

```rescript
location: option<Reventless.GeoPoint.t>,
locationStatus: locationStatus,       // Pending | Located | Unresolvable
@hidden locationNote: option<string>,
```

Twelve representable combinations for three legal ones. `Located` with `location: None` compiles.
`Unresolvable` with a stale point still on the row compiles. `Pending` carrying a note compiles. What
keeps the twelve down to three is the five-arm switch in
[Customers_Projections.res:42-99](../../examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/Customers_Projections.res#L42-L99)
remembering to write all three fields on every arm — and it does, today, in both the aggregate mapping
and the DCB one, and in both `UpdateWithDefault` defaults. Six places that have to agree.

The file already makes this argument against itself. Twenty lines up, `accountStatus` is a variant
rather than an enum-beside-a-flag, and the comment says why: "The alternative — an `accountStatus`
enum AND a `deactivated: bool` — is the same fact twice, with nothing keeping the two in step." The
same sentence applies verbatim to the three fields below it. The reason it was not applied is not a
design decision; it is that **the framework cannot express the type**.

That is the gap this plan closes. The honest type is:

```rescript
@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({point: Reventless.GeoPoint.t})
  | Unresolvable({reason: string})
```

(`Pending` carries the address the geocoder was asked about rather than nothing — D2 explains why
every arm has to carry *something*, and it is a GraphQL rule rather than a ReScript one.)

`Customers` is the motivating case, not this plan's work: collapsing it belongs to
[semantic-geolocation.md](./semantic-geolocation.md), because the type it should collapse *into* is
framework vocabulary rather than an example's local variant, and deciding that alongside the
mechanism would let two unrelated arguments lean on each other. What matters here is only that the
type above cannot be written today.

Writing it compiles, deploys, and silently degrades the field to `String!` in the API —
`SchemaType.shapeOf` sends a mixed `AnyOf` to `Unknown`
([SchemaType.res:150-166](../../reventless/core/src/components/Api/SchemaType.res#L150-L166)) and
`Unknown` is emitted as `String${bang}`
([GraphQL_FragmentGenerator.res:88](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L88)).
No error anywhere. **Silent degradation is the current behaviour, which makes this a correctness fix
as much as a feature** — even if nothing else here is built, the fallthrough deserves to become a
compile error.

## What already works, verified rather than assumed

The layers that usually make a change like this expensive are all already correct. Each was checked
against the installed toolchain, not reasoned about:

| Layer | State | Evidence |
|---|---|---|
| sury-ppx compilation | ✅ | a payload variant compiles to `S.union` of **declared** arms — `S.$schema(s => ({TAG: "Located", point: s.m(…)}))` — which is the form [Offload.res:78-90](../../reventless/spec/src/semantic/Offload.res#L78-L90) requires and a transform arm is not |
| encode / decode / round-trip | ✅ | probed on sury 11.0.0-rc.1: a nested union field encodes to `{"TAG":"Located","point":{…}}`, parses back identically, and a payload-less arm encodes to the bare string `"Pending"` |
| `toJSONSchema` | ✅ | emits `anyOf` with `const` discriminators on `TAG`, per arm |
| storage, all four backends | ✅ | [QueryDb_Operations.res:71,85](../../reventless/core/src/components/QueryDb/QueryDb_Operations.res#L71) encodes state through `Message.encode(stateSchema)` and decodes through `Message.decode` — not a raw marshal — so DynamoDB, Postgres, SQLite and in-memory carry a nested union with no backend change |
| replay healing | ✅ | [Message.res:240-243](../../reventless/spec/src/types/Message.res#L240-L243) already resolves an `anyOf` member by matching `properties.TAG.const` against the value's `TAG`, with a shape-scored fallback |
| a union in the SDL | ✅ | `CommandResult` is one, on AppSync and on the local yoga server, resolved by an explicitly written `__typename` ([CommandTopic_Helpers.res:131-158](../../reventless/core/src/components/CommandTopic/CommandTopic_Helpers.res#L131-L158)) |
| an empty inline-record arm | ✅ ReScript, ❌ SDL | `\| Pending({})` compiles, sury-ppx emits a declared object arm, and the runtime and wire form is `{"TAG":"Pending"}` — but the member type it implies has zero fields, which is invalid GraphQL |
| a positional-payload arm | ✅ everywhere, ❌ as a contract | `\| Located(GeoPoint.t)` compiles and encodes to `{"TAG":"Located","_0":{…}}` — correct, and it publishes the compiler's `_0` as an SDL field name. Both rows are what D2 turns on |

So the question is not whether sury can express it. It is what the four Reventless layers above sury
have to learn.

## The two decisions this plan turns on

Everything else is mechanical. These two decide whether the change is contained or sprawling.

### D1. `__typename` is stamped at **write** time, once, not at read time on every door

Both AppSync and graphql-js resolve a union member from `__typename` on the returned value. The
AppSync JS resolvers hand back the DynamoDB item as it was stored, and
[PgQueryResolver_Lambda.res:509](../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res#L509)
stamps only the *top-level* one. So a read-time stamp has to reach a nested field on **fourteen
doors**:

| Backend | Doors |
|---|---|
| AppSync ([QueryDbResolvers_AppSync.res](../../reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)) | single, single`Items` (composite sort key), list/connection, by-index, by-ids, refs, `@resolves`, `@resolvesMany` |
| Postgres ([PgQueryResolver_Lambda.res](../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res)) | its own resolver |
| Local ([QueryDbResolvers_GraphQL.res](../../reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res)) | single, single`Items`, list, by-ids, refs, by-index |

Fourteen chances to miss one, and missing one is not a visible bug: a union field with no
`__typename` resolves to null, and **a null in a non-nullable field nulls its parent** — inside a list
that is every row vanishing — precisely the failure this read model already produced once, when a
newly non-nullable `locationStatus` made all eight seeded customers disappear from the list
([customer-address-backend-geocoding.md](./customer-address-backend-geocoding.md), "A note this plan
owes step 6"). It reads as data loss rather than as a schema mistake.

Stamping at write time — in `QueryDb_Operations`, beside the existing `Message.encode` — is one place
instead of fourteen. It costs a `__typename` key inside every stored union value and a backfill for
rows written before it.

It also buys something the read-time stamp cannot. The live change descriptor carries the row as
**raw JSON**, not through a typed GraphQL field
([LocalStateChangeDescriptor.res:119-130](../../reventless/local/src/adapter/LocalStateChangeDescriptor.res#L119-L130);
the AWS relay carries no payload at all, only `changeKind`/`id`/`sortKeyValue`, per
[StateTopic_AppSync.res:121-124](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L121-L124)).
So under read-time stamping a subscriber sees `{TAG: "Located"}` from the live channel and
`{__typename: "GeolocationLocated"}` from the query — two shapes for one value, decided by which
channel delivered it, with the client owning the reconciliation. Under D1 the stored row carries both
keys and both channels agree.

**The counter-argument, stated fairly:** `__typename` is a GraphQL transport concern and D1 puts it in
the storage layer, which is a leak. The answer is that it is the *narrower* leak — the alternative
puts the same concern in fourteen resolvers across three backends and still leaves the live channel
disagreeing with all of them.

### D2. Every arm declares at least one **named** field

Three arm shapes are refused, for three different reasons that are all the SDL's rather than
ReScript's or sury's — every one checked against the compiler rather than assumed.

**A bare arm is a scalar on the wire.** `| Pending` compiles to `S.literal("Pending")` and encodes to
the JSON string `"Pending"` — verified. **GraphQL unions admit only object types**, so a string arm has
no member type it could be.

The obvious fix is an empty inline record, and it gets further than expected: `| Pending({})` is legal
ReScript, sury-ppx compiles it to a declared object arm (`S.schema(s => Pending({}))`), and its
runtime and wire form is `{"TAG": "Pending"}` — an object, exactly what the union needs. All three
verified.

**But the member type would then have no fields.** `TAG` is filtered out of the emitted fields
([SchemaType.res:125](../../reventless/core/src/components/Api/SchemaType.res#L125)), leaving
`type GeolocationPending { }` — and a GraphQL object type with zero fields is invalid. So the empty
arm gets exactly as far as the SDL and stops.

Two ways out:

- **Emit the discriminator as a declared field** — `kind: String!` on every member type — so an empty
  arm has something to declare. Cheap, and wrong for the reason every plan in this directory keeps
  giving: it puts a second discriminator beside `__typename` in the published contract, and two ways to
  reach one fact is what these types exist to remove. It also leaks `TAG`, a ReScript runtime detail,
  into the SDL.
- **Require every arm to declare at least one field of its own.** No synthetic field anywhere, one
  discriminator, and every member type valid by construction.

Take the second. The pressure it creates is usually productive: an arm that seems to carry nothing
normally carries *when* or *what it was trying* — a `Pending` state that names the input it is pending
on is more useful than one that does not — and the declaration is the right place to be asked.

**And the field must be named, which rules out a positional payload.** `| Located(GeoPoint.t)` is the
form that reads most naturally in ReScript and it is the third refusal. It compiles, sury-ppx accepts
it (`S.schema(s => Located(s.matches(pointSchema)))`), and it encodes to
`{"TAG":"Located","_0":{"lat":1,"lng":2}}` — all verified. The payload's key is `_0`, a name the
ReScript compiler generated, and that name is not an internal: it is in the stored JSON, in the JSON
Schema's arm properties, in the emitted `type GeolocationLocated { _0: GeoPoint! }`, and in every
consumer's `... on GeolocationLocated { _0 { lat lng } }`.

`| Located({point: GeoPoint.t})` is the same wire shape with an honest key, and it costs one pair of
braces. It also keeps the *next* field additive: going from `Located(GeoPoint.t)` to a two-value arm
renames `_0` to `point` and breaks the stored shape and the SDL together, where going from
`Located({point})` to `Located({point, resolvedFrom})` breaks neither — and `resolvedFrom` is a
plausible next field, since the aggregate already carries that staleness token on `SetLocation`.
The general reason underneath both: `@s.matches`, the DCB tag markers, `@owner` and `@offload` all
attach to a *named* record field, and a positional payload gives them nothing to attach to.

The ppx refuses all three shapes with one error naming the field and the arm: a bare arm, an empty
inline record, and a positional payload.

Note D2 applies **only to a union used as a state field**. Command and event variants are unaffected:
they are decomposed into one mutation per constructor, and a payload-less command like `Deactivate`
stays exactly as it is.

### D3. The union's name is carried on the **schema**, not composed from the field path

Found while implementing D1, and it is what makes D1 possible at all. The plan above assumed the
member name could be composed the way an enum's is — `<parentType><Field>`, so
`Ordering_CustomerLocationStatus`. The write-time stamp cannot do that: `QueryDb_Operations` holds a
`ReadModel.Spec` and a sury schema, and the GraphQL return type name (`<Plugin>_<singularised
Spec.name>`) is composed three levels up, differently per component kind. A stamp that guessed it
would write a `__typename` naming no member — which resolves to null, which nulls the parent row.
Threading the type name down through six builders was the alternative.

So the name lives where both halves can read it: `Reventless.TaggedUnion.named(~name=…, schema)`, one
metadata marker, set once at the declaration. The SDL emitter reads it, the stamp reads it, and they
cannot disagree because there is nothing to derive twice. Two consequences worth stating:

- **The ppx writes it**, for a union a queryable's state holds — `<Plugin>_<Spec><Type>`, which is
  the shape the enum beside it already has. A hand-written schema (a framework semantic type) writes
  the same line itself. There is no annotation to learn.
- **A union with no name is not emitted as one.** It stays the `String` it is today, and step 1's
  report names it. That is stricter than "compose something" and it is the safe direction: every
  union in the SDL is one the stamp can write a `__typename` for.

This also makes the member names path-*independent*, which is what step 2 wanted for merged-API
composition, and which a field-path name would have quietly failed at — the same union on two views
would have been two GraphQL types.

The cost is a collision surface: two queryables in different plugins whose spec names and union type
names both match, with different arms, would emit one name for two types, and the stitcher resolves
that the way it already resolves a duplicated `Money` — first wins, with a warning. Including the
spec name (rather than only the plugin's) is what keeps that to a case somebody had to construct.

## What it costs a deployment

**On its own, nothing.** No view declares a union field when this lands, so every SDL, every stored
row and every query document is byte-identical before and after. That is the point of cutting the work
here: the mechanism can land, be released and sit unused while the adopting plan is still being
argued about.

The costs arrive with the first adopter, and belong to its plan: adopting a union *field* is a
**breaking retype** in the `DateRange` plan's vocabulary — the wire shape changes, so the view is
rebuilt. A read model is derived state and replay is what it is for, so that is a projection rebuild,
not an upcaster.

**One constraint does bind here, and it binds the release.** A union field cannot be selected bare —
every consumer must emit `... on Member { … }`. The moment a view declares one, a client that has not
learned inline fragments produces an *invalid query*, not a degraded render. So the UI's generic
union support must ship **before or with** the first adopter, never after. This is the same
lockstep `GeoPoint` needed, one notch harder: there the UI degraded to no map, here the query fails
outright. The mechanism itself is safe to release ahead of both.

## Steps

**1 — the IR grows a case, and the fallthrough stops being silent.** `TaggedUnion(string, array<(string, schemaType)>)`
in [SchemaType.res](../../reventless/core/src/components/Api/SchemaType.res) — the union's name, and
its arms by TAG const. `shapeOf`'s `AnyOf` branch classifies a multi-arm union whose members are all
TAG-discriminated objects; anything else still falls to `Unknown`, but `Unknown` reaching the SDL
emitter now warns at deploy time rather than emitting `String!` in silence.

Four consumers, all in core: [GraphQL_FragmentGenerator](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res),
[SuryToJsonSchema](../../reventless/core/src/components/Api/SuryToJsonSchema.res),
[Plugin_Structure](../../reventless/core/src/plugin/component/Plugin_Structure.res),
[SchemaWalker](../../reventless/core/src/plugin/component/SchemaWalker.res). **Read each by hand rather
than trusting the compiler** — `isLabelShape` and `isLifecycleShape` both end `| _ => false`, so a new
case slips past them without a warning. Neither should accept a union (a union is not a name and not a
lifecycle), so `false` is the right answer in both — but it should be the *chosen* answer.

*Done.* The arms are carried as the `ObjectRef` each member type is emitted from, so every consumer
that renders an object renders an arm. The report is narrower than "warn on `Unknown`":
`SchemaType.unclassifiedUnions` names only a field whose schema is a union of two or more real
members that could not be classified, and `deriveObjectTypeWithNested` logs it with the view and the
field. `Unknown` from an opaque `JSON.t` field is left alone — the `Plugins` view has two, and a
warning fired on every deploy for a field that never had a better answer is a warning nobody reads.
`isLabelShape` / `isLifecycleShape` got the explicit `false`; `SchemaWalker.describeSchema` did not
have a chosen answer either — it described a union field as an `option` of its *first* arm, so the
structural hash was blind to every other one. It now describes all of them.

**2 — union SDL.** `union Geolocation = GeolocationLocated | GeolocationUnresolvable | GeolocationPending`
plus a member object type per arm, out of `GraphQL_FragmentGenerator`. The naming input already
exists: `SchemaWalker.tagConstOf` reads the TAG const, and the generator uses it today to pair mutation
field names with command variants
([GraphQL_FragmentGenerator.res:665-671](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L665-L671)).
Member names are `<UnionName><Arm>` so that a plugin's copy of the union is byte-identical to every
other plugin's — the property merged-API composition needs, and the reason `semanticCompositeNames`
exists ([SchemaType.res:51-55](../../reventless/core/src/components/Api/SchemaType.res#L51-L55)).

*Done*, with the name coming from D3's marker rather than from the field path — which is what
actually delivers the byte-identity this step asked for. In an input position the union is *not*
emitted: GraphQL has no input unions, so the field keeps the `String` it renders as today and the
generator says so rather than producing an SDL AppSync would reject.

**3 — JSON Schema.** `oneOf` with the arm objects, in `SuryToJsonSchema.fromSchemaType`. sury's own
`toJSONSchema` already produces the right shape for a bare union; what this walk adds is the annotation
merge and the `x-reventless-*` keys, which is why it cannot just delegate.

*Done.* Each arm declares its `TAG` const — the raw payload carries it, and it is what tells a union
from a nullable object — plus `x-reventless-union-member`, the GraphQL type that arm is emitted as,
so a reader mapping a live-channel payload onto a selection does not re-derive the naming rule in a
second repo. The field itself carries `x-reventless-union: "<Name>"`.

**4 — the write-time stamp (D1).** In `QueryDb_Operations`, after `Message.encode(stateSchema)`, walk
the encoded JSON against the state schema's union fields and set `__typename` beside `TAG` on each.
One traversal, driven by the schema, so it costs nothing on a view with no union field.

*Done*, on both `save` and `saveBatch`. The walk lives in `Reventless.TaggedUnion.stampInto`
(reventless-spec, so nothing in the storage path reaches for the Api layer) and follows records,
arrays, optionals and unions nested inside an arm.

**5 — the guards.** Three compile errors, in the ppx:
  - an arm of a state-field union without a named field — bare (`| Pending`), empty
    (`| Pending({})`) or positional (`| Located(GeoPoint.t)`), one error for all three (D2);
  - `@index` / `@scan` / `@scanSort` / `@groupBy` / `@lifecycle` / `@retired` on a union field —
    `deriveServerCapability` is annotation-driven
    ([GraphQL_FragmentGenerator.res:286-331](../../reventless/core/src/components/Api/GraphQL_FragmentGenerator.res#L286-L331))
    and would otherwise emit a filter input whose `gqlType` falls back to `String` against a value
    that is an object;
  - `@id` / `@subId` on a union field, for the same reason one notch harder — a key must be a scalar.

*Done*, in `TaggedUnionInference.ml`, which also writes D3's name. Two additions the plan did not
list, both the same argument in a different spelling: the composite key forms (`@compositeId`,
`@compositeSubId`, `@indexSubId`) join the refused set, and so does `@retired` on an *arm* — the
constructor form is read by comparing the stored field to a state name, and a union field stores a
record, so the predicate would never fire and every row would stay visible. A retirement that
silently retires nothing is the failure mode this whole plan is about.

**6 — a union fixture in the core tests, since no view has one.** A three-arm view spec in
`reventless/core/tests`, carried through the SDL emitter, the JSON-Schema walk, the write-time stamp
and all four storage backends. It exists because steps 1–5 are otherwise unprovable: every assertion
below runs against it.

Deliberately a *fixture* and not the example. Pointing step 1 at a real view would make the mechanism
plan own a breaking retype, a golden refresh and a UI pin — which is exactly the coupling this cut
exists to avoid, and it would put the plan's release behind the adopting plan's argument.

*Done*: [TaggedUnionFixtures.res](../../reventless/core/tests/fixtures/TaggedUnionFixtures.res) — a
required union, an optional one, an array of them, and an unnamed one for the case the emitter must
decline. The storage arms could not all live beside it: a package's `type: dev` sources are invisible
to another package, so the local and AWS round trips redeclare the four-line union.

**7 — the reader half, planned in `reventless-ui`.** What this plan owes it is a contract, not a
design:

| What the UI reads | Fixed by |
|---|---|
| a union field is selected with `... on Member { … }`, never bare | step 2's SDL |
| the member type name is `<UnionName><Arm>`, stable across plugins and across the views that use it | D3's schema-carried name, read by step 2 |
| the union's own name is published as `x-reventless-union`, and each arm's member type as `x-reventless-union-member` — neither is re-derived client-side | step 3 |
| an arm is discriminated by `__typename`, and the live channel's raw payload carries the same one the query does | D1 |
| a union field is never a filter, sort, group or lifecycle field | step 5's guards |
| a union field is distinguishable from a nullable object, both of which are `oneOf` of objects | step 3's arm `const`s — the discriminator is what tells them apart |

The last row is the one to state loudest, because a reader that gets it wrong does not fail: it
selects one arm's fields as though they were the field's own, and produces a query that looks
plausible and is invalid.

## Verification

**What ran, 2026-08-20.** `pnpm test` — 352 suites, 3533 tests, green; `pnpm run check:graphql` — both
goldens byte-identical, which is the claim that this lands invisibly; `pnpm run check:unions` — the
sury constructor-reachability sweep still clean over 110 unions; `packages/reventless-ppx/test/run.sh`
— 324 checks, green, including the seven new refusals and the naming assertions. Every bullet below is
one of those, except the two marked otherwise.

- **The silent degradation is gone.** A mixed `AnyOf` that step 1 cannot classify produces a deploy-time
  warning naming the view and the field. Asserted as a test on the emitter, because the current
  behaviour is that nothing is emitted at all.
- **The SDL is what the arms say.** `GraphQL_FragmentGeneratorTest` over a three-arm union: the union
  declaration, three member types, and the field typed as the union — and, separately, that two plugins
  declaring the same union emit byte-identical text. The second assertion is the merged-API property,
  and it is the one that fails quietly.
- **The stamp lands on every arm, and only on union values.** The step 6 fixture encoded and inspected:
  `__typename` beside `TAG` on the union field, and a view with no union field byte-identical to what
  it encodes today. The second half is what keeps this releasable ahead of any adopter.
- **Round-trip through storage, all four backends.** In-memory and SQLite in the local suite, DynamoDB
  and Postgres in the AWS suite: save a `Located`, read it back, get a `Located` with its point intact.

  **In-memory and SQLite ran and pass**
  ([QueryDbUnionRoundTripTest.res](../../reventless/local/tests/adapter/QueryDbUnionRoundTripTest.res)).
  **DynamoDB and Postgres are written and were not run here** — both need a Docker sidecar
  (`pnpm run test:integration` / `test:integration:pg`), and Docker was not available on the machine
  this landed from. They compile, they are in the suites CI runs, and they assert the same two things
  the local pair does: `__typename` survives the store as a nested key, and the row decodes back to
  the arm it was saved as. Until CI has run them, that is a written test, not evidence.
- **Replay heals an older row.** A row stored before the union field existed, parsed against the new
  schema, arrives as the first arm rather than throwing — the `fillMissingDefaults` path, asserted
  directly rather than assumed from the code reading above.
- **The guards refuse.** Each of step 5's three errors, as a ppx test, checked for naming the field —
  a guard that fires with an unhelpful message is a guard people work around. Seven cases in the end:
  the three arm shapes, four of the refused annotations, and `@retired` on an arm.
- **The marker survives the wrapper sury does not keep.** `option<union>` flattens the arms and the
  `undefined` into one `anyOf`, so there is nothing nested left to read a name from — what makes an
  optional union field work is that the metadata survives onto the wrapper.
  [TaggedUnionTest.res](../../reventless/spec/tests/TaggedUnionTest.res) pins it, because a sury
  release that stopped preserving it would turn every optional union field into a `String` with no
  compile error anywhere.

**What this plan deliberately cannot verify.** Nothing here proves a union field survives a *deployed*
read. The fourteen doors in D1's table need a real view declaring a real union, which arrives with the
first adopter — so that sweep, the live local round trip and the browser check are
[semantic-geolocation.md](./semantic-geolocation.md)'s verification, not this one's. Saying so is the
point: a mechanism plan that claims deployment evidence it has not gathered is how a door gets
declared covered without ever being called.

## Out of scope

- **Union fields in command input.** GraphQL has no input unions. A command that needs one takes the
  arms as separate mutations, which is what the command decomposition already does — and is why D2's
  restriction touches only state.
- **Interfaces.** A union says "one of these"; an interface says "these share fields". Nothing here
  needs the second, and adding both at once would make the IR case answer two questions.
- **Filtering, sorting or grouping by arm.** Step 5 refuses them rather than defining them. "List the
  customers whose geolocation is `Unresolvable`" is a real query and it wants a *derived* scalar field
  beside the union, not a filter over the union — see follow-ups.
- **Recursive unions.** An arm carrying the union again. Nothing needs it, the SDL emitter would need
  cycle detection, and `fillMissingDefaults` walks eagerly.
- **Any view adopting a union**, `Customers` included — [semantic-geolocation.md](./semantic-geolocation.md)
  owns the first one, and every other view keeps its shape until something asks.
- **The semantic vocabulary.** Whether a given union is framework vocabulary or an application's own
  local type is a question about that union, not about the mechanism. Every union emitted here is a
  plain one; a semantic marker on top is additive and is the sibling plan's first decision.

## Follow-ups

- **A derived arm-name field**, the first time a view wants to filter or group by which arm a row is
  in. A `@scan`-able string beside the union, written by the same walk that stamps `__typename`, would
  make the query work without making the union itself indexable. Worth doing when asked for, not
  before — it is a second statement of the same fact, and the only thing that justifies one is that
  DynamoDB cannot key on the first.
- **A second union semantic.** [semantic-geolocation.md](./semantic-geolocation.md) is the first, and
  one entry does not make a vocabulary. The shape of the *next* one — an outcome, an approval, a
  settlement state — is what will show whether `<UnionName><Arm>` member naming and the
  every-arm-carries-a-payload rule generalise or were fitted to one case.
- **The `Unknown` fallthrough's other callers.** Step 1 makes it warn for state fields. Command and
  event schemas reach the same emitter and can also produce an unclassifiable shape; that path is
  untouched here and deserves the same treatment.

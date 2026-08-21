# `@resolves` / `@resolvesMany` — cross-table fields, end to end

## Context

The two annotations were inert. The PPX wrote `config.idResolvers` /
`config.idsResolvers` from them and every layer downstream either ignored the
configs or acted on them in a way that could not work:

1. **No SDL field.** `GraphQL_FragmentGenerator` built a queryable's object type
   from its sury state schema alone, and `querySchemaEntry` had no channel for
   resolver configs — so the virtual field (`products: [Catalog_Product!]`) was
   never declared, on any backend.
2. **Wrong GraphQL type.** Both AWS adapters attached the field resolver to
   `~type_=name` — the capitalised spec name (`Products`), not the SDL's
   plugin-prefixed `returnTypeName` (`Catalog_Product`). AppSync refuses that at
   deploy: *No field named X found on type Y*.
3. **`resolveIds` answered the wrong shape.** BatchGetItem returns
   `{data: {<table>: [...]}}`; the template returned `ctx.result` — the whole
   envelope — into a field typed as a list. Its empty-list branch fell through to
   a `GetItem` on the *parent's* id against the *target's* table.
4. **A `Multi` single-resolver returned one row.** All six `resolveId*` templates
   ended in `firstResultResponseCode` whatever `resolvedField` said.
5. **The local platform dropped both configs** (`~idResolverConfigs as _`), so
   in-memory had no cross-table read at all.
6. **No narrowing.** The rows come out of the *target's* table, so the target's
   `@owner` / `@retired` rules decide who may see them — and nothing asked.

The `reventless-gwt` `MakeResolver` DSL simulates the join in-memory against
`config`, so GWT tests passed green over the whole gap.

## What landed

**Schema (core).** `Api.querySchemaEntry` gains `resolvedFields?:
array<resolvedFieldEntry>` — `{fieldName, typeName, multi}`, named where the
entry is built because that is the only place the owning plugin's name is known.
`Api_Naming.resolvedFieldsOfConfig` derives them from a view's config;
`Plugin_Builder` (ReadModels) and `Dcb_Builder` (StateViewSlices) populate them,
mirroring how `indexQueries` was threaded. `deriveObjectTypeWithNested` appends
the field lines to the object type; `generate` refuses, before emitting anything,
a target type this plugin does not declare and a field name the state record
already uses.

**Guarded like its parent.** A nested field is read through its parent and answers
under the parent's authorization, so a target declaring a different rule is
refused at build time — the wider door would otherwise hand over rows the
target's own door withholds. A target open to everyone passes, since it can only
narrow.

**Same plugin only.** A `plugin:` key naming another plugin is refused with the
reason: each plugin's document is validated standalone before the merge, and on
AWS the target table's `dynamodb:*` grant is attached to the *declaring* plugin's
API role — so a field returning another plugin's type could neither merge nor
read.

**AWS.** Both adapters now name the parent type from the registry's
`returnTypeName`. `resolveIds` returns `ctx.result.data['<table>']`, short-circuits
an empty id array with `runtime.earlyReturn([])`, and carries the target's owner /
retirement guards — the same `_owns` / `_live` preambles `batchGetItemsByIds`
uses. `resolvedFieldResponse` gives the six single-read templates the same guards
and, for `Multi`, the list rather than its first row. On the Postgres path
`dispatch` applies `ownerAllows` / `retiredAllows` to `resolveOne` / `resolveMany`,
which it was not doing.

**Local.** `GraphQL_ServerInstance.t` gains `registerFieldResolvers(~typeName,
~resolvers)`; the Domain server keeps them per scope bucket so a plugin's
subgraph stays standalone, and merges them into the composed resolver map.
`QueryDbResolvers_GraphQL` builds the field resolvers from the two configs —
primary key, `via` index, and target sub-id (from a parent field or a field
argument) — narrowed by the same target rules.

A nested field carries no `includeRetired` argument, so a retired row never
travels through one on any backend. `{list}Refs` with `@namedWhenRetired` remains
the door that names a row the archive took.

## Tests

- `GraphQL_FragmentGeneratorTest` — both forms reach the SDL with the target's
  type, the state's own fields are untouched, a view declaring none is unchanged,
  and an unexposed target, a differently-guarded target, or a colliding field name
  is refused.
- `AppSync_RetirementNarrowingTest` — the batch door returns the rows out of the
  envelope, short-circuits empty, and drops retired ones; the single door narrows
  the row it hands back and the list form returns the list.
- `QueryDbResolvedFieldsTest` (local) — both forms resolve against a second
  QueryDb, a key naming no row resolves to nothing, missing ids drop out of the
  batch, and a retired target row is withheld from both forms.

No example plugin adopts the annotations, so the GraphQL contract goldens are
unchanged.

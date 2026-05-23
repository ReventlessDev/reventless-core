# Mixed-source ReadModels — projecting Aggregate + DCB events together

A ReadModel can subscribe to events from any combination of Aggregate `EventTopic`s
and a plugin's DCB `EventLog`. The runtime registers all of them in the same
`allEventTopics` dict; `Mapping.Make` picks sources by **name**.

This guide is the application-developer reference for that pattern.

## When to use it

- A read model needs *both* an Aggregate's lifecycle (e.g. `Category`) and DCB
  slice events (e.g. `ProductAdded`) in the same projected state.
- A read model needs to denormalise a few DCB-slice variants into a query table
  so an API can fetch them without re-deriving from raw events.

If your ReadModel only reads DCB events for a single decision-model query,
prefer `StateViewSlice` — it's purpose-built for that and skips the
`Mapping.sourceName` routing altogether.

## The `name` convention

A `Mapping`'s source is matched against the topic dict by **string equality** of
the source's `name` field. The runtime uses these dict keys:

| Source type | Dict key |
|-------------|----------|
| Aggregate | `<AggregateSpec.name>` (e.g. `"Category"`) |
| DCB EventLog | `<pluginName> ++ "DcbEventLog"` (e.g. `"CatalogDcbEventLog"`) |

For DCB sources the **plugin name** is the `~name` argument the plugin's
generated `make` function passes to the framework — i.e. the same string you
read in the `Catalog/src/plugin.json` (or that defaults to your folder name).

> **Pro tip — fail-fast.** If a `Mapping.sourceName` doesn't match any key in
> `allEventTopics`, ReadModel construction throws with a clear error pointing to
> the typo. Without this check, the projection would silently
> see zero events.

## Authoring a mixed-source ReadModel

### 1. The ReadModel spec

The spec file lives in a `ReadModel/` folder, so its filename carries no kind
suffix — the folder supplies the kind:

```rescript
// catalog/src/CatalogActivity/ReadModel/CatalogActivity.res
@@reventless.spec

@schema
type state = {kind: string, lastChange: string}
```

### 2. The Projections file — define each `Mapping`

The sibling body file is `CatalogActivity_Projections.res` (underscore + plural
`_Projections`). Its `@@reventless.mappings` annotation auto-injects the domain
opens, `module Target` / `module M` / `module type Mapping`, `let moduleUrl`, and
— for any inline DCB `Source` module — `module Id` + dcbTags on `*Id` fields.

The Aggregate-source mapping passes the aggregate spec module as the first
argument:

```rescript
// CatalogActivity_Projections.res
@@reventless.mappings

module CategoryActivityMapping = Mapping.Make(
  Category,                             // Aggregate spec module — name = "Category"
  CatalogActivity,
  {
    open Category
    let project = ({event, id, _}) =>
      switch event {
      | Added(_) => Set(id, {CatalogActivity.kind: "category", lastChange: "Added"})
      | Renamed(_) => Update(id, s => {...s, lastChange: "Renamed"})
      | Archived => Update(id, s => {...s, lastChange: "Archived"})
      }
  },
)
```

For the DCB-source mapping, declare a small `Source`-shaped module **inline**.
The `name` MUST match the dict key (`module Id` is auto-injected by
`@@reventless.mappings`):

```rescript
// Same file, just above the DCB mapping.
module CatalogDcbSource = {
  let name = "CatalogDcbEventLog"        // <pluginName>DcbEventLog

  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductRenamed({productId: string, name: string})
}

module ProductActivityMapping = Mapping.Make(
  CatalogDcbSource,
  CatalogActivity,
  {
    open CatalogDcbSource
    let project = ({event, _}) =>
      switch event {
      | ProductAdded({productId}) =>
        Set(productId, {CatalogActivity.kind: "product", lastChange: "Added"})
      | ProductRenamed({productId}) => Update(productId, s => {...s, lastChange: "Renamed"})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CategoryActivityMapping), module(ProductActivityMapping)]
```

Both mappings target `CatalogActivity`. The auto-generated `Plugin.res` wires the
pair as `Platform.ReadModel.Make(CatalogActivity, CatalogActivity_Projections)` —
no manual wiring is needed.

### 3. Typed event subsetting

The DCB log carries the union of every event variant produced by every
StateChangeSlice in the plugin (`ProductAdded`, `ProductRenamed`, `RecordProductDemand`, …).
Your `CatalogDcbSource.event` type only needs to enumerate the variants this
projection cares about. Other variants decode as parse errors and the runtime
treats them as `Ignore` — same behaviour as Aggregate ReadModels seeing event
variants they don't enumerate.

This means:
- Adding a new `event` variant to a sibling DCB slice **does not** force
  consumers to recompile or update their projections.
- Awareness of a new variant is a deliberate developer action: extend
  `CatalogDcbSource.event` and add a `switch` arm.

### 4. Optional helper: `Reventless.Projection.DcbSource.Make`

There's a thin functor for declaring DCB sources:

```rescript
module CatalogDcbSourceDef = {
  let name = "CatalogDcbEventLog"
  @schema type event = ProductAdded({productId: string, name: string})
}
module CatalogDcbSource = Reventless.Projection.DcbSource.Make(CatalogDcbSourceDef)
```

It's purely cosmetic. ReScript requires the inline definition to be bound to a
named module first (otherwise the functor's result type can't be inferred), so
the hand-rolled form above is usually shorter. Use whichever you prefer.

## Failure modes & debugging

| Symptom | Diagnosis |
|---------|-----------|
| `ReadModel "X" has a Mapping with sourceName "Y", but no EventTopic with that key exists` at startup | The startup fail-fast caught a typo. The error message lists all available source names — pick the right one. |
| Projection runs but state never updates | If the typo fail-fast passed, a different mapping is firing instead. Check the logs — `ReadModel(...)  handling event N/M from <sourceName>` tells you which source the event came from and which mapping matched. |
| Adding a new event variant to a DCB slice quietly loses events | Expected. Extend the consumer's `Source.event` type to include the new variant and add a `switch` arm. |

## See also

- `examples/online-shop-hybrid/catalog/src/CatalogActivity/ReadModel/` — the
  reference example for this pattern.
- `reventless/reventless-in-memory/tests/components/readmodel/DcbReadModelE2ETest.res`
  — focused integration test that exercises the DCB → ReadModel path
  end-to-end.
- [Aggregate vs DCB decision guide](aggregate-vs-dcb-decision-guide) — when to
  use Aggregate vs DCB in the first place.

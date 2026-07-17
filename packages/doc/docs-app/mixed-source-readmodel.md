# Mixed-source ReadModels — projecting Aggregate + DCB events together

A ReadModel can subscribe to events from any combination of Aggregate `EventTopic`s
and a plugin's DCB `EventLog`. The runtime registers all of them in the same
`allEventTopics` dict; `Mapping.Make` picks sources by **name**.

This guide is the application-developer reference for that pattern. The reference
implementation is Ordering's `Customers` read model in
`examples/online-shop-hybrid/`: a customer profile (from the **`Customer`
aggregate**) blended with an `orderCount` (from the plugin's **DCB log**), merged
into one row keyed by `customerId`.

## When to use it

- A read model needs *both* an Aggregate's lifecycle (e.g. `Customer`) and DCB
  slice events (e.g. `OrderPlaced`) in the same projected state.
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
| Aggregate | `<AggregateSpec.name>` (e.g. `"Customer"`) |
| DCB EventLog | `<pluginName> ++ "DcbEventLog"` (e.g. `"OrderingDcbEventLog"`) |

For DCB sources the **plugin name** is the `~name` argument the plugin's
generated `make` function passes to the framework — i.e. the same string you
read in the `Ordering/src/plugin.json` (or that defaults to your folder name).

> **Pro tip — fail-fast.** If a `Mapping.sourceName` doesn't match any key in
> `allEventTopics`, ReadModel construction throws with a clear error pointing to
> the typo. Without this check, the projection would silently
> see zero events.

## Authoring a mixed-source ReadModel

### 1. The ReadModel spec

The spec file lives in a `ReadModel/` (or `ReadModelStream/`) folder, so its
filename carries no kind suffix — the folder supplies the kind. `Customers` uses
the stream variant, which adds live updates on top of the same multi-source
dispatch:

```rescript
// ordering/src/Customer/ReadModelStream/Customers.res
@@reventless.spec

@schema
type state = {
  @displayName email: string,
  address: string,
  deactivated: bool,
  orderCount: int,
}
```

### 2. The Projections file — define each `Mapping`

The sibling body file is `Customers_Projections.res` (underscore + plural
`_Projections`). Its `@@reventless.mappings` annotation auto-injects the domain
opens, `module Target` / `module M` / `module type Mapping`, `let moduleUrl`, and
— for any inline DCB `Source` module — `module Id` + dcbTags on `*Id` fields.

The Aggregate-source mapping passes the aggregate spec module as the first
argument:

```rescript
// Customers_Projections.res
@@reventless.mappings

module CustomerMapping = Mapping.Make(
  Customer,                             // Aggregate spec module — name = "Customer"
  Customers,
  {
    open Customer
    let project = ({event, id, _}) =>
      switch event {
      | Registered({email, address}) =>
        // UpdateWithDefault, not Set, so an OrderPlaced that arrived first isn't clobbered
        UpdateWithDefault(
          id,
          {Customers.email: email, address, deactivated: false, orderCount: 0},
          s => {...s, email, address, deactivated: false},
        )
      | EmailUpdated({email}) => Update(id, s => {...s, email})
      | AddressUpdated({address}) => Update(id, s => {...s, address})
      | Deactivated => Update(id, s => {...s, deactivated: true})
      }
  },
)
```

For the DCB-source mapping, declare a small `Source`-shaped module **inline**.
The `name` MUST match the dict key (`module Id` is auto-injected by
`@@reventless.mappings`):

```rescript
// Same file, just above the DCB mapping.
module OrderEvents = {
  let name = "OrderingDcbEventLog"        // <pluginName>DcbEventLog

  @schema
  type event = OrderPlaced({orderId: string, customerId: string})
}

module CustomerOrdersMapping = Mapping.Make(
  OrderEvents,
  Customers,
  {
    open OrderEvents
    let project = ({event, _}) =>
      switch event {
      | OrderPlaced({customerId}) =>
        // Same row id (customerId) as the aggregate source → the two sources merge
        UpdateWithDefault(
          customerId,
          {Customers.email: "", address: "", deactivated: false, orderCount: 1},
          s => {...s, orderCount: s.orderCount + 1},
        )
      }
  },
)

let mappings: array<module(Mapping)> = [module(CustomerMapping), module(CustomerOrdersMapping)]
```

Both mappings target `Customers` and write to the **same row id** (`customerId`),
so the framework merges the aggregate profile and the DCB-derived `orderCount`
into one record. The auto-generated `Plugin.res` wires the pair as
`Platform.ReadModelStream.Make(Customers, Customers_Projections)` — no manual
wiring is needed.

### 3. Typed event subsetting

The DCB log carries the union of every event variant produced by every
StateChangeSlice in the plugin (`OrderPlaced`, `OrderShipped`, `CatalogProductSynced`, …).
Your `OrderEvents.event` type only needs to enumerate the variants this
projection cares about. Other variants decode as parse errors and the runtime
treats them as `Ignore` — same behaviour as Aggregate ReadModels seeing event
variants they don't enumerate.

This means:
- Adding a new `event` variant to a sibling DCB slice **does not** force
  consumers to recompile or update their projections.
- Awareness of a new variant is a deliberate developer action: extend
  `OrderEvents.event` and add a `switch` arm.

### 4. Optional helper: `Reventless.Projection.DcbSource.Make`

There's a thin functor for declaring DCB sources:

```rescript
module OrderEventsDef = {
  let name = "OrderingDcbEventLog"
  @schema type event = OrderPlaced({orderId: string, customerId: string})
}
module OrderEvents = Reventless.Projection.DcbSource.Make(OrderEventsDef)
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

- `examples/online-shop-hybrid/ordering/src/Customer/ReadModelStream/` — the
  reference example for this pattern.
- `reventless/local/tests/components/readmodel/DcbReadModelE2ETest.res`
  — focused integration test that exercises the DCB → ReadModel path
  end-to-end.
- [Aggregate vs DCB decision guide](aggregate-vs-dcb-decision-guide) — when to
  use Aggregate vs DCB in the first place.

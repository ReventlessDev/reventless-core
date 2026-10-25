# Reventless Component Catalog

Every component is a **spec file** plus, for most kinds, a **body file** beside it. The folder
names the kind; the spec file never carries a kind suffix; the body file is
`<SpecStem>_<KindWord>.res`. Spec files carry `@@reventless.spec`, which injects `let name`,
`module Id` and `let moduleUrl` — never write those by hand. Body files carry the matching
attribute (`@@reventless.decision`, `@@reventless.projection`, …), which injects `open <Spec>`,
`module Spec = <Spec>` and `let moduleUrl`.

You do not wire components into the plugin by hand: `generate-plugin` (the plugin's `prebuild`)
scans `src/` by folder and writes `src/Plugin.res`. Only the root platform is hand-written.

| Folder | Spec file | Body file |
|---|---|---|
| `Aggregate/` | `<Entity>.res` | `<Entity>_Decision.res` (+ `<Entity>_Mappings.res` for event mappings) |
| `StateChange/` | `<Slice>.res` | `<Slice>_Decision.res` |
| `StateView/`, `StateViewStream/` | `<Name>.res` | `<Name>_Projection.res` |
| `ReadModel/`, `ReadModelStream/` | `<Plural>.res` | `<Plural>_Projections.res` |
| `Automation/` | `<Slice>.res` | `<Slice>_Automation.res` |
| `InboundTranslation/`, `OutboundTranslation/` | `<Slice>.res` | `<Slice>_Translation.res` |
| `ExtensionPoint/` | `<Name>_ExtensionPoint.res` (spec package) | `<Name>_ExtensionPointMapping.res` |
| `Extension/` | — | `<Name>_Extension.res` |
| `Task/` | `<Name>.res` | — |

## Write-Side Components

### Aggregate (Aggregate approach)

Command handler with a per-entity event stream.

**Spec** (`Aggregate/Product.res`):
```rescript
@@reventless.spec

module Id = CatalogSpec.ProductId   // optional: type the entity id by an identity

@schema
type command =
  | Add({name: string, price: float})
  | Rename({name: string})

@schema
type event =
  | Added({name: string, price: float})
  | Renamed({name: string})

@schema
type error = AlreadyExists | NotFound
```

**Decision** (`Aggregate/Product_Decision.res`):
```rescript
@@reventless.decision

@schema
type state = NotCreated | Created({name: string})

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name})) => Created({name: name})
  | (Created(_), Renamed({name})) => Created({name: name})
  | _ => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name, price})) => Ok([Added({name, price})])
  | (Created(_), Add(_)) => Error(AlreadyExists)
  | (Created({name: current}), Rename({name})) => name == current ? Ok([]) : Ok([Renamed({name: name})])
  | (NotCreated, Rename(_)) => Error(NotFound)
  }
```

**Generated:** `Platform.Aggregate.Make(Product, Product_Decision, …)`

### StateChangeSlice (DCB approach)

Command handler that reads the shared event log by DCB tag. Inside a slice folder every `*Id`
field (and every identity-typed field) is a DCB tag automatically.

**Spec** (`StateChange/ChangeProductName.res`):
```rescript
@@reventless.spec

// What `evolve` reads. An arm the slice does not produce carries no id it is
// partitioned by: write `ProductAdded`, not `ProductAdded({productId})`.
@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

@schema
type command = ChangeProductName({productId: CatalogSpec.ProductId.t, name: string})

@schema
type error = ProductNotFound

@schema
type event = ProductNameChanged({productId: CatalogSpec.ProductId.t, name: string})
```

**Decision** (`StateChange/ChangeProductName_Decision.res`):
```rescript
@@reventless.decision

type state = {exists: bool, currentName: string}
let initialState = {exists: false, currentName: ""}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductName({productId, name}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if name == state.currentName {
      Ok([]) // idempotent
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
```

**Generated:** `Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Decision)`
(`MakeAsync` when the spec carries `@@reventless.async`).

## Read-Side Components

### ReadModel (Aggregate approach)

**Spec** (`ReadModel/Products.res`; `@@reventless.spec` also injects `let config` and
`let subIdConfig` in this folder):
```rescript
@@reventless.spec

module Id = CatalogSpec.ProductId   // rows keyed by this identity

@schema
type state = {
  name: string,
  @index categoryId: string,         // GSI (optional)
  price: float,
}
```

**Projections** (`ReadModel/Products_Projections.res`) — one mapping per source aggregate:
```rescript
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, price}) => Set(id, {Products.name, categoryId: "", price})
      | Renamed({name}) => Update(id, (state: Products.state) => {...state, name})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

**Generated:** `Platform.ReadModel.Make(Products, Products_Projections)`
(`ReadModelStream/` → `Platform.ReadModelStream.Make`, for live updates).

### StateViewSlice (DCB approach)

**Spec** (`StateView/Products.res`; injects `open Reventless.Projection`, `let config`,
`let subIdConfig`, and a string row key unless you declare `module Id`):
```rescript
@@reventless.spec

module Id = CatalogSpec.ProductId

@schema
type state = {productId: CatalogSpec.ProductId.t, name: string, price: float}

@schema
type consumedEvent =
  | ProductAdded({productId: CatalogSpec.ProductId.t, name: string, price: float})
  | ProductNameChanged({productId: CatalogSpec.ProductId.t, name: string})
```

**Projection** (`StateView/Products_Projection.res`):
```rescript
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, price}) => [Set(productId, {productId, name, price})]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  }
```

Key annotations on `state` fields (`@id`, `@subId`, `@index`, `@resolves`, …) are in
`references/querydb-key-patterns.md`.

**Generated:** `Platform.StateViewSlice.Make(Products, Products_Projection)`
(`StateViewStream/` → `Platform.StateViewSliceStream.Make`).

## Cross-Plugin Components

### ExtensionPoint Spec (in the spec package)

`<Name>_ExtensionPoint.res` — in a `*Spec` namespace the name is prefixed (`Catalog.Products`):
```rescript
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: ProductId.t, name: string, price: float})
  | ProductPriceChanged({productId: ProductId.t, price: float})

@schema
type directive = unit
```

### ExtensionPoint Mapping (in the plugin)

Maps internal events to the public ones; its `module Delegate` and the published-event table are
derived by the PPX. See `references/cross-plugin-patterns.md`.

### Extension (in the plugin)

`Extension/<Name>_Extension.res` with `@@reventless.extension` and a `module Mapping`; routes
another plugin's public events to local commands. See `references/cross-plugin-patterns.md`.

## Automation Components (DCB only)

### AutomationSlice

**Spec** (`Automation/AutoShipOrder.res`):
```rescript
@@reventless.spec

@schema
type todoItem = {orderId: OrderId.t}

@schema
type command = ShipOrder({orderId: OrderId.t})

let maxRetries = 3
let targetName = "ShipOrder"
```

**Body** (`Automation/AutoShipOrder_Automation.res`) — one mapping per event source, then
`process` and `onExhausted`:
```rescript
@@reventless.automation

module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: OrderId.t})
    | OrderShipped({orderId: OrderId.t})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource
    let collect = (event, ~sourceId as _, _ctx) =>
      switch event {
      | OrderPlaced({orderId}) => [(orderId->OrderId.toString, ({orderId: orderId}: AutoShipOrder.todoItem))]
      | OrderShipped(_) => []
      }
    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) => Some(orderId->OrderId.toString)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, item: AutoShipOrder.todoItem) => Some((id, ShipOrder({orderId: item.orderId})))

let onExhausted = (_id, _item) => None
```

**Generated:** `Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)`

### InboundTranslationSlice

An anti-corruption door: external input in, commands out.

**Spec** (`InboundTranslation/ImportProduct.res`):
```rescript
@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))   // who may call the door

@schema
type externalInput = {sku: string, title: string, unitPrice: int, currency: string}

@schema
type command = AddProduct({productId: CatalogSpec.ProductId.t, name: string, price: float})

let targetName = "AddProduct"                   // the slice or aggregate that receives it
let externalSystem = Some("SupplierFeed")       // drawn outside the plugin in the Event Graph
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
let endpoint = None                             // or Some({path, auth, role}) for a webhook URL
```

Mark a field `@sensitive` (a password, a proof) to keep its value out of the door's audit row.

**Body** (`InboundTranslation/ImportProduct_Translation.res`):
```rescript
@@reventless.translation

let translate = async (input, ~capabilities as _, ~caller as _) =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else {
    Ok([
      (
        input.sku,
        AddProduct({
          productId: CatalogSpec.ProductId.makeFromString(input.sku),
          name: input.title,
          price: Int.toFloat(input.unitPrice) /. 100.0,
        }),
      ),
    ])
  }
```

`translate` returns `Ok([(targetId, command), …])`, `Ok([])` for an idempotent no-op, or
`Error(msg)`. It is handed `~capabilities` (the platform's providers, for a door that must act
before any command exists) and `~caller` (`option<Reventless.Identity.t>`: who called, or `None`
where the platform acts for itself), so a door can refuse on its caller before doing anything.
Each returned command is still checked against the caller's rule.

**Generated:** `Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)`

### OutboundTranslationSlice

Events in, calls to an outside system out, optionally a command back.

**Spec** (`OutboundTranslation/SendOrderConfirmation.res`):
```rescript
@@reventless.spec

@schema
type consumedEvent = OrderPlaced({orderId: OrderId.t, customerId: CustomerId.t})

@schema
type outboundItem = {orderId: OrderId.t, customerId: CustomerId.t}

@schema
type inboundCommand = unit                      // or the command sent back

let maxRetries = 3
let targetName = None                           // or Some(<receiver name>) when a command goes back
let sourceNames: array<string> = []             // [] = this plugin's own DCB event log
let externalSystem = Some("EmailService")
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []   // e.g. [Messaging]
```

**Body** (`OutboundTranslation/SendOrderConfirmation_Translation.res`):
```rescript
@@reventless.translation

let collect = (event, ~sourceId as _) =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId->OrderId.toString, {orderId, customerId})]
  }

let translate = async (_id, item, ~capabilities as _) =>
  try {
    await EmailService.sendOrderConfirmation(
      ~email=item.customerId->CustomerId.toString,
      ~orderId=item.orderId->OrderId.toString,
    )
    Ok(None)
  } catch {
  | _ => Error("email send failed")
  }

let onExhausted = (_id, _item, ~lastError as _) => None
```

`translate` returns `Ok(None)`, `Ok(Some((targetId, inboundCommand)))`, or `Error(msg)` to retry.
A slice that reaches a platform capability names it in `capabilityNeeds` and calls it through
`capabilities` (`capabilities.messaging.send(…)`).

**Generated:** `Platform.OutboundTranslationSlice.Make(SendOrderConfirmation, SendOrderConfirmation_Translation)`

## Infrastructure Components

### Plugin

Generated: `src/Plugin.res` is written by `generate-plugin` from the folders under `src/`
(and from packages listed in `src/plugin.json`'s `slicesFrom`). Commit it; never edit it.
`src/plugin.json` sets the name and heartbeat interval.

### Platform

The top-level composition, hand-written in the platform package:

```rescript
module Platform = ReventlessLocal.Platform.Make()
module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)
Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)
```

# DCB Architecture — Code Templates

Each slice is a spec file and a body file in its kind's folder. `@@reventless.spec` injects
`let name`, `module Id` and `let moduleUrl`; in a slice folder it also makes every `*Id` field —
and every field typed by an identity (`ProductId.t`) — a DCB tag. Body files carry
`@@reventless.decision` / `.projection` / `.automation` / `.translation`, which open the spec. The
plugin's `src/Plugin.res` is generated from the folders; you never write it.

## Identity (e.g., `src/Product/ProductId.res`)

```rescript
include Reventless.Id.Make({
  let key = "productId"
})
```

A field typed `ProductId.t` is tagged by its type, whatever it is called. Make one where an id
is created (`ProductId.makeFromString(sku)`) and read it with `ProductId.toString`.

## StateChangeSlice (e.g., `Product/StateChange/AddProduct.res`)

```rescript
// AddProduct StateChangeSlice.
// Rejects a second creation of the same product.
@@reventless.spec

// What `evolve` folds. An arm this slice does not produce must not declare the
// id the slice is partitioned by: write `ProductAdded`, not `ProductAdded({productId})`.
@schema
type consumedEvent = ProductAdded

@schema
type command =
  AddProduct({productId: ProductId.t, name: string, description: string, price: float})

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({productId: ProductId.t, name: string, description: string, price: float})
```

`Product/StateChange/AddProduct_Decision.res`:

```rescript
@@reventless.decision

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

## StateChangeSlice with Idempotency (e.g., `ChangeProductName.res`)

```rescript
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

@schema
type command = ChangeProductName({productId: ProductId.t, name: string})

@schema
type error = ProductNotFound

@schema
type event = ProductNameChanged({productId: ProductId.t, name: string})
```

`ChangeProductName_Decision.res`:

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
      Ok([]) // idempotent — a retried command changes nothing
    } else {
      Ok([ProductNameChanged({productId, name})])
    }
  }
```

## StateViewSlice (e.g., `Product/StateView/Products.res`)

```rescript
// Products StateViewSlice.
@@reventless.spec   // also injects: open Reventless.Projection, let config, let subIdConfig

// Rows are keyed by this identity (a string key when left out).
module Id = ProductId

@schema
type state = {productId: ProductId.t, name: string, description: string, price: float}

@schema
type consumedEvent =
  | ProductAdded({productId: ProductId.t, name: string, description: string, price: float})
  | ProductNameChanged({productId: ProductId.t, name: string})
  | ProductPriceChanged({productId: ProductId.t, price: float})
```

`Product/StateView/Products_Projection.res`:

```rescript
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
```

Put the view in `StateViewStream/` instead of `StateView/` for live updates to subscribers.

## StateViewSlice with sort key and GSI (e.g., `OrderLineItems.res`)

Use `@subId` to enable sort-key range queries, `@index` to declare a GSI for querying by a
secondary field, and `@resolves` to add a virtual cross-table field (its `table` must be a view
of the same plugin). Details: `references/querydb-key-patterns.md`.

```rescript
@@reventless.spec

@schema
type state = {
  @id orderId: string,
  @subId lineItemId: string,           // enables orderLineItemsById(id, prefix?, from?, to?, …)
  @index categoryId: string,           // GSI: query by categoryId
  @resolves({table: "Products", field: "product"}) productId: string,  // virtual field
  quantity: int,
  price: float,
}

@schema
type consumedEvent =
  | LineItemAdded({
      orderId: string,
      lineItemId: string,
      productId: string,
      categoryId: string,
      quantity: int,
      price: float,
    })
  | LineItemRemoved({orderId: string, lineItemId: string})
```

`OrderLineItems_Projection.res` — with a sort key, one order holds several rows, so they are
written with the multi-row actions, keyed by the order:

```rescript
@@reventless.projection

let project = ({event}) =>
  switch event {
  | LineItemAdded({orderId, lineItemId, productId, categoryId, quantity, price}) => [
      UpdateMultiState(
        orderId,
        rows =>
          rows
          ->Array.filter(row => row.lineItemId != lineItemId)
          ->Array.concat([{orderId, lineItemId, productId, categoryId, quantity, price}]),
      ),
    ]
  | LineItemRemoved({orderId, lineItemId}) => [
      UpdateMultiState(orderId, rows => rows->Array.filter(row => row.lineItemId != lineItemId)),
    ]
  }
```

## AutomationSlice (e.g., `Order/Automation/AutoShipOrder.res`)

```rescript
// AutoShipOrder AutomationSlice.
// On OrderPlaced, issue ShipOrder; done when OrderShipped arrives.
@@reventless.spec

@schema
type todoItem = {orderId: OrderId.t}

@schema
type command = ShipOrder({orderId: OrderId.t})

let maxRetries = 3
let targetName = "ShipOrder"
```

`Order/Automation/AutoShipOrder_Automation.res` — the consumed events come from one mapping per
source:

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
      // To-do rows are keyed by string; the item keeps the typed id.
      | OrderPlaced({orderId}) => [
          (orderId->OrderId.toString, ({orderId: orderId}: AutoShipOrder.todoItem)),
        ]
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

// After maxRetries: a command to record the failure, or None when the domain has
// no state for it.
let onExhausted = (_id, _item) => None
```

## InboundTranslationSlice (e.g., `Product/InboundTranslation/ImportProduct.res`)

```rescript
// ImportProduct InboundTranslationSlice.
// Receives supplier JSON, validates it, and translates it into AddProduct.
@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))

@schema
type externalInput = {
  sku: string,
  title: string,
  desc: string,
  unitPrice: int,
  currency: string,
}

@schema
type command =
  AddProduct({productId: ProductId.t, name: string, description: string, price: float})

let targetName = "AddProduct"
let externalSystem = Some("SupplierFeed")
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
let endpoint = None
```

`Product/InboundTranslation/ImportProduct_Translation.res`:

```rescript
@@reventless.translation

let translate = async (input, ~capabilities as _, ~caller as _) =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else {
    Ok([
      (
        input.sku,
        AddProduct({
          // The external SKU becomes the catalog's product id here, at the edge.
          productId: ProductId.makeFromString(input.sku),
          name: input.title,
          description: input.desc,
          price: Int.toFloat(input.unitPrice) /. 100.0,
        }),
      ),
    ])
  }
```

`~capabilities` reaches a platform provider before any command exists (name it in
`capabilityNeeds`). `~caller` is `option<Reventless.Identity.t>`: refuse there when only some
callers may use the door, e.g. `| Some(c) if c->Reventless.Identity.hasGroup("Finance") => …`.

## OutboundTranslationSlice (e.g., `Order/OutboundTranslation/SendOrderConfirmation.res`)

```rescript
// SendOrderConfirmation OutboundTranslationSlice.
// On OrderPlaced, sends a confirmation email. Fire-and-forget: no command back.
@@reventless.spec

@schema
type consumedEvent = OrderPlaced({orderId: OrderId.t, customerId: CustomerId.t})

@schema
type outboundItem = {orderId: OrderId.t, customerId: CustomerId.t}

@schema
type inboundCommand = unit

let maxRetries = 3
let targetName = None
let sourceNames: array<string> = []   // this plugin's own DCB event log
let externalSystem = Some("EmailService")
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
```

`Order/OutboundTranslation/SendOrderConfirmation_Translation.res`:

```rescript
@@reventless.translation

let collect = (event, ~sourceId as _) =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId->OrderId.toString, {orderId, customerId})]
  }

let translate = async (_id, item, ~capabilities as _) => {
  try {
    await EmailService.sendOrderConfirmation(
      ~email=item.customerId->CustomerId.toString,
      ~orderId=item.orderId->OrderId.toString,
    )
    Ok(None)
  } catch {
  | exn =>
    let msg =
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("send failed")
    Error(msg) // retried, up to maxRetries
  }
}

let onExhausted = (_id, _item, ~lastError as _) => None
```

To send through the platform's mailer instead of a service of your own, declare
`capabilityNeeds = [Reventless.CapabilityNeed.Messaging]` and call
`capabilities.messaging.send(~recipient, ~message)`.

## DCB Plugin Composition

Generated. `generate-plugin` runs in the plugin's `prebuild`, scans `src/` by folder, and writes
`src/Plugin.res`, which is committed. For the catalog above it emits, among the rest:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Decision)
  module ProductsSlice = Platform.StateViewSlice.Make(Products, Products_Projection)
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(
    ImportProduct,
    ImportProduct_Translation,
  )
  // … pluginStructure and make() ...
}
```

`src/plugin.json` sets the plugin's name and heartbeat interval. Run `pnpm run generate` after
adding a file if you are not running a full build.

## Directory Structure

```
plugin-name/
├── package.json
├── rescript.json
├── src/
│   ├── plugin.json
│   ├── Plugin.res                 # generated — never edit
│   ├── Roles.res                  # the plugin's roles, if any rule names one
│   ├── EntityName/                # a chapter
│   │   ├── EntityNameId.res       # its identity
│   │   ├── StateChange/
│   │   │   ├── AddEntityName.res
│   │   │   └── AddEntityName_Decision.res
│   │   ├── StateView/
│   │   │   ├── EntityNames.res
│   │   │   └── EntityNames_Projection.res
│   │   ├── Automation/            # if needed
│   │   │   ├── AutoProcessName.res
│   │   │   └── AutoProcessName_Automation.res
│   │   ├── InboundTranslation/    # if needed
│   │   │   ├── ImportEntityName.res
│   │   │   └── ImportEntityName_Translation.res
│   │   └── OutboundTranslation/   # if needed
│   │       ├── SendNotification.res
│   │       └── SendNotification_Translation.res
│   ├── Extension/
│   │   └── Other_Extension.res
│   ├── ExtensionPoint/
│   │   └── EntityNames_ExtensionPointMapping.res
│   └── Service/                   # wrappers for services the framework does not broker
│       └── EmailService.res
└── tests/                         # mirrors src/ one to one, _GWT.res files only
    └── EntityName/
        ├── StateChange/
        │   └── AddEntityName_GWT.res
        └── StateView/
            └── EntityNames_GWT.res
```

Filename stems must be unique across the plugin. Test templates are in
`references/testing-patterns.md`.

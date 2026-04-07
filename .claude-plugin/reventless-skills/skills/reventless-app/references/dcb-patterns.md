# DCB Architecture — Code Templates

## StateChangeSlice (e.g., AddProduct.res)

```rescript
@@reventless.spec   // injects: let name, module Id, let moduleUrl
@@reventless.dcbTags  // injects @s.matches(DcbTag.string) on *Id fields

open Reventless

type state = {exists: bool}
let initialState = {exists: false}

@schema
type consumedEvent =
  | ProductAdded

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

@schema
type command =
  | AddProduct({
      productId: string,  // @s.matches(DcbTag.string) injected by @@reventless.dcbTags
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type producedEvent =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

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

## StateChangeSlice with Idempotency (e.g., ChangeProductName.res)

```rescript
@@reventless.spec
@@reventless.dcbTags

open Reventless

type state = {exists: bool, currentName: string}
let initialState = {exists: false, currentName: ""}

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})

let evolve = (state, event) =>
  switch event {
  | ProductAdded({name}) => {exists: true, currentName: name}
  | ProductNameChanged({name}) => {...state, currentName: name}
  }

@schema
type command = ChangeProductName({
  productId: string,
  name: string,
})

@schema
type error = ProductNotFound

@schema
type producedEvent = ProductNameChanged({
  productId: string,
  name: string,
})

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

## StateViewSlice (e.g., ProductsView.res)

```rescript
@@reventless.spec  // injects: let name, module Id, let makeId, let subIdConfig, let config

open Reventless.Projection

@schema
type state = {
  @id productId: string,
  name: string,
  description: string,
  price: float,
}

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})

let project = event =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [
      Update(productId, state => {...state, name}),
    ]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [
      Update(productId, state => {...state, price}),
    ]
  }
```

## StateViewSlice with sort key and GSI (e.g., OrderLineItemsView.res)

Use `@subId` to enable sort-key range queries (`{name}ById`). Use `@index` to declare a GSI for querying by a secondary field. Use `@resolves` to add a virtual cross-table join field.

```rescript
@@reventless.spec

open Reventless.Projection

@schema
type state = {
  @id orderId: string,
  @subId lineItemId: string,           // enables orderLineItemsById(id, prefix?, from?, to?, ...) 
  @index categoryId: string,           // GSI: query by categoryId
  @resolves({table: "Products", field: "product"}) productId: string,  // virtual field
  quantity: int,
  price: float,
}

@schema
type consumedEvent =
  | LineItemAdded({orderId: string, lineItemId: string, productId: string, categoryId: string, quantity: int, price: float})
  | LineItemRemoved({orderId: string, lineItemId: string})

let project = event =>
  switch event {
  | LineItemAdded({orderId, lineItemId, productId, categoryId, quantity, price}) => [
      Set(lineItemId, {orderId, lineItemId, productId, categoryId, quantity, price}),
    ]
  | LineItemRemoved({orderId: _, lineItemId}) => [Delete(lineItemId)]
  }
```

## AutomationSlice (e.g., AutoShipOrder.res)

```rescript
open Reventless

let name = "AutoShipOrder"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | OrderShipped({orderId: string})

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | OrderShipped(_) => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | OrderPlaced(_) => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))

let maxRetries = 3
let heartbeatInterval = 60
```

## InboundTranslationSlice (e.g., ImportProduct.res)

```rescript
open Reventless

let name = "ImportProduct"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type externalInput = {
  sku: string,
  title: string,
  desc: string,
  unitPrice: int,
  currency: string,
}

@schema
type command = AddProduct({
  productId: @s.matches(DcbTag.string) string,
  name: string,
  description: string,
  price: float,
})

let translate = input =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else {
    Ok((
      input.sku,
      AddProduct({
        productId: input.sku,
        name: input.title,
        description: input.desc,
        price: Int.toFloat(input.unitPrice) /. 100.0,
      }),
    ))
  }
```

## OutboundTranslationSlice (e.g., SendOrderConfirmation.res)

```rescript
let name = "SendOrderConfirmation"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string})

@schema
type outboundItem = {orderId: string, customerId: string}

@schema
type inboundCommand = unit

let collect = event =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId, {orderId, customerId})]
  }

let translate = async (_id, item) => {
  try {
    await EmailService.sendOrderConfirmation(
      ~email=item.customerId,
      ~orderId=item.orderId,
    )
    Ok(None)
  } catch {
  | exn =>
    let msg =
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("send failed")
    Error(msg)
  }
}

let maxRetries = 3
let heartbeatInterval = 60
```

## DCB Plugin Composition (e.g., CatalogPlugin.res)

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // 1. Wire StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  // 2. Wire StateViewSlices
  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  // 3. Wire InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // 4. Self-assembly
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~api, ~apiRole, ~scheduler,
      ~stateChangeSlices=[
        module(AddProductSlice),
        module(ChangeProductNameSlice),
        module(ChangeProductPriceSlice),
      ],
      ~stateViewSlices=[module(ProductsViewSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
    )
}
```

## Directory Structure

```
plugin-name/
├── package.json
├── rescript.json
├── src/
│   ├── EntityName/
│   │   ├── StateChangeSlice/
│   │   │   ├── AddEntityName.res
│   │   │   ├── ChangeEntityField.res
│   │   │   └── ...
│   │   ├── StateViewSlice/
│   │   │   └── EntityNamesView.res
│   │   ├── AutomationSlice/        # if needed
│   │   │   └── AutoProcessName.res
│   │   ├── InboundTranslationSlice/ # if needed
│   │   │   └── ImportEntityName.res
│   │   └── OutboundTranslationSlice/ # if needed
│   │       └── SendNotification.res
│   ├── Extension/
│   │   └── ExternalExtension.res
│   ├── ExtensionPoint/
│   │   └── EntityNamesExtensionPointMapping.res
│   ├── Plugin/
│   │   └── PluginNamePlugin.res
│   └── Service/                     # external service wrappers
│       └── EmailService.res
└── tests/
    ├── EntityName/
    │   ├── StateChangeSlice/
    │   │   └── *DecisionTest.res
    │   └── StateViewSlice/
    │       └── *ViewTest.res
    └── E2E/
        └── *E2ETest.res
```

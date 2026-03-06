# Plan: DCB Online Shop — AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice

Add three new features to the DCB online shop example demonstrating the remaining slice types. See `docs/analysis/dcb-online-shop-missing-slices.md` for the analysis behind these choices.

**Branch**: feature/dcb-online-shop-slices (from alpha)
**Status**: Complete

---

## Step 1: Auto-Ship Order — AutomationSlice (Ordering Plugin)

**Goal**: When `OrderPlaced` is emitted, automatically issue a `ShipOrder` command. Mark the TODO item resolved when `OrderShipped` arrives.

### 1a. Verify ShipOrder StateChangeSlice exists

The `ShipOrder` StateChangeSlice already exists at `examples/online-shop-dcb/ordering/src/Order/StateChangeSlice/ShipOrder.res`. Confirm it handles the `ShipOrder` command and emits `OrderShipped`. No changes expected.

- [x] Read `ShipOrder.res` and verify spec

### 1b. Create AutoShipOrder automation spec

Create `examples/online-shop-dcb/ordering/src/Order/AutomationSlice/AutoShipOrder.res`:

```rescript
open Reventless
open OrderingEventLog

let name = "AutoShipOrder"
module DcbEventLogSpec = OrderingEventLog

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | _ => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | _ => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))

let maxRetries = 3
let heartbeatInterval = 60
```

- [x] Create `AutoShipOrder.res`
- [x] Add source dir to `rescript.json` if needed — not needed, `{"dir": "src", "subdirs": true}` already covers it

### 1c. Wire into OrderingPlugin

Update `examples/online-shop-dcb/ordering/src/Plugin/OrderingPlugin.res`:
- Add `module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)`
- Add `module(AutoShipOrderSlice)` to `automationSlices` array in DcbSpec

- [x] Update `OrderingPlugin.res`

### 1d. Build and verify

- [x] Run `npm run build` from monorepo root — zero warnings
- [x] Run `npm test` in the ordering package — all existing tests pass (48 passed)

---

## Step 2: Import Product from Supplier — InboundTranslationSlice (Catalog Plugin)

**Goal**: Receive external supplier JSON (`{sku, title, desc, unitPrice, currency}`), validate and translate to an `AddProduct` command via an anti-corruption layer.

### 2a. Create ImportProduct inbound translation spec

Create `examples/online-shop-dcb/catalog/src/Product/InboundTranslationSlice/ImportProduct.res`:

```rescript
open Reventless
open CatalogEventLog

let name = "ImportProduct"
module DcbEventLogSpec = CatalogEventLog

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

let translate = (input: externalInput) =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else if input.sku === "" {
    Error("SKU is required")
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

- [x] Create `ImportProduct.res`
- [x] Add source dir to `rescript.json` if needed — not needed, `{"dir": "src", "subdirs": true}` already covers it

### 2b. Wire into CatalogPlugin

Update `examples/online-shop-dcb/catalog/src/Plugin/CatalogPlugin.res`:
- Add `module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)`
- Add `module(ImportProductSlice)` to `inboundTranslationSlices` array in DcbSpec

- [x] Update `CatalogPlugin.res`

### 2c. Build and verify

- [x] Run `npm run build` from monorepo root — zero warnings
- [x] Run `npm test` in the catalog package — all existing tests pass (44 passed)

---

## Step 3: Send Order Confirmation Email — OutboundTranslationSlice (Ordering Plugin)

**Goal**: When `OrderPlaced` is emitted, call a (stubbed) email service to send a confirmation. Fire-and-forget pattern (`inboundCommand = unit`).

### 3a. Create EmailService stub

Create `examples/online-shop-dcb/ordering/src/Service/EmailService.res`:

```rescript
let sendOrderConfirmation = async (~email as _: string, ~orderId as _: string) => {
  Console.log("[EmailService] Order confirmation sent")
}
```

- [x] Create `EmailService.res`
- [x] Add source dir to `rescript.json` if needed — not needed, `{"dir": "src", "subdirs": true}` already covers it

### 3b. Create SendOrderConfirmation outbound translation spec

Create `examples/online-shop-dcb/ordering/src/Order/OutboundTranslationSlice/SendOrderConfirmation.res`:

```rescript
open OrderingEventLog

let name = "SendOrderConfirmation"
module DcbEventLogSpec = OrderingEventLog

@schema
type outboundItem = {orderId: string, customerId: string}

@schema
type inboundCommand = unit

let collect = event =>
  switch event {
  | OrderPlaced({orderId, customerId}) =>
    [(orderId, {orderId, customerId})]
  | _ => []
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
      exn
      ->JsExn.fromException
      ->Option.flatMap(JsExn.message)
      ->Option.getOr("email send failed")
    Error(msg)
  }
}

let maxRetries = 3
let heartbeatInterval = 60
```

- [x] Create `SendOrderConfirmation.res`
- [x] Add source dir to `rescript.json` if needed — not needed, `{"dir": "src", "subdirs": true}` already covers it

### 3c. Wire into OrderingPlugin

Update `examples/online-shop-dcb/ordering/src/Plugin/OrderingPlugin.res`:
- Add `module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)`
- Add `module(SendOrderConfirmationSlice)` to `outboundTranslationSlices` array in DcbSpec

- [x] Update `OrderingPlugin.res`

### 3d. Build and verify

- [x] Run `npm run build` from monorepo root — zero warnings
- [x] Run `npm test` in the ordering package — all existing tests pass (48 passed)

---

## Step 4: Update DCB documentation page

Update `packages/doc/docs-online-shop/dcb-based.md` to document the three new features:
- Add an "Automation: Auto-Ship Order" section under Ordering's Chapter: Order
- Add an "Inbound Translation: Import Product from Supplier" section under Catalog's Chapter: Product
- Add an "Outbound Translation: Send Order Confirmation Email" section under Ordering's Chapter: Order
- Include code snippets matching the implementation walkthrough style of existing sections

- [x] Update `dcb-based.md`

---

## Step 5: Final verification

- [x] `npm run build` from root — zero warnings across all packages
- [x] `npm test` from root — all tests pass (85 suites, 697 tests)
- [x] Verify the three new slice types appear in plugin DcbSpec arrays
- [x] Commit with message: `feat(examples): add AutomationSlice, InboundTranslationSlice, and OutboundTranslationSlice to DCB online shop`

---

## Files Created/Modified

### New files
- `examples/online-shop-dcb/ordering/src/Order/AutomationSlice/AutoShipOrder.res`
- `examples/online-shop-dcb/catalog/src/Product/InboundTranslationSlice/ImportProduct.res`
- `examples/online-shop-dcb/ordering/src/Service/EmailService.res`
- `examples/online-shop-dcb/ordering/src/Order/OutboundTranslationSlice/SendOrderConfirmation.res`

### Modified files
- `examples/online-shop-dcb/ordering/src/Plugin/OrderingPlugin.res` (wire AutomationSlice + OutboundTranslationSlice)
- `examples/online-shop-dcb/catalog/src/Plugin/CatalogPlugin.res` (wire InboundTranslationSlice)
- `packages/doc/docs-online-shop/dcb-based.md` (document new features)

### Not modified (no changes needed)
- `examples/online-shop-dcb/ordering/rescript.json` — `{"dir": "src", "subdirs": true}` already covers new subdirs
- `examples/online-shop-dcb/catalog/rescript.json` — same

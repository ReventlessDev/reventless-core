# Plan: Aggregates Online Shop — EventMapper, SideEffectHandler, and Task

Add three new features to the aggregates online shop example demonstrating the remaining component types. See `docs/analysis/aggregates-online-shop-missing-components.md` for the analysis behind these choices.

**Branch**: feature/aggregates-online-shop-components (from alpha)

---

## Step 1: Auto-Ship Order — EventMapper (Ordering Plugin)

**Goal**: When `Order.Placed` is emitted, automatically issue an `Order.Ship` command for the same aggregate. Stateless fire-and-forget — no TODO list, no resolution tracking.

### 1a. Verify Order aggregate supports Ship command

The Order aggregate at `examples/online-shop-aggregates/ordering/src/Aggregate/Order.res` already defines `Ship` as a command and `Shipped` as an event. The behavior in `OrderBehavior.res` handles `Ship` when in `Placed` state and is idempotent when already `Shipped`. No changes needed.

- [ ] Confirm `Order.res` and `OrderBehavior.res` — no modifications required

### 1b. Create Order EventMappings

Create `examples/online-shop-aggregates/ordering/src/EventMappings/Order_EventMappings.res`:

```rescript
// Order event mappings — maps Order events to Order commands.
// When an order is placed, automatically issue a Ship command.

open Reventless

module Target = Order

module AutoShipMapping = {
  module Source = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Placed(_) => [
        EventMapping.Publish(orderId, Order.Ship),
      ]
    | _ => []
    }
}

module type Mapping = EventMapping.T with module Target := Target

let mappings: array<module(Mapping)> = [module(AutoShipMapping)]

let counter = None
```

- [ ] Create `Order_EventMappings.res`

### 1c. Wire into OrderingPlugin

Update `examples/online-shop-aggregates/ordering/src/OrderingPlugin.res`:
- Replace `ReventlessInfra.NoEventMappings.Make(Order)` with `Order_EventMappings` in the `OrderAggregate` definition

Change:
```rescript
module OrderAggregate = Platform.Aggregate.Make(
  Order,
  OrderBehavior,
  ReventlessInfra.NoEventMappings.Make(Order),
)
```

To:
```rescript
module OrderAggregate = Platform.Aggregate.Make(
  Order,
  OrderBehavior,
  Order_EventMappings,
)
```

- [ ] Update `OrderingPlugin.res`

### 1d. Build and verify

- [ ] Run `npm run build` from monorepo root — zero warnings
- [ ] Run `npm test` in the ordering package — all existing tests pass

---

## Step 2: Import Products from CSV — Task (Catalog Plugin)

**Goal**: When a CSV file is uploaded to an S3 bucket, parse each row and publish `Product.Add` commands. Uses the file-triggered Task pattern.

### 2a. Create ImportProducts Task

Create `examples/online-shop-aggregates/catalog/src/Task/ImportProducts.res`:

```rescript
// Import products from a CSV file uploaded to S3.
// Each row is translated to a Product.Add command.

open Reventless

let name = "ImportProducts"

let importCallback = (~eventName, ~key) => {
  if eventName->String.includes("ObjectCreated") {
    // In production, this would read and parse the CSV from S3.
    // For the example, we demonstrate the Task action pattern.
    Console.log("[ImportProducts] Processing file: " ++ key)

    [
      Task.PublishCommands(
        "Product",
        [
          {
            Message.id: key, // use filename as product ID for simplicity
            meta: Message.generateMeta(~service="ImportProducts", ~user="system"),
            commandJson: Product.Add({
              name: "Imported Product",
              description: "Imported from " ++ key,
              price: 9.99,
            })->Message.encode(Product.commandSchema),
          },
        ],
      ),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.buckets: Some([
    {
      bucketName: Some("product-imports"),
      bucketMode: Task.Read,
      callback: Some(importCallback),
    },
  ]),
  sideEffects: None,
}
```

- [ ] Create `ImportProducts.res`

### 2b. Wire into CatalogPlugin

Update `examples/online-shop-aggregates/catalog/src/CatalogPlugin.res`:
- Add the Task to the plugin's `make` function

The Task component is passed to `Platform.Plugin.make` via the `~tasks` parameter. Add:

```rescript
module ImportProductsTask = Platform.Task.Make(ImportProducts)
```

And include `module(ImportProductsTask)` in the tasks list passed to `Plugin.make`.

- [ ] Update `CatalogPlugin.res`

### 2c. Build and verify

- [ ] Run `npm run build` from monorepo root — zero warnings
- [ ] Run `npm test` in the catalog package — all existing tests pass

**Note**: The exact Task wiring depends on the `Platform.Task.Make` functor signature and `Plugin.make` parameters. If the Plugin assembly doesn't support a `~tasks` parameter, the Task may need to be created alongside the plugin in the platform assembly (`Main.res`) instead. Adjust wiring based on the actual API during implementation.

---

## Step 3: Send Order Confirmation Email — SideEffectHandler (Ordering Plugin)

**Goal**: When `Order.Placed` is emitted, call a (stubbed) email service. Fire-and-forget — no retry tracking, no TODO list.

### 3a. Create EmailService stub

Create `examples/online-shop-aggregates/ordering/src/Service/EmailService.res`:

```rescript
// Stub email service for the example.
// In production this would call an external email API.

let sendOrderConfirmation = async (~email as _: string, ~orderId as _: string) => {
  Console.log("[EmailService] Order confirmation sent")
}
```

- [ ] Create `EmailService.res`

### 3b. Create Order SideEffect

Create `examples/online-shop-aggregates/ordering/src/SideEffect/Order_EmailNotification.res`:

```rescript
// Send an order confirmation email when an order is placed.

module Source = {
  let name = Order.name
  module Id = Order.Id
  @schema type event = Order.event
}

let execute = async (orderId, _meta, event, _queryEngine) =>
  switch event {
  | Order.Placed({customerId}) =>
    await EmailService.sendOrderConfirmation(
      ~email=customerId, // simplified: use customerId as email placeholder
      ~orderId=orderId->Order.Id.toString,
    )
  | _ => ()
  }
```

- [ ] Create `Order_EmailNotification.res`

### 3c. Wire into OrderingPlugin

Update `examples/online-shop-aggregates/ordering/src/OrderingPlugin.res`:
- Create the SideEffectHandler with the side effect module and add it to the plugin

Add the side effect handler creation after the existing aggregate and read model definitions:

```rescript
let orderSideEffects: ReventlessInfra.SideEffectHandler.sideEffects = [
  module(Order_EmailNotification),
]
```

Pass this to `Platform.Plugin.make` via the appropriate parameter (e.g., `~sideEffects`).

- [ ] Update `OrderingPlugin.res`

### 3d. Build and verify

- [ ] Run `npm run build` from monorepo root — zero warnings
- [ ] Run `npm test` in the ordering package — all existing tests pass

**Note**: The exact SideEffectHandler wiring depends on how `Platform.Plugin.make` accepts side effects. It may be passed as a `~sideEffects` parameter, or the SideEffectHandler may need to be created as a separate component via `Platform.SideEffectHandler.Make(...)`. Adjust wiring based on the actual API during implementation.

---

## Step 4: Update aggregate documentation page

Update `packages/doc/docs-online-shop/aggregate-based.md` to document the three new features:
- Add an "EventMapper: Auto-Ship Order" section under the Order aggregate
- Add a "Task: Import Products from CSV" section under the Catalog plugin
- Add a "SideEffectHandler: Send Order Confirmation Email" section under the Order aggregate
- Include code snippets matching the implementation walkthrough style of existing sections

- [ ] Update `aggregate-based.md`

---

## Step 5: Final verification

- [ ] `npm run build` from root — zero warnings across all packages
- [ ] `npm test` from root — all tests pass
- [ ] Verify the EventMapper replaces `NoEventMappings` for Order aggregate
- [ ] Verify the SideEffectHandler and Task are wired into the plugin assembly
- [ ] Commit with message: `feat(examples): add EventMapper, SideEffectHandler, and Task to aggregates online shop`

---

## Files Created/Modified

### New files
- `examples/online-shop-aggregates/ordering/src/EventMappings/Order_EventMappings.res`
- `examples/online-shop-aggregates/ordering/src/Service/EmailService.res`
- `examples/online-shop-aggregates/ordering/src/SideEffect/Order_EmailNotification.res`
- `examples/online-shop-aggregates/catalog/src/Task/ImportProducts.res`

### Modified files
- `examples/online-shop-aggregates/ordering/src/OrderingPlugin.res` (wire EventMapper + SideEffectHandler)
- `examples/online-shop-aggregates/catalog/src/CatalogPlugin.res` (wire Task)
- `packages/doc/docs-online-shop/aggregate-based.md` (document new features)

### No rescript.json changes needed
Both packages use `{ "dir": "src", "subdirs": true }` — new subdirectories are automatically picked up.

---

## DCB Comparison

These three features intentionally mirror the DCB online shop plan (`docs/plans/dcb-online-shop-automation-integration.md`):

| Feature | Aggregate Component | DCB Component |
|---|---|---|
| Auto-Ship Order | EventMapper (stateless) | AutomationSlice (stateful TODO list) |
| Import Product | Task (S3 file upload) | InboundTranslationSlice (webhook) |
| Send Email | SideEffectHandler (fire-and-forget) | OutboundTranslationSlice (retry + tracking) |

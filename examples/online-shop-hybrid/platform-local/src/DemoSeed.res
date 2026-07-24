// Seeds the online-shop-hybrid example with a coherent demo dataset by driving
// the example's own GraphQL mutations — no direct store access.
//
// Because it goes through the public command API, this doubles as a smoke test:
// it exercises the DCB append path, both extension points, and the AutoShipOrder
// automation. Keep it in the review scope of any command signature change —
// though a signature change breaks `DemoCommands.res` at compile time first.
//
//   pnpm run serve:reset     # in one shell
//   pnpm run demo-data       # in another
//
// What to seed lives in `DemoData.res`; how commands map onto the API lives in
// `DemoCommands.res`; the transport and reporting come from `ReventlessSeed`.

open ReventlessSeed

let endpoint = Seed.Runner.envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql")
let loginEndpoint = Seed.Runner.envOr(
  "REVENTLESS_LOGIN_ENDPOINT",
  "http://localhost:4000/__inmemory/login",
)

let client = Seed.Client.make(
  ~config={
    endpoint,
    loginEndpoint,
    username: Seed.Runner.envOr("REVENTLESS_DEMO_USER", "admin"),
    password: Seed.Runner.envOr("REVENTLESS_DEMO_PASSWORD", "admin"),
  },
)

// Every queryable view this example exposes. `Unfillable` is not a way to
// silence a gap — it records a view no volume of seed data can reach, with the
// reason, so a zero is never read as a seeding miss.
let views = [
  Seed.Runner.Seeded("Catalog_Categories"),
  Seed.Runner.Seeded("Catalog_Products"),
  Seed.Runner.Seeded("Catalog_ProductDemands"),
  Seed.Runner.Seeded("Catalog_ImportProductAudits"),
  Seed.Runner.Seeded("Ordering_AvailableProducts"),
  Seed.Runner.Seeded("Ordering_Orders"),
  Seed.Runner.Seeded("Ordering_Customers"),
  Seed.Runner.Seeded("Ordering_AutoShipOrderTodos"),
  Seed.Runner.Unfillable(
    "Ordering_SendOrderConfirmationTodos",
    "the SendOrderConfirmation OutboundTranslationSlice never runs on the local platform — " ++
    "no todo rows and no EmailService calls for any OrderPlaced event",
  ),
]

// ── Phases ──────────────────────────────────────────────────────────────────

let seedCategories = async () => {
  await client->Seed.Client.sendAll(
    DemoData.categories->Array.map(c =>
      DemoCommands.addCategory(AddCategory({categoryId: c.id, name: c.name}))
    ),
  )
  Seed.Runner.report(
    `categories: ${(DemoData.categories->Array.length)->Int.toString} added`,
  )
}

let seedProducts = async (products: array<DemoData.product>) => {
  await client->Seed.Client.sendAll(
    products->Array.map(p =>
      DemoCommands.addProduct(
        AddProduct({
          productId: p.id,
          name: p.name,
          description: p.description,
          price: p.price,
          categoryId: p.categoryId,
        }),
      )
    ),
  )
  Seed.Runner.report(`products: ${(products->Array.length)->Int.toString} added`)
}

let seedCatalogEdits = async (products: array<DemoData.product>) => {
  let repriced = DemoData.repricedProducts(products)
  await client->Seed.Client.sendAll(
    repriced->Array.map(p =>
      DemoCommands.changeProductPrice(
        ChangeProductPrice({productId: p.id, price: DemoData.discountedPrice(p)}),
      )
    ),
  )
  let redescribed = DemoData.redescribedProducts(products)
  await client->Seed.Client.sendAll(
    redescribed->Array.map(p =>
      DemoCommands.changeProductDescription(
        ChangeProductDescription({
          productId: p.id,
          description: `${p.description} Updated listing copy.`,
        }),
      )
    ),
  )
  await client->Seed.Client.sendAll([
    DemoCommands.renameCategory(
      RenameCategory({
        categoryId: DemoData.renamedCategoryId,
        name: DemoData.renamedCategoryName,
      }),
    ),
  ])
  let archived = DemoData.categories->Array.filter(c => c.archive)
  await client->Seed.Client.sendAll(
    archived->Array.map(c => DemoCommands.archiveCategory(ArchiveCategory({categoryId: c.id}))),
  )
  Seed.Runner.report(
    `catalog edits: ${(repriced->Array.length)->Int.toString} repriced, ${(redescribed
        ->Array.length)
        ->Int.toString} redescribed, 1 renamed, ${(archived->Array.length)
        ->Int.toString} archived`,
  )
}

let seedSupplierFeed = async () => {
  for i in 0 to DemoData.supplierFeed->Array.length - 1 {
    switch DemoData.supplierFeed->Array.get(i) {
    | Some(row) =>
      await client->Seed.Client.sendInboundTranslation(DemoCommands.importProduct(row))
    | None => ()
    }
  }
  // The import mutation cannot report its own outcome (see
  // `sendInboundTranslation`), so confirm through the audit view instead.
  let audits = await client->Seed.Client.queryAllNodes(
    ~field="Catalog_ImportProductAudits",
    ~selection="status",
  )
  let countWith = status =>
    audits->Array.filter(a => a->Seed.Client.nodeString("status") == Some(status))->Array.length
  let successes = countWith("Success")
  let failures = countWith("Failure")
  if (
    successes != DemoData.expectedImportSuccesses || failures != DemoData.expectedImportFailures
  ) {
    throw(
      Seed.Failed(
        `supplier feed: expected ${DemoData.expectedImportSuccesses->Int.toString} Success / ${DemoData.expectedImportFailures->Int.toString} Failure audit rows, got ${successes->Int.toString}/${failures->Int.toString}`,
      ),
    )
  }
  Seed.Runner.report(
    `supplier feed: ${successes->Int.toString} imported, ${failures->Int.toString} rejected (both shown in the audit view)`,
  )
}

let seedCustomers = async (customers: array<DemoData.customer>) => {
  await client->Seed.Client.sendAll(
    customers->Array.map(c =>
      DemoCommands.customer(~id=c.id, Register({email: c.email, address: c.address}))
    ),
  )
  let moved = DemoData.movedCustomers(customers)
  await client->Seed.Client.sendAll(
    moved->Array.map(c =>
      DemoCommands.customer(~id=c.id, UpdateAddress({address: DemoData.newAddress()}))
    ),
  )
  Seed.Runner.report(
    `customers: ${(customers->Array.length)->Int.toString} registered, ${(moved->Array.length)
        ->Int.toString} moved`,
  )
}

let seedOrders = async (orders: array<DemoData.order>) => {
  for i in 0 to orders->Array.length - 1 {
    switch orders->Array.get(i) {
    | Some(order) =>
      (await client->Seed.Client.send(
        DemoCommands.placeOrder(
          PlaceOrder({
            orderId: order.id,
            customerId: order.customerId,
            productIds: order.productIds,
            shippingMethod: order.shippingMethod,
          }),
        ),
      ))->ignore
      if mod(i + 1, 50) == 0 {
        Seed.Runner.report(
          `orders: ${(i + 1)->Int.toString}/${(orders->Array.length)->Int.toString} placed`,
        )
      }
    | None => ()
    }
  }
  let countMethod = (method: OrderingPlugin.PlaceOrder.shippingMethod) =>
    orders->Array.filter(o => o.shippingMethod == method)->Array.length
  Seed.Runner.report(
    `orders: ${(orders->Array.length)->Int.toString} placed (Standard ${countMethod(
        Standard,
      )->Int.toString}, Express ${countMethod(Express)->Int.toString}, Pickup ${countMethod(
        Pickup,
      )->Int.toString}) — Express placements were auto-shipped on arrival`,
  )
}

let dispatchStandardBatch = async (orders: array<DemoData.order>) => {
  let dispatched = DemoData.batchDispatched(orders)
  await client->Seed.Client.sendAll(
    dispatched->Array.map(o => DemoCommands.shipOrder(ShipOrder({orderId: o.id}))),
  )
  let standardTotal = orders->Array.filter(o => o.shippingMethod == Standard)->Array.length
  Seed.Runner.report(
    `batch dispatch: ${(dispatched->Array.length)
        ->Int.toString}/${standardTotal->Int.toString} Standard orders shipped, ${(standardTotal -
      dispatched->Array.length)->Int.toString} left pending`,
  )
  dispatched->Array.map(o => o.id)
}

let seedCancellations = async (orders: array<DemoData.order>, ~dispatched: array<string>) => {
  let cancellable = DemoData.cancellable(orders, ~dispatched)
  let targets = DemoData.cancelled(cancellable)
  await client->Seed.Client.sendAll(
    targets->Array.map(o => DemoCommands.cancelOrder(CancelOrder({orderId: o.id}))),
  )
  Seed.Runner.report(
    `cancellations: ${(targets->Array.length)->Int.toString} of ${(cancellable->Array.length)
        ->Int.toString} cancellable orders cancelled`,
  )
}

let seedDeactivations = async (customers: array<DemoData.customer>) => {
  let targets = DemoData.deactivatedCustomers(customers)
  await client->Seed.Client.sendAll(
    targets->Array.map(c => DemoCommands.customer(~id=c.id, Deactivate)),
  )
  Seed.Runner.report(`customers: ${(targets->Array.length)->Int.toString} deactivated`)
}

// ── Summary ─────────────────────────────────────────────────────────────────

let summarise = async (~counts: dict<int>) => {
  let orders = await client->Seed.Client.queryAllNodes(
    ~field="Ordering_Orders",
    ~selection="status shippingMethod",
  )
  let statuses = ["Placed", "Shipped", "Cancelled"]
  let methods = ["Standard", "Express", "Pickup"]
  let countCell = (status, method) =>
    orders
    ->Array.filter(o =>
      o->Seed.Client.nodeString("status") == Some(status) &&
        o->Seed.Client.nodeString("shippingMethod") == Some(method)
    )
    ->Array.length
  let countStatus = status =>
    orders->Array.filter(o => o->Seed.Client.nodeString("status") == Some(status))->Array.length

  let demand = await client->Seed.Client.queryAllNodes(
    ~field="Catalog_ProductDemands",
    ~selection="name orderCount",
  )
  let orderCountOf = node =>
    switch node->Seed.Client.field("orderCount") {
    | Some(Number(n)) => n->Int.fromFloat
    | _ => 0
    }
  let ranked = demand->Array.toSorted((a, b) => Int.compare(orderCountOf(b), orderCountOf(a)))
  let withDemand = ranked->Array.filter(n => orderCountOf(n) > 0)
  let head =
    ranked
    ->Array.slice(~start=0, ~end=3)
    ->Array.map(n =>
      `${n->Seed.Client.nodeString("name")->Option.getOr("?")} (${orderCountOf(n)->Int.toString})`
    )
    ->Array.join(", ")

  Seed.Runner.heading("Seeded:")
  Console.log(
    `  order status:  ${statuses
      ->Array.map(s => `${s} ${countStatus(s)->Int.toString}`)
      ->Array.join(", ")}`,
  )
  Console.log(`  demand head:   ${head}`)
  Console.log(
    `  demand spread: ${(withDemand->Array.length)->Int.toString}/${(ranked->Array.length)
        ->Int.toString} products ordered, tail min ${withDemand
      ->Array.last
      ->Option.mapOr(0, orderCountOf)
      ->Int.toString}`,
  )

  Console.log("")
  Console.log("  status × shippingMethod:")
  Console.log(
    `    ${" "->String.padEnd(10, " ")}${methods
      ->Array.map(m => m->String.padStart(10, " "))
      ->Array.join("")}`,
  )
  statuses->Array.forEach(status =>
    Console.log(
      `    ${status->String.padEnd(10, " ")}${methods
        ->Array.map(m => countCell(status, m)->Int.toString->String.padStart(10, " "))
        ->Array.join("")}`,
    )
  )

  let observedStatuses = statuses->Array.filter(s => countStatus(s) > 0)
  let spreadWarning = if observedStatuses->Array.length < 3 {
    [
      `the board shows only ${(observedStatuses->Array.length)
          ->Int.toString} of the 3 order statuses (${observedStatuses->Array.join(
          ", ",
        )}) — the shipping-method mix or the batch-dispatch share needs adjusting.`,
    ]
  } else {
    []
  }
  Seed.Runner.warn(
    Array.concat(spreadWarning, Seed.Runner.unfillableWarnings(~views, ~counts)),
  )
}

// ── Run ─────────────────────────────────────────────────────────────────────

let main = async () => {
  Console.log(`Seeding demo data via ${endpoint}`)
  await client->Seed.Client.login

  let products = DemoData.buildProducts()
  let customers = DemoData.buildCustomers()
  let orders = DemoData.buildOrders(products, customers)

  await seedCategories()
  await seedProducts(products)
  await seedCatalogEdits(products)
  await seedSupplierFeed()
  await seedCustomers(customers)

  // Products reach Ordering asynchronously through the Products extension
  // point; PlaceOrder rejects until the shadow copy lands.
  let expected = Array.concat(products->Array.map(p => p.id), DemoData.importedSkus)
  let available = await client->Seed.Client.waitForIds(
    ~field="Ordering_AvailableProductsByIds",
    ~ids=expected,
  )
  Seed.Runner.report(`ordering: ${available->Int.toString} products available`)

  await seedOrders(orders)
  let dispatched = await dispatchStandardBatch(orders)
  await seedCancellations(orders, ~dispatched)
  await seedDeactivations(customers)

  let counts = await Seed.Runner.verifyViews(client, ~views)
  await summarise(~counts)
}

Seed.Runner.run(main)->ignore

// The online-shop-hybrid demo data set(s), exported as `Seed.dataSet` values.
//
// This is the shareable artifact: `dataSets` carries everything domain-specific
// — the phases, the view verification, and the summary board — behind the
// generic `Seed.dataSet` shape, so any platform script (this example's
// `platform-local`/`platform-aws`, or a downstream consumer) seeds it with just
// `Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=…)`.
//
// Because every phase drives the public GraphQL command API, a run doubles as a
// smoke test: it exercises the DCB append path, both extension points, and the
// AutoShipOrder automation. `DemoData.res` holds *what* to seed; `DemoCommands.res`
// maps command values onto mutations; the transport and reporting come from
// `ReventlessSeed`.

open ReventlessSeed

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
  Seed.Runner.Seeded("Ordering_SendOrderConfirmationTodos"),
]

// The fresh-store guard probes these before sending any command — the `Seeded`
// view names, so the pre-flight refusal stays in lockstep with `verifyViews`.
// `Catalog_Categories` leads, so a populated store aborts after one query.
let probeViews =
  views->Array.filterMap(v =>
    switch v {
    | Seed.Runner.Seeded(name) => Some(name)
    | Seed.Runner.Unfillable(_, _) => None
    }
  )

// ── Phases ──────────────────────────────────────────────────────────────────

let seedCategories = async (~client: Seed.Client.t) => {
  await client->Seed.Client.sendAll(
    DemoData.categories->Array.map(c =>
      DemoCommands.addCategory(AddCategory({categoryId: c.id, name: c.name}))
    ),
  )
  Seed.Runner.report(`categories: ${(DemoData.categories->Array.length)->Int.toString} added`)
}

// Upload each product's deterministic placeholder SVG through the deployment's
// upload endpoint and swap `imageUrl` for the returned served `/{prefix}/{key}`
// ref, so the demo image travels the real upload → store → serve loop (local
// dev store or AWS bucket) exactly like a user upload — no external image URL.
let uploadProductImages = async (
  products: array<DemoData.product>,
  ~client: Seed.Client.t,
  ~uploadEndpoint: string,
): array<DemoData.product> => {
  let out = []
  for i in 0 to products->Array.length - 1 {
    switch products->Array.get(i) {
    | Some(p) =>
      let svg = DemoData.productSvg(~name=p.name, ~index=i)
      switch await Seed.Upload.uploadAsset(
        ~uploadEndpoint,
        ~bytes=svg,
        ~fileName=`${p.id}.svg`,
        ~contentType="image/svg+xml",
        ~authToken=?Seed.Client.currentToken(client),
      ) {
      | Ok(servedRef) => out->Array.push({...p, imageUrl: servedRef})
      | Error(msg) => throw(Seed.Failed(`product image upload for ${p.id} failed: ${msg}`))
      }
    | None => ()
    }
  }
  Seed.Runner.report(
    `product images: ${(out->Array.length)->Int.toString} uploaded to the served bucket`,
  )
  out
}

let seedProducts = async (products: array<DemoData.product>, ~client: Seed.Client.t) => {
  await client->Seed.Client.sendAll(
    products->Array.map(p =>
      DemoCommands.addProduct(
        AddProduct({
          productId: p.id,
          name: p.name,
          description: p.description,
          price: p.price,
          imageUrl: p.imageUrl,
          categoryId: p.categoryId,
        }),
      )
    ),
  )
  Seed.Runner.report(`products: ${(products->Array.length)->Int.toString} added`)
}

let seedCatalogEdits = async (products: array<DemoData.product>, ~client: Seed.Client.t) => {
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

let seedSupplierFeed = async (~client: Seed.Client.t) => {
  for i in 0 to DemoData.supplierFeed->Array.length - 1 {
    switch DemoData.supplierFeed->Array.get(i) {
    | Some(row) =>
      // One feed row is deliberately invalid, so a translation rejection is an
      // expected outcome here rather than a seeding failure.
      (
        await client->Seed.Client.send(
          DemoCommands.importProduct(row),
          ~tolerate=["TranslationFailed"],
        )
      )->ignore
    | None => ()
    }
  }
  // Cross-check the per-request outcomes against the slice's audit view. The
  // slice writes an audit row as it receives each feed row, but we read it back
  // over a separate, eventually-consistent query — so poll until the expected
  // tally appears rather than asserting on a single immediate read (which would
  // race the projection and spuriously report 0/0). Same pattern as the id waits
  // above.
  let countWith = (audits, status) =>
    audits->Array.filter(a => a->Seed.Client.nodeString("status") == Some(status))->Array.length
  let expectedSuccesses = DemoData.expectedImportSuccesses
  let expectedFailures = DemoData.expectedImportFailures
  let expected = `${expectedSuccesses->Int.toString} Success / ${expectedFailures->Int.toString} Failure`
  let audits = await client->Seed.Client.queryAllNodesUntil(
    ~field="Catalog_ImportProductAudits",
    ~selection="status",
    ~satisfied=audits =>
      audits->countWith("Success") == expectedSuccesses &&
        audits->countWith("Failure") == expectedFailures,
    ~onTimeout=audits => {
      let successes = audits->countWith("Success")
      let failures = audits->countWith("Failure")
      let total = audits->Array.length
      total == 0
        ? `supplier feed: the import audit view (Catalog_ImportProductAudits) never became non-empty. All ${(DemoData.supplierFeed
            ->Array.length)
            ->Int.toString} import commands were accepted by the API, yet no audit rows appeared — the ImportProduct slice is not persisting its audit log (or it is not queryable through this view). Expected ${expected}.`
        : `supplier feed: the audit view settled on ${successes->Int.toString} Success / ${failures->Int.toString} Failure (${total->Int.toString} rows), expected ${expected} — the feed produced a different set of outcomes than the seed data describes.`
    },
  )
  let successes = audits->countWith("Success")
  let failures = audits->countWith("Failure")
  Seed.Runner.report(
    `supplier feed: ${successes->Int.toString} imported, ${failures->Int.toString} rejected (both shown in the audit view)`,
  )
}

let seedCustomers = async (customers: array<DemoData.customer>, ~client: Seed.Client.t) => {
  await client->Seed.Client.sendAll(
    customers->Array.map(c =>
      DemoCommands.customer(~id=c.id, Register({email: c.email, address: c.address}))
    ),
  )
  // Give every customer a map coordinate so the Customers map view renders a
  // pin per row. The geo-point payload is a `{lat, lng}` input object.
  await client->Seed.Client.sendAll(
    customers->Array.map(c =>
      DemoCommands.customer(~id=c.id, SetLocation({location: {lat: c.lat, lng: c.lng}}))
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

let seedOrders = async (orders: array<DemoData.order>, ~client: Seed.Client.t) => {
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

let dispatchStandardBatch = async (orders: array<DemoData.order>, ~client: Seed.Client.t) => {
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

let seedCancellations = async (
  orders: array<DemoData.order>,
  ~client: Seed.Client.t,
  ~dispatched: array<string>,
) => {
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

let seedDeactivations = async (customers: array<DemoData.customer>, ~client: Seed.Client.t) => {
  let targets = DemoData.deactivatedCustomers(customers)
  await client->Seed.Client.sendAll(
    targets->Array.map(c => DemoCommands.customer(~id=c.id, Deactivate)),
  )
  Seed.Runner.report(`customers: ${(targets->Array.length)->Int.toString} deactivated`)
}

// ── Summary ─────────────────────────────────────────────────────────────────

let summarise = async (~client: Seed.Client.t, ~counts: dict<int>) => {
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
  Seed.Runner.warn(Array.concat(spreadWarning, Seed.Runner.unfillableWarnings(~views, ~counts)))
}

// ── Run ─────────────────────────────────────────────────────────────────────

// The shared seed run, parameterized only by volume so every data set walks the
// same phases. Uploads no-op when the connection carries no upload endpoint
// (a deployment that serves none), keeping `imageUrl` empty rather than failing.
let run = async (
  connection: Seed.connection,
  ~productCount: int,
  ~customerCount: int,
  ~orderCount: int,
): unit => {
  let client = connection.client

  let built = DemoData.buildProducts(~count=productCount, ())
  let products = if connection.uploadEndpoint == "" {
    Seed.Runner.report(
      "product images: skipped (no upload endpoint / SEED_SKIP_UPLOADS) — imageUrl left empty",
    )
    built
  } else {
    await uploadProductImages(built, ~client, ~uploadEndpoint=connection.uploadEndpoint)
  }
  let customers = DemoData.buildCustomers(~count=customerCount, ())
  let orders = DemoData.buildOrders(products, customers, ~count=orderCount, ())

  await seedCategories(~client)
  await seedProducts(products, ~client)
  await seedCatalogEdits(products, ~client)
  await seedSupplierFeed(~client)
  await seedCustomers(customers, ~client)

  // Products reach Ordering asynchronously through the Products extension
  // point; PlaceOrder rejects until the shadow copy lands.
  let expected = Array.concat(products->Array.map(p => p.id), DemoData.importedSkus)
  let available = await client->Seed.Client.waitForIds(
    ~field="Ordering_AvailableProductsByIds",
    ~ids=expected,
  )
  Seed.Runner.report(`ordering: ${available->Int.toString} products available`)

  await seedOrders(orders, ~client)
  let dispatched = await dispatchStandardBatch(orders, ~client)
  await seedCancellations(orders, ~client, ~dispatched)
  await seedDeactivations(customers, ~client)

  let counts = await Seed.Runner.verifyViews(client, ~views)
  await summarise(~client, ~counts)
}

// Two sets, so `Seed.Runner.seed` presents a selection: the full demo, and a
// compact sample for a quick end-to-end check. Both walk identical phases.
let dataSets: array<Seed.dataSet> = [
  {
    name: "full",
    label: `full — ${DemoData.productCount->Int.toString} products, ${DemoData.customerCount->Int.toString} customers, ${DemoData.orderCount->Int.toString} orders`,
    seed: connection =>
      run(
        connection,
        ~productCount=DemoData.productCount,
        ~customerCount=DemoData.customerCount,
        ~orderCount=DemoData.orderCount,
      ),
    probeViews,
  },
  {
    name: "sample",
    label: "sample — 16 products, 8 customers, 40 orders",
    seed: connection => run(connection, ~productCount=16, ~customerCount=8, ~orderCount=40),
    probeViews,
  },
]

// The online-shop-hybrid demo data set(s), exported as `Seed.dataSet` values.
//
// This is the shareable artifact: `dataSets` carries everything domain-specific
// — the phases, the view verification, and the summary board — behind the
// generic `Seed.dataSet` shape, so any platform script (this example's
// `platform-local`/`platform-aws`, or a downstream consumer) seeds it with just
// `Seed.Runner.seed(~sets=HybridSeedData.dataSets, ~connect=…)`.
//
// Because every phase drives the public GraphQL command API, a run doubles as a
// smoke test: it exercises the DCB append path, a deliberate command rejection,
// both extension points, and the AutoShipOrder automation. `DemoData.res` holds
// *what* to seed; `DemoCommands.res`
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

let seedCategories = async (categories: array<DemoData.category>, ~client: Seed.Client.t) => {
  await client->Seed.Client.sendAll(
    categories->Array.map(c =>
      DemoCommands.addCategory(
        AddCategory({categoryId: c.id, name: c.name, imageUrl: ?c.imageUrl}),
      )
    ),
  )
  Seed.Runner.report(`categories: ${(categories->Array.length)->Int.toString} added`)
}

// The store a product image lives in: the qualified `{plugin}.{store}` the
// catalog plugin's `@storageRef("productImages")` declares, and the key the
// platform publishes that store's presign endpoint under. Naming it is what lets
// a deployment serving several stores put the image in the right one — a
// resolver that just took "the" upload endpoint would upload into whichever
// store came first, with a 2xx and a plausible-looking ref.
let productImageStore = "Catalog.productImages"

// The categories' own store. A separate store rather than a shared "images" one:
// the two asset kinds are wiped, permissioned and prefixed independently, and a
// store whose name describes half its contents is the kind of thing nobody
// renames once refs are in an append-only log.
let categoryImageStore = "Catalog.categoryImages"

// Upload each product's deterministic placeholder SVG through the store's
// upload endpoint and swap `imageUrl` for the returned served `/{prefix}/{key}`
// ref, so the demo image travels the real upload → store → serve loop (local
// dev store or AWS bucket) exactly like a user upload — no external image URL.
let uploadProductImages = async (
  products: array<DemoData.product>,
  ~client: Seed.Client.t,
  ~store: string,
): array<DemoData.product> => {
  let out = []
  for i in 0 to products->Array.length - 1 {
    switch products->Array.get(i) {
    | Some(p) =>
      let svg = DemoData.productSvg(~name=p.name, ~index=i)
      switch await Seed.Upload.uploadAsset(
        ~client,
        ~store,
        ~bytes=svg,
        ~fileName=`${p.id}.svg`,
        ~contentType="image/svg+xml",
      ) {
      | Ok(servedRef) => out->Array.push({...p, imageUrl: Some(servedRef)})
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

// The category counterpart of `uploadProductImages`, and the same reason for
// existing: the demo image travels the real upload → store → serve loop rather
// than arriving as an external URL.
let uploadCategoryImages = async (
  categories: array<DemoData.category>,
  ~client: Seed.Client.t,
  ~store: string,
): array<DemoData.category> => {
  let out = []
  for i in 0 to categories->Array.length - 1 {
    switch categories->Array.get(i) {
    | Some(c) =>
      let svg = DemoData.categorySvg(~name=c.name, ~index=i)
      switch await Seed.Upload.uploadAsset(
        ~client,
        ~store,
        ~bytes=svg,
        ~fileName=`${c.id}.svg`,
        ~contentType="image/svg+xml",
      ) {
      | Ok(servedRef) => out->Array.push({...c, imageUrl: Some(servedRef)})
      | Error(msg) => throw(Seed.Failed(`category image upload for ${c.id} failed: ${msg}`))
      }
    | None => ()
    }
  }
  Seed.Runner.report(
    `category images: ${(out->Array.length)->Int.toString} uploaded to the served bucket`,
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
          imageUrl: ?p.imageUrl,
          categoryId: p.categoryId,
        }),
      )
    ),
  )
  Seed.Runner.report(`products: ${(products->Array.length)->Int.toString} added`)
}

// One command the domain must refuse, sent on purpose: re-adding a productId
// that already exists. It comes back as CommandRejected/ProductAlreadyExists and
// appends nothing, so the run shows the rejection path next to the accepted
// ones. Acceptance is the failure mode here — a duplicate that slipped through
// would leave two ProductAdded events on the same id — so an accepted duplicate
// aborts the seed instead of passing quietly.
let seedRejectedDuplicate = async (products: array<DemoData.product>, ~client: Seed.Client.t) =>
  switch products->Array.get(0) {
  | Some(p) =>
    let outcome = await client->Seed.Client.send(
      DemoCommands.addProduct(
        AddProduct({
          productId: p.id,
          name: p.name,
          description: p.description,
          price: p.price,
          imageUrl: ?p.imageUrl,
          categoryId: p.categoryId,
        }),
      ),
      ~tolerate=["ProductAlreadyExists"],
    )
    switch outcome {
    | Some(code) =>
      Seed.Runner.report(`duplicate guard: re-adding ${p.id} was rejected with ${code} (expected)`)
    | None =>
      throw(
        Seed.Failed(
          `duplicate guard: re-adding product ${p.id} was accepted — AddProduct is no longer ` ++
          `rejecting an existing productId with ProductAlreadyExists`,
        ),
      )
    }
  | None => ()
  }

let seedCatalogEdits = async (
  products: array<DemoData.product>,
  categories: array<DemoData.category>,
  ~client: Seed.Client.t,
  // (categoryId, a freshly uploaded ref) for the one category that gets its
  // image replaced. Empty when uploads are off.
  ~reimage: array<(string, string)>,
) => {
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
  // Re-image one live category, so the change path is exercised next to the
  // rename. The ref must differ from the one AddCategory carried — changing to
  // the same ref is the idempotent arm and appends nothing, which would leave
  // this phase reporting work it did not do.
  await client->Seed.Client.sendAll(
    reimage->Array.map(((categoryId, imageUrl)) =>
      DemoCommands.changeCategoryImage(ChangeCategoryImage({categoryId, imageUrl}))
    ),
  )

  let archived = categories->Array.filter(c => c.archive)
  await client->Seed.Client.sendAll(
    archived->Array.map(c => DemoCommands.archiveCategory(ArchiveCategory({categoryId: c.id}))),
  )
  Seed.Runner.report(
    `catalog edits: ${(repriced->Array.length)->Int.toString} repriced, ${(redescribed
        ->Array.length)
        ->Int.toString} redescribed, 1 renamed, ${(reimage->Array.length)
        ->Int.toString} re-imaged, ${(archived->Array.length)
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
  // pin per row. The seed is a client that already knows both halves, so it
  // sends them together — which is also what keeps the geocoding slice from
  // spending a request per seeded customer on addresses it was handed.
  await client->Seed.Client.sendAll(
    customers->Array.map(c =>
      DemoCommands.customer(
        ~id=c.id,
        SetAddressLocation({address: c.address, location: {lat: c.lat, lng: c.lng}}),
      )
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
            deliveryWindow: ?order.deliveryWindow,
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

// The two ways a product leaves the shelf, run late for the reason the archived
// category is archived late: withdrawn before anything points at it, a product
// demonstrates nothing. Withdrawn after the orders exist, it shows an order still
// resolving a product the catalog no longer offers — which is the case the whole
// feature is for — and it shows the withdrawal crossing the extension point into
// Ordering, where the shopper's `AvailableProducts` drops the row.
let seedProductRetirements = async (products: array<DemoData.product>, ~client: Seed.Client.t) => {
  let archived = DemoData.archivedProducts(products)
  await client->Seed.Client.sendAll(
    archived->Array.map(p => DemoCommands.archiveProduct(ArchiveProduct({productId: p.id}))),
  )
  let discontinued = DemoData.discontinuedProducts(products)
  await client->Seed.Client.sendAll(
    discontinued->Array.map(p =>
      DemoCommands.discontinueProduct(DiscontinueProduct({productId: p.id}))
    ),
  )
  Seed.Runner.report(
    `catalog retirements: ${(archived->Array.length)->Int.toString} archived, ${(discontinued
        ->Array.length)
        ->Int.toString} discontinued`,
  )
}

// ── Summary ─────────────────────────────────────────────────────────────────

let summarise = async (~client: Seed.Client.t, ~counts: dict<int>) => {
  // `lifecycle`, not `status`: the Orders view names its lifecycle field by the
  // convention rather than annotating it. The audit view above still reads
  // `status`, because a framework-generated row's field name is a published wire
  // name and stays as it is.
  let orders = await client->Seed.Client.queryAllNodes(
    ~field="Ordering_Orders",
    ~selection="lifecycle shippingMethod",
  )
  let lifecycles = ["Placed", "Shipped", "Cancelled"]
  let methods = ["Standard", "Express", "Pickup"]
  let countCell = (lifecycle, method) =>
    orders
    ->Array.filter(o =>
      o->Seed.Client.nodeString("lifecycle") == Some(lifecycle) &&
        o->Seed.Client.nodeString("shippingMethod") == Some(method)
    )
    ->Array.length
  let countLifecycle = lifecycle =>
    orders
    ->Array.filter(o => o->Seed.Client.nodeString("lifecycle") == Some(lifecycle))
    ->Array.length

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

  // The retirements, read back and counted by state. This query runs as the seed's
  // own caller — `admin`, which the deployment lists as elevated — so it returns
  // retired rows and the view counts above do NOT drop. That is correct behaviour
  // and reads exactly like a bug, so it is stated rather than left to be
  // rediscovered. The line below is what an elevated caller sees; a scoped one
  // sees neither of these rows.
  let shelved = await client->Seed.Client.queryAllNodes(
    ~field="Catalog_Products",
    ~selection="name shelfStatus",
  )
  let countShelf = state =>
    shelved
    ->Array.filter(p => p->Seed.Client.nodeString("shelfStatus") == Some(state))
    ->Array.length

  Seed.Runner.heading("Seeded:")
  Console.log(
    `  order lifecycle: ${lifecycles
      ->Array.map(s => `${s} ${countLifecycle(s)->Int.toString}`)
      ->Array.join(", ")}`,
  )
  Console.log(
    `  product shelf:   ${["Listed", "Archived", "Discontinued"]
      ->Array.map(s => `${s} ${countShelf(s)->Int.toString}`)
      ->Array.join(", ")} (elevated view — a scoped caller sees only the Listed ones)`,
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
  Console.log("  lifecycle × shippingMethod:")
  Console.log(
    `    ${" "->String.padEnd(10, " ")}${methods
      ->Array.map(m => m->String.padStart(10, " "))
      ->Array.join("")}`,
  )
  lifecycles->Array.forEach(lifecycle =>
    Console.log(
      `    ${lifecycle->String.padEnd(10, " ")}${methods
        ->Array.map(m => countCell(lifecycle, m)->Int.toString->String.padStart(10, " "))
        ->Array.join("")}`,
    )
  )

  let observedLifecycles = lifecycles->Array.filter(s => countLifecycle(s) > 0)
  let spreadWarning = if observedLifecycles->Array.length < 3 {
    [
      `the board shows only ${(observedLifecycles->Array.length)
          ->Int.toString} of the 3 order lifecycle states (${observedLifecycles->Array.join(
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
// same phases. Uploads no-op when `SEED_SKIP_UPLOADS` is set, keeping `imageUrl`
// empty rather than failing.
let run = async (
  connection: Seed.connection,
  ~productCount: int,
  ~customerCount: int,
  ~orderCount: int,
): unit => {
  let client = connection.client

  let built = DemoData.buildProducts(~count=productCount, ())
  let products = switch connection.uploadsSkipped {
  | false => await uploadProductImages(built, ~client, ~store=productImageStore)
  | true =>
    Seed.Runner.report(`product images: skipped (SEED_SKIP_UPLOADS) — imageUrl left absent`)
    built
  }
  let categories = switch connection.uploadsSkipped {
  | false => await uploadCategoryImages(DemoData.categories, ~client, ~store=categoryImageStore)
  | true =>
    Seed.Runner.report(`category images: skipped (SEED_SKIP_UPLOADS) — imageUrl left absent`)
    DemoData.categories
  }
  // A second, visibly different image for one live category, so the edit phase
  // has a ref to change *to*. Uploaded here rather than in the edit phase
  // because this is where the store and the skip flag already are.
  let reimage = switch (
    connection.uploadsSkipped,
    categories->Array.filter(c => !c.archive)->Array.get(2),
  ) {
  | (false, Some(c)) =>
    switch await Seed.Upload.uploadAsset(
      ~client,
      ~store=categoryImageStore,
      ~bytes=DemoData.categorySvg(~name=`${c.name} (updated)`, ~index=101),
      ~fileName=`${c.id}-v2.svg`,
      ~contentType="image/svg+xml",
    ) {
    | Ok(servedRef) => [(c.id, servedRef)]
    | Error(msg) => throw(Seed.Failed(`category re-image upload for ${c.id} failed: ${msg}`))
    }
  | _ => []
  }
  let generatedCustomers = DemoData.buildCustomers(~count=customerCount, ())
  // The demo logins are registered as customers but are deliberately NOT part of
  // the weighted draw below: their order counts are fixed by index, and letting
  // them also be sampled would make those counts approximate again.
  let customers = generatedCustomers->Array.concat(DemoData.demoCustomers)
  let orders = DemoData.buildOrders(products, generatedCustomers, ~count=orderCount, ())

  await seedCategories(categories, ~client)
  await seedProducts(products, ~client)
  await seedRejectedDuplicate(products, ~client)
  await seedCatalogEdits(products, categories, ~client, ~reimage)
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
  await seedProductRetirements(products, ~client)

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

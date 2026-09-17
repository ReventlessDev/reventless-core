// A follow-up run: one day of activity added to a shop a first run filled.
//
// Everything here is decided from what the shop holds now (`ShopSnapshot`) and
// the run date, and nothing is sent — `HybridSeedData.runFollowUp` sends it. The
// run date and the run's number on that date name its ids and seed its random
// generator, so every run differs and a given run repeats itself.

open ReventlessSeed

type t = {
  runDate: string,
  // 1 for the day's first follow-up, then counting up.
  run: int,
  newProducts: array<DemoData.product>,
  repriced: array<(string, Reventless.Money.t)>,
  redescribed: array<(string, string)>,
  newCustomers: array<DemoData.customer>,
  moved: array<(string, string)>,
  orders: array<DemoData.order>,
  shipping: array<string>,
  cancelled: array<string>,
  deactivated: array<string>,
  archived: array<string>,
  discontinued: array<string>,
}

/** `2026-09-24` for any instant on that UTC day. */
let runDateOf = (today: float): string =>
  Date.fromTime(today)->Date.toISOString->String.slice(~start=0, ~end=10)

/** The run as it appears in ids: `20260924` for the day's first run, which keeps
    the format ids had before runs were numbered, then `20260924-r2`, `20260924-r3`. */
let idTag = (runDate: string, ~run: int): string => {
  let date = runDate->String.replaceAll("-", "")
  run == 1 ? date : `${date}-r${run->Int.toString}`
}

let orderIdPrefix = (runDate: string, ~run: int) => `ord-${idTag(runDate, ~run)}-`

let randomFor = (runDate: string, ~run: int): Seed.Random.t =>
  Seed.Random.make(
    ~seed=Int.fromString(runDate->String.replaceAll("-", ""))
    ->Option.getOr(0)
    ->Int.bitwiseXor(0x5eed)
    ->Int.bitwiseXor((run - 1) * 0x10001),
  )

// The run number an id belongs to, when it was made by a follow-up on `runDate`:
// `prd-20260924-01` is run 1, `prd-20260924-r2-01` run 2.
let runOfId = (id: string, ~runDate: string): option<int> => {
  let date = runDate->String.replaceAll("-", "")
  ["prd", "cust", "ord"]->Array.findMap(kind => {
    let prefix = `${kind}-${date}-`
    if id->String.startsWith(prefix) {
      let rest = id->String.slice(~start=String.length(prefix))
      switch rest->String.startsWith("r") {
      | false => Some(1)
      | true =>
        rest
        ->String.slice(~start=1, ~end=rest->String.indexOf("-"))
        ->Int.fromString
      }
    } else {
      None
    }
  })
}

/** The number the next follow-up on `runDate` takes: one past the highest run
    whose ids are in the shop. Products and customers count as well as orders, so
    a run that stopped before placing its orders does not hand its number on. */
let nextRun = (snapshot: ShopSnapshot.t, ~runDate: string): int => {
  let ids = Array.concat(
    snapshot.products->Array.map(p => p.id),
    Array.concat(snapshot.customers->Array.map(c => c.id), snapshot.orders->Array.map(o => o.id)),
  )
  ids->Array.filterMap(id => runOfId(id, ~runDate))->Array.reduce(0, (a, b) => a > b ? a : b) + 1
}

/** A share of what exists, never below `min`. */
let sizeOf = (existing: int, ~share: float, ~min: int): int => {
  let n = Math.round(Int.toFloat(existing) *. share)->Int.fromFloat
  n < min ? min : n
}

let sample = (random, xs: array<'a>, ~count: int): array<'a> =>
  Seed.Random.sampleWeighted(random, xs->Array.map(x => (x, 1.0)), ~count)

// A description without the note a previous follow-up appended, so repeated
// runs replace the note rather than stacking them.
let refreshed = (description: string, ~runDate: string): string => {
  let base = switch description->String.indexOf(" Listing refreshed on ") {
  | -1 => description
  | at => description->String.slice(~start=0, ~end=at)
  }
  `${base} Listing refreshed on ${runDate}.`
}

let priceFactors = [0.85, 0.9, 1.1, 1.2]

let plan = (snapshot: ShopSnapshot.t, ~today: float, ~demoCustomerIds: array<string>): t => {
  let runDate = runDateOf(today)
  let run = nextRun(snapshot, ~runDate)
  let tag = idTag(runDate, ~run)
  let random = randomFor(runDate, ~run)

  let listed = snapshot.products->Array.filter(p => p.listed)
  let listedCategories =
    DemoData.categories->Array.filter(c =>
      snapshot.categories->Array.some(s => s.id == c.id && s.listed)
    )
  // The demo accounts' order counts are what a first run checks, so a follow-up
  // places no orders for them and neither moves nor deactivates them.
  let customers =
    snapshot.customers->Array.filter(c => c.active && !(demoCustomerIds->Array.includes(c.id)))

  let newProductCount = {
    let roll = Seed.Random.float(random)
    roll < 0.5 ? 0 : roll < 0.85 ? 1 : 2
  }
  let newProducts =
    Array.fromInitializer(~length=newProductCount, i =>
      Seed.Random.pick(random, listedCategories)->Option.map(category =>
        DemoData.makeProduct(~random, ~id=`prd-${tag}-${DemoData.pad(i + 1, 2)}`, ~category)
      )
    )->Array.filterMap(p => p)

  let repriced =
    sample(random, listed, ~count=Seed.Random.int(random, ~min=2, ~max=4))->Array.map(p => (
      p.id,
      DemoData.scaledPrice(p.price, ~by=Seed.Random.pickOr(random, ~fallback=1.1, priceFactors)),
    ))
  let redescribed =
    sample(random, listed, ~count=Seed.Random.int(random, ~min=2, ~max=4))->Array.map(p => (
      p.id,
      refreshed(p.description, ~runDate),
    ))

  let newCustomers = DemoData.buildCustomers(
    ~random,
    ~count=sizeOf(snapshot.customers->Array.length, ~share=0.05, ~min=1),
    ~idPrefix=`cust-${tag}-`,
    ~nameOffset=snapshot.customers->Array.length,
    ~emailTag=`.${tag}`,
    (),
  )
  let moved =
    sample(random, customers, ~count=Seed.Random.int(random, ~min=1, ~max=3))->Array.map(c => (
      c.id,
      DemoData.newAddress(~random),
    ))

  // One currency per order: the supplier feed lists some products in its own
  // currency, and an order mixing two is refused.
  let orderable =
    snapshot.availableProducts
    ->Array.filter(p => p.price.currency == DemoData.currency)
    ->Array.map(p => p.id)
  let orders = DemoData.buildOrders(
    ~random,
    ~productIds=orderable,
    ~customerIds=Array.concat(customers->Array.map(c => c.id), newCustomers->Array.map(c => c.id)),
    ~count=sizeOf(snapshot.orders->Array.length, ~share=0.1, ~min=5),
    ~idPrefix=orderIdPrefix(runDate, ~run),
    ~today,
    (),
  )
  let orders = orderable->Array.length == 0 ? [] : orders

  // Waiting orders from every earlier run, and this run's own, under one rule.
  let placed = Array.concat(
    snapshot.orders
    ->Array.filter(o => o.placed)
    ->Array.map((o): DemoData.placedOrder => {
      id: o.id,
      shippingMethod: o.shippingMethod,
      deliveryWindow: o.deliveryWindow,
    }),
    orders->Array.filter(o => o.shippingMethod != Express)->Array.map(DemoData.placedOf),
  )
  let shipping = DemoData.dueForShipping(placed, ~today)
  let cancelled = DemoData.cancellations(
    placed,
    ~shipping,
    ~max=Seed.Random.int(random, ~min=1, ~max=3),
  )

  let movedIds = moved->Array.map(((id, _)) => id)
  let deactivated =
    Seed.Random.float(random) < 0.4
      ? sample(
          random,
          customers->Array.filter(c => !(movedIds->Array.includes(c.id))),
          ~count=1,
        )->Array.map(c => c.id)
      : []
  let archived =
    Seed.Random.float(random) < 0.3 ? sample(random, listed, ~count=1)->Array.map(p => p.id) : []
  let discontinued =
    Seed.Random.float(random) < 0.15
      ? sample(
          random,
          listed->Array.filter(p => !(archived->Array.includes(p.id))),
          ~count=1,
        )->Array.map(p => p.id)
      : []

  {
    runDate,
    run,
    newProducts,
    repriced,
    redescribed,
    newCustomers,
    moved,
    orders,
    shipping,
    cancelled,
    deactivated,
    archived,
    discontinued,
  }
}

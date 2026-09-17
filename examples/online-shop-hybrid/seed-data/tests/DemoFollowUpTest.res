open JestGlobals

// A small seeded shop, as a follow-up reads it.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)

let product = (i, ~listed=true): ShopSnapshot.product => {
  id: `prd-${DemoData.pad(i, 3)}`,
  categoryId: "cat-01",
  name: `Product ${i->Int.toString}`,
  description: `Product ${i->Int.toString} description.`,
  price: eur(1000.0),
  listed,
}

let customer = (id, ~active=true): ShopSnapshot.customer => {id, active}

let order = (
  i,
  ~customerId="cust-01",
  ~placed=true,
  ~shippingMethod=OrderingPlugin.PlaceOrder.Standard,
): ShopSnapshot.order => {
  id: `ord-${DemoData.pad(i, 3)}`,
  customerId,
  placed,
  shippingMethod,
  deliveryWindow: None,
}

let demoIds = ["local-shopper", "local-admin", "local-merch"]

let snapshot: ShopSnapshot.t = {
  products: Array.concat(
    Array.fromInitializer(~length=10, i => product(i + 1)),
    [product(11, ~listed=false)],
  ),
  categories: DemoData.categories->Array.map(c => {ShopSnapshot.id: c.id, listed: !c.archive}),
  availableProducts: Array.concat(
    Array.fromInitializer(~length=10, i => {
      ShopSnapshot.id: `prd-${DemoData.pad(i + 1, 3)}`,
      price: eur(1000.0),
    }),
    // A supplier-fed product in another currency, which no order may mix in.
    [{id: "SKU-4410", price: Reventless.Money.make(~amount=8990.0, ~currency=USD)}],
  ),
  customers: Array.concat(
    Array.fromInitializer(~length=17, i => customer(`cust-${DemoData.pad(i + 1, 2)}`)),
    [customer("cust-18", ~active=false), ...demoIds->Array.map(id => customer(id))],
  ),
  orders: Array.fromInitializer(~length=40, i =>
    order(i + 1, ~shippingMethod=mod(i, 3) == 0 ? Express : Standard, ~placed=mod(i, 3) != 0)
  ),
}

// 2026-09-24T10:00Z
let today = 1790244000000.0
let plan = DemoFollowUp.plan(snapshot, ~today, ~demoCustomerIds=demoIds)
let ids = xs => xs->Array.map(((id, _)) => id)

describe("DemoFollowUp.plan", () => {
  testSync("names everything it creates by the run date", () => {
    expect((
      (plan.runDate, plan.run),
      plan.orders->Array.every(o => o.id->String.startsWith("ord-20260924-")),
      plan.newCustomers->Array.every(c => c.id->String.startsWith("cust-20260924-")),
      plan.newProducts->Array.every(p => p.id->String.startsWith("prd-20260924-")),
    ))->toEqual((("2026-09-24", 1), true, true, true))
  })

  testSync("repeat itself on the same day and differ on another", () => {
    let again = DemoFollowUp.plan(snapshot, ~today=today +. 3600000.0, ~demoCustomerIds=demoIds)
    let nextDay = DemoFollowUp.plan(
      snapshot,
      ~today=today +. DemoData.dayMs,
      ~demoCustomerIds=demoIds,
    )
    expect((again == plan, nextDay.orders == plan.orders))->toEqual((true, false))
  })

  // 10 % of 40 orders is 4, so the floor of 5 applies; 5 % of 21 customers is 1.
  testSync("size itself from the shop", () => {
    expect((plan.orders->Array.length, plan.newCustomers->Array.length))->toEqual((5, 1))
  })

  testSync("leave the demo accounts and inactive customers alone", () => {
    let untouchable = ["cust-18", ...demoIds]
    let touched = Array.concat(
      plan.orders->Array.map(o => o.customerId),
      Array.concat(ids(plan.moved), plan.deactivated),
    )
    expect(touched->Array.filter(id => untouchable->Array.includes(id)))->toEqual([])
  })

  testSync(
    "order only what Ordering sells in the shop's currency, and change only listed products",
    () => {
      let listed = snapshot.products->Array.filter(p => p.listed)->Array.map(p => p.id)
      let ordered = plan.orders->Array.flatMap(o => o.lineItems->Array.map(line => line.productId))
      let changed = Array.concat(
        Array.concat(ids(plan.repriced), ids(plan.redescribed)),
        Array.concat(plan.archived, plan.discontinued),
      )
      expect((
        ordered->Array.every(id => id->String.startsWith("prd-")),
        changed->Array.every(id => listed->Array.includes(id)),
      ))->toEqual((true, true))
    },
  )

  // Express ships on arrival, so only earlier Standard and Pickup orders, and
  // this run's own, are still waiting.
  testSync("ship and cancel only orders still waiting", () => {
    let waiting = Array.concat(
      snapshot.orders->Array.filter(o => o.placed)->Array.map(o => o.id),
      plan.orders->Array.filter(o => o.shippingMethod != Express)->Array.map(o => o.id),
    )
    expect((
      plan.shipping->Array.every(id => waiting->Array.includes(id)),
      plan.cancelled->Array.every(
        id => waiting->Array.includes(id) && !(plan.shipping->Array.includes(id)),
      ),
      plan.shipping->Array.length > 0,
    ))->toEqual((true, true, true))
  })
})

describe("DemoFollowUp", () => {
  testSync("number the day's runs from the ids already in the shop", () => {
    let withIds = (~orders=[], ~customers=[]) => {
      ...snapshot,
      orders: [...snapshot.orders, ...orders->Array.map(id => {...order(1), ShopSnapshot.id})],
      customers: [...snapshot.customers, ...customers->Array.map(id => customer(id))],
    }
    expect((
      DemoFollowUp.nextRun(snapshot, ~runDate="2026-09-24"),
      DemoFollowUp.nextRun(withIds(~orders=["ord-20260924-001"]), ~runDate="2026-09-24"),
      DemoFollowUp.nextRun(
        withIds(~orders=["ord-20260924-001", "ord-20260924-r2-001"]),
        ~runDate="2026-09-24",
      ),
      // A run that stopped after registering its customers keeps its number.
      DemoFollowUp.nextRun(withIds(~customers=["cust-20260924-r3-01"]), ~runDate="2026-09-24"),
      DemoFollowUp.nextRun(withIds(~orders=["ord-20260924-001"]), ~runDate="2026-09-25"),
    ))->toEqual((1, 2, 3, 4, 1))
  })

  // What the first run of the day placed is in the shop the second one reads.
  testSync("give a second run on the same day its own ids and its own choices", () => {
    let afterFirst = {
      ...snapshot,
      orders: Array.concat(
        snapshot.orders,
        plan.orders->Array.map(
          (o): ShopSnapshot.order => {
            id: o.id,
            customerId: o.customerId,
            placed: o.shippingMethod != Express,
            shippingMethod: o.shippingMethod,
            deliveryWindow: o.deliveryWindow,
          },
        ),
      ),
    }
    let second = DemoFollowUp.plan(afterFirst, ~today, ~demoCustomerIds=demoIds)
    expect((
      second.run,
      second.orders->Array.every(o => o.id->String.startsWith("ord-20260924-r2-")),
      second.newCustomers->Array.every(c => c.id->String.startsWith("cust-20260924-r2-")),
      second.orders->Array.map(o => o.lineItems) == plan.orders->Array.map(o => o.lineItems),
    ))->toEqual((2, true, true, false))
  })

  testSync("replace an earlier listing note rather than stacking it", () => {
    expect(
      "A lamp."
      ->DemoFollowUp.refreshed(~runDate="2026-09-24")
      ->DemoFollowUp.refreshed(~runDate="2026-09-25"),
    )->toBe("A lamp. Listing refreshed on 2026-09-25.")
  })
})

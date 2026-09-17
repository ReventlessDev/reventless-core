open JestGlobals

// The demo owners are found in the accounts file each platform's template starts
// from. On AWS the usernames are addresses, so a lookup by `shopper` alone found
// nobody and every owner-scoped row was seeded under a fallback id.
let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))

let template = platform =>
  NodePath.join([here, "..", "..", platform, "users.example.yaml"])
  ->NodeFs.readFileSync
  ->ReventlessSeed.Seed.Users.parseString

// What `provision-accounts` writes back: the id the pool minted for each account.
let provisioned = (accounts: array<DemoData.account>) =>
  accounts->Array.map(a => {...a, userId: Some(`sub-${a.username}`)})

let resolve = accounts =>
  DemoData.resolveOwners(
    ~accounts,
    ~caller=accounts->Array.getUnsafe(0),
    ~callerId=None,
  )->DemoData.all

// 2026-09-17T06:45Z — mid-morning of the run's day, not its start.
let today = 1789627500000.0
let dayOf = (w: Reventless.DateRange.t) => w.start->String.slice(~start=0, ~end=10)
let distinct = xs => xs->Array.reduce([], (acc, x) => acc->Array.includes(x) ? acc : [...acc, x])

describe("DemoData.deliveryWindowFor", () => {
  let standard = Array.fromInitializer(~length=19, i =>
    DemoData.deliveryWindowFor(i, ~today, ~shippingMethod=Standard)
  )

  testSync("places the first Standard windows on distinct days, three or more ahead", () => {
    expect(standard->Array.slice(~start=0, ~end=3))->toEqual([
      {Reventless.DateRange.start: "2026-09-20T09:00:00.000Z", end_: "2026-09-20T12:00:00.000Z"},
      {start: "2026-09-25T14:00:00.000Z", end_: "2026-09-25T17:00:00.000Z"},
      {start: "2026-09-30T18:00:00.000Z", end_: "2026-09-30T21:00:00.000Z"},
    ])
  })

  // Nineteen orders cover all nineteen days, so no day grid is left holding
  // every bar.
  testSync("spread 19 Standard orders over days 3 to 21", () => {
    let days = standard->Array.map(dayOf)
    expect((
      distinct(days)->Array.length,
      days->Array.every(d => d >= "2026-09-20" && d <= "2026-10-08"),
    ))->toEqual((19, true))
  })

  // Express ships the moment it is placed, so a slot weeks out would describe a
  // parcel sitting on a doorstep for a fortnight.
  testSync("keep Express windows within the next two days", () => {
    let days =
      Array.fromInitializer(
        ~length=6,
        i => DemoData.deliveryWindowFor(i, ~today, ~shippingMethod=Express),
      )->Array.map(dayOf)
    expect(distinct(days)->Array.toSorted(String.compare))->toEqual(["2026-09-18", "2026-09-19"])
  })

  testSync("produce valid date-time instants", () => {
    expect(
      standard->Array.every(
        w =>
          Reventless.DateTime.fromString(w.start)->Result.isOk &&
            Reventless.DateTime.fromString(w.end_)->Result.isOk,
      ),
    )->toBe(true)
  })
})

describe("DemoData.dueForShipping", () => {
  let windowIn = days => Some(
    DemoData.deliveryWindowFor(
      0,
      ~today=today +. Float.fromInt(days - 3) *. DemoData.dayMs,
      ~shippingMethod=Standard,
    ),
  )
  let placed = (id, shippingMethod, deliveryWindow): DemoData.placedOrder => {
    id,
    shippingMethod,
    deliveryWindow,
  }
  let orders = [
    placed("due", Standard, windowIn(3)),
    placed("later", Standard, windowIn(4)),
    placed("open-1", Standard, None),
    placed("open-2", Standard, None),
    placed("open-3", Standard, None),
    placed("pickup", Pickup, None),
    placed("express", Express, windowIn(1)),
  ]

  // A later run applies the same rule, so "later" ships on the next day's run.
  testSync(
    "ship Standard orders whose window opens within three days, and every other unscheduled one",
    () => {
      expect(DemoData.dueForShipping(orders, ~today))->toEqual(["due", "open-1", "open-3"])
    },
  )

  testSync("cancel only what stays Placed and is not shipping, up to the limit", () => {
    let shipping = DemoData.dueForShipping(orders, ~today)
    expect((
      DemoData.cancellations(orders, ~shipping, ~max=5),
      DemoData.cancellations(orders, ~shipping, ~max=0),
    ))->toEqual((["open-2"], []))
  })
})

describe("DemoData.resolveOwners", () => {
  testSync("finds every demo owner in the provisioned AWS template", () => {
    let owners = template("platform-aws")->provisioned->resolve
    expect(owners->Array.map(o => (o.username, o.id, o.source)))->toEqual([
      ("shopper@example.com", "sub-shopper@example.com", DemoData.AccountsFile),
      ("admin@example.com", "sub-admin@example.com", DemoData.AccountsFile),
      ("merch@example.com", "sub-merch@example.com", DemoData.AccountsFile),
    ])
  })

  testSync("still finds every demo owner in the local template", () => {
    let owners = template("platform-local")->resolve
    expect(owners->Array.map(o => (o.username, o.id, o.source)))->toEqual([
      ("shopper", "local-shopper", DemoData.AccountsFile),
      ("admin", "local-admin", DemoData.AccountsFile),
      ("merch", "local-merch", DemoData.AccountsFile),
    ])
  })
})

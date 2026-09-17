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

describe("DemoData.deliveryWindowFor", () => {
  // 2026-09-17T06:45Z — mid-morning of the run's day, not its start.
  let today = 1789627500000.0
  let windows = Array.fromInitializer(~length=21, i => DemoData.deliveryWindowFor(i, ~today))
  let days = windows->Array.map(w => w.start->String.slice(~start=0, ~end=10))

  testSync("places the first windows on distinct days after the run's day", () => {
    expect(windows->Array.slice(~start=0, ~end=3))->toEqual([
      {Reventless.DateRange.start: "2026-09-18T09:00:00.000Z", end_: "2026-09-18T12:00:00.000Z"},
      {start: "2026-09-23T14:00:00.000Z", end_: "2026-09-23T17:00:00.000Z"},
      {start: "2026-09-28T18:00:00.000Z", end_: "2026-09-28T21:00:00.000Z"},
    ])
  })

  // Twenty-one orders cover all twenty-one days, so no day grid is left holding
  // every bar.
  testSync("spread 21 orders over 21 different future days", () => {
    let distinct = days->Array.reduce([], (acc, d) => acc->Array.includes(d) ? acc : [...acc, d])
    expect((
      distinct->Array.length,
      days->Array.every(d => d > "2026-09-17" && d <= "2026-10-08"),
    ))->toEqual((21, true))
  })

  testSync("produce valid date-time instants", () => {
    expect(
      windows->Array.every(
        w =>
          Reventless.DateTime.fromString(w.start)->Result.isOk &&
            Reventless.DateTime.fromString(w.end_)->Result.isOk,
      ),
    )->toBe(true)
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

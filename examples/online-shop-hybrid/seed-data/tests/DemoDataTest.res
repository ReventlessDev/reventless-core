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

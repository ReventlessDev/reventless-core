open JestGlobals

// `.reventless/users.yaml` is hand-maintained and shared with the auth adapter,
// so the seed reads it defensively: it must survive the comment blocks both
// copies carry, must not reorder the accounts (the first one is the prompt's
// default, so order IS the contract), and must never throw — a broken file costs
// the menu, not the run.

let document = `
# Local dev users — a comment block like the real file carries.

- username: admin
  password: admin
  groups: [Admin, Shopper]
  userId: local-admin

- username: shopper
  password: Shopper-2026!
  groups: [Shopper]

- username: noGroups
  password: pw
`

describe("Seed_Users.parseString:", () => {
  testSync("reads every account, in the order the file defines them", () => {
    let users = Seed_Users.parseString(document)
    expect(users->Array.map(u => u.Seed_Users.username))->Expect.toEqual([
      "admin",
      "shopper",
      "noGroups",
    ])
  })

  testSync("carries the password beside the username", () => {
    let users = Seed_Users.parseString(document)
    expect(users->Array.map(u => u.Seed_Users.password))->Expect.toEqual([
      "admin",
      "Shopper-2026!",
      "pw",
    ])
  })

  testSync("keeps the groups, and reads a missing groups key as none", () => {
    let users = Seed_Users.parseString(document)
    expect(users->Array.map(u => u.Seed_Users.groups))->Expect.toEqual([
      ["Admin", "Shopper"],
      ["Shopper"],
      [],
    ])
  })

  // The half that was dropped, and the reason owner-scoped demo rows were keyed
  // to ids nobody on a Cognito deployment holds: the file records the id the
  // platform stamps, and reading it only for a password threw that away.
  //
  // Absent stays absent rather than defaulting to the username — a local file
  // may omit it and let the auth adapter default it, and an AWS file records a
  // sub no default could invent. Guessing here would look like an answer.
  testSync("keeps the userId an entry declares, and reads a missing one as absent", () => {
    let users = Seed_Users.parseString(document)
    expect(users->Array.map(u => u.Seed_Users.userId))->Expect.toEqual([
      Some("local-admin"),
      None,
      None,
    ])
  })

  // An entry half-written by hand is the likely flaw in this file. Dropping it
  // keeps the other accounts selectable; failing the parse would not.
  testSync("skips an entry that names no password", () => {
    let users = Seed_Users.parseString(`
- username: admin
  password: admin
- username: halfWritten
  groups: [Shopper]
`)
    expect(users->Array.map(u => u.Seed_Users.username))->Expect.toEqual(["admin"])
  })

  testSync("yields no accounts for a document that is not a list", () => {
    expect(Seed_Users.parseString("users: {}")->Array.length)->Expect.toBe(0)
  })

  // The whole point of returning accounts rather than raising: the caller falls
  // back to prompting, and it can only do that if nothing here escapes.
  testSync("yields no accounts for malformed YAML instead of throwing", () => {
    expect(Seed_Users.parseString("- username: [unclosed")->Array.length)->Expect.toBe(0)
  })
})

describe("Seed_Users.load:", () => {
  testSync("is silent about a file that is not there", () => {
    expect(Seed_Users.load(~path="/nonexistent/.reventless/users.yaml"))->Expect.toBe(None)
  })
})

describe("Seed_Users.label:", () => {
  testSync("names the groups an account carries", () => {
    expect(
      Seed_Users.label({
        username: "admin",
        password: "x",
        groups: ["Admin", "Shopper"],
        userId: None,
      }),
    )->Expect.toBe("admin  [Admin, Shopper]")
  })

  testSync("is the bare username when the file records no groups", () => {
    expect(
      Seed_Users.label({username: "admin", password: "x", groups: [], userId: None}),
    )->Expect.toBe("admin")
  })

  // The menu is unchanged by the id: an operator picks an account by name and
  // membership, and a Cognito sub in the list would be noise at the one moment
  // they are choosing a login.
  testSync("says nothing about the userId", () => {
    expect(
      Seed_Users.label({
        username: "admin",
        password: "x",
        groups: ["Admin"],
        userId: Some("4275e4a4-00c1-70e1-1cb5-363b06b992b5"),
      }),
    )->Expect.toBe("admin  [Admin]")
  })
})

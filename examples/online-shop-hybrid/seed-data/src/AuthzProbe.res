// Does the deployed API actually refuse what the specs say it should?
//
// Nothing tested that. The GWT suites test behaviour, and a plugin's authorization
// annotations become AppSync directives at deploy time — so the whole path from
// annotation to directive to refusal was only ever exercised by an operator
// hitting a wall. It cost an afternoon once already: an `admin` account refused on
// `Catalog_ProductDemands`, a view its groups plainly allow, because the *token*
// carried one narrowed role and nothing compared the two. That exact case is the
// first row this checks.
//
// A `Seed.dataSet` rather than a phase of the demo seed, because it is a different
// job: it fills nothing, it runs against a store that is ALREADY seeded, and it is
// worth running on its own. `SEED_SET=authz` selects it.
//
// **It writes nothing.** Reads change nothing, and every command it sends carries
// a payload the domain refuses anyway — so a door that opens answers
// `CommandRejected`, which appends no events.
//
// **Every rule is read off its spec**, so a re-annotation moves the check with
// it: a queryable's `authorization`, a command's `authorizationOf(name)`.

open ReventlessSeed

// What the caller may do, against what the component demands. Groups come from
// the TOKEN rather than the accounts file: membership is not what authorizes, as
// a narrowed role demonstrates, and the server only ever sees the token.
// Each role is compared as the group it maps to, as the server compares it.
let permits = (rule: Reventless.Authorization.permission, ~groups: array<string>): bool =>
  rule->Reventless.Authorization.admits(~signedIn=true, ~holds=role =>
    groups->Array.includes(Reventless.Role.groupOf(role))
  )

let describeRule = (rule: Reventless.Authorization.permission): string =>
  switch rule {
  | DenyAll => "nobody"
  | AllowAnonymous => "anyone"
  | AllowAuthenticated => "any authenticated caller"
  | AllowRoles(_) => rule->Reventless.Authorization.groupsOf->Array.join(" | ")
  }

// What to ask, and the rule that should decide the answer. A command carries the
// very mutation the seed itself would send, so what is probed is what is used.
type subject =
  | Command(Seed.mutation)
  | Queryable(string)

type probeCase = {
  name: string,
  rule: Reventless.Authorization.permission,
  subject: subject,
}

// A command's rule, by the constructor name the spec answers for.
let commandRule = (authorizationOf: string => Reventless.Authorization.rule<'role>, name) =>
  name->authorizationOf->Reventless.Authorization.named

// Commands are sent with payloads the domain refuses anyway — ids that cannot
// exist — so an authorized caller is rejected by the domain rather than served.
// That is what keeps this non-writing: a door that opens answers CommandRejected,
// which appends no events, so even a regression that wrongly GRANTS a command
// cannot corrupt the demo data on its way to being reported.
let missing = "probe-does-not-exist"

let cases: array<probeCase> = [
  // Catalog: gated on Admin | Merchandiser.
  {
    name: "Catalog_ArchiveProduct",
    rule: commandRule(CatalogPlugin.ArchiveProduct.authorizationOf, "ArchiveProduct"),
    subject: Command(
      DemoCommands.archiveProduct(ArchiveProduct({productId: CatalogSpec.ProductId.make(missing)})),
    ),
  },
  {
    name: "Catalog_RenameCategory",
    rule: commandRule(CatalogPlugin.RenameCategory.authorizationOf, "RenameCategory"),
    subject: Command(
      DemoCommands.renameCategory(
        RenameCategory({categoryId: CatalogPlugin.CategoryId.make(missing), name: "probe"}),
      ),
    ),
  },
  // The one command gated on Admin | Fulfilment, and the reason the two operator
  // roles are not interchangeable.
  {
    name: "Ordering_ShipOrder",
    rule: commandRule(OrderingPlugin.ShipOrder.authorizationOf, "ShipOrder"),
    subject: Command(
      DemoCommands.shipOrder(ShipOrder({orderId: OrderingPlugin.OrderId.make(missing)})),
    ),
  },
  // An ungated command. Not padding: a run where EVERYTHING is refused — a broken
  // token, an unreachable API — would otherwise read as a clean pass on every row
  // that expects refusal.
  {
    name: "Ordering_CancelOrder",
    rule: commandRule(OrderingPlugin.CancelOrder.authorizationOf, "CancelOrder"),
    subject: Command(
      DemoCommands.cancelOrder(CancelOrder({orderId: OrderingPlugin.OrderId.make(missing)})),
    ),
  },
  // The two gated views, and the ungated control for the same reason as the
  // command one.
  {
    name: "Catalog_ProductDemands",
    rule: CatalogPlugin.ProductDemand.authorization->Reventless.Authorization.named,
    subject: Queryable("Catalog_ProductDemands"),
  },
  {
    name: "Ordering_Customers",
    rule: OrderingPlugin.Customers.authorization->Reventless.Authorization.named,
    subject: Queryable("Ordering_Customers"),
  },
  {
    name: "Catalog_Products",
    rule: CatalogPlugin.Products.authorization->Reventless.Authorization.named,
    subject: Queryable("Catalog_Products"),
  },
]

type outcome = {name: string, ok: bool, detail: string}

let ask = async (client: Seed.Client.t, ~subject: subject): Seed.Client.access =>
  switch subject {
  | Command(m) => await client->Seed.Client.checkCommandAccess(m)
  | Queryable(field) => await client->Seed.Client.checkQueryAccess(~field)
  }

let probeAccount = async (connection: Seed.connection, ~account: Seed.Users.user): array<
  outcome,
> => {
  let client = await Seed.Connect.clientFor(connection, ~account)
  // The token's groups, not the file's. A narrowed bearer holds less than the
  // account does, and that difference is the whole reason this exists.
  let groups = Seed.Client.effectiveGroups(client)->Option.getOr([])
  Seed.Runner.heading(
    `${account.username} — token carries ${groups->Array.length == 0
        ? "no groups"
        : groups->Array.join(", ")}`,
  )
  let out = []
  for i in 0 to cases->Array.length - 1 {
    switch cases->Array.get(i) {
    | Some({name, rule, subject}) =>
      let expected = rule->permits(~groups)
      let actual = await ask(client, ~subject)
      // `Broke` is never a pass. A field the schema does not carry, or a fault on
      // the endpoint, answers neither question — and read as "not refused" it
      // would turn a deploy that dropped a field into a green check.
      let (ok, detail) = switch (expected, actual) {
      | (true, Granted) => (true, `allowed (${describeRule(rule)}), as declared`)
      | (false, Refused) => (true, `refused (needs ${describeRule(rule)}), as declared`)
      // Served but empty, where a refusal was due. The local platform denies a
      // read that way — its interceptor returns an empty connection rather than
      // an error — so this IS what a correct denial looks like there, and it
      // cannot be told apart from a view that genuinely holds nothing.
      | (false, Empty) => (
          true,
          `served nothing (needs ${describeRule(rule)}) — consistent with a denial`,
        )
      // The same ambiguity pointing the other way, and deliberately not a
      // failure: a caller who may read a view that happens to be empty looks
      // exactly like one who may not read it. Failing here would make the check
      // depend on how much data the store happens to hold.
      | (true, Empty) => (
          true,
          `INCONCLUSIVE — served no rows, so allowed-and-empty cannot be told from denied`,
        )
      | (true, Refused) => (
          false,
          `REFUSED, but ${describeRule(
              rule,
            )} should be allowed — the deployed rule is narrower than the spec, or this token is narrower than the account`,
        )
      // The one unambiguous failure: rows handed to a caller the spec excludes.
      | (false, Granted) => (
          false,
          `ALLOWED, but only ${describeRule(
              rule,
            )} should be — the deployed rule is missing or wider than the spec`,
        )
      | (_, Broke(message)) => (false, `neither allowed nor refused: ${message}`)
      }
      Seed.Runner.report(`${ok ? "✓" : "✗"} ${name}: ${detail}`)
      out->Array.push({name, ok, detail})
    | None => ()
    }
  }
  out
}

let run = async (connection: Seed.connection): unit => {
  if connection.accounts->Array.length == 0 {
    throw(
      Seed.Failed(
        "the authorization check needs an accounts file: it reads each account's password to " ++
        "ask the same questions as several callers. The REVENTLESS_DEMO_USER/PASSWORD path " ++ "supplies one identity, which cannot answer whether a door is closed to anybody else.",
      ),
    )
  }
  let failures = []
  let accounts = connection.accounts
  for i in 0 to accounts->Array.length - 1 {
    switch accounts->Array.get(i) {
    | Some(account) =>
      let results = await probeAccount(connection, ~account)
      results->Array.forEach(r =>
        if !r.ok {
          failures->Array.push(`${account.username} / ${r.name}: ${r.detail}`)
        }
      )
    | None => ()
    }
  }
  Seed.Runner.heading(
    `Checked ${(accounts->Array.length * cases->Array.length)
        ->Int.toString} account × subject ` ++ `pairs against what the specs declare.`,
  )
  if failures->Array.length > 0 {
    throw(
      Seed.Failed(
        `the deployed authorization does not match the specs:\n  ` ++ failures->Array.join("\n  "),
      ),
    )
  }
  Seed.Runner.report("every door matched its declaration.")
}

// No `probeViews`: the fresh-store guard is exactly wrong here. This runs against
// a store that has already been seeded, and refusing to start on a non-empty one
// would refuse every run it is meant for.
let dataSet: Seed.dataSet = {
  name: "authz",
  label: "authorization check — every account against every gated door (writes nothing)",
  seed: run,
}

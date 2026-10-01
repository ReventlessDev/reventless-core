open JestGlobals

// Roles are what rules name and groups are what identities carry; these pin the
// one mapping between them that enforcement, the published access keys and the
// deploy check all read.

// Roles as a plugin declares them; `role` is the PPX's step from case to name.
module Roles = {
  type t =
    | Admin
    | Merchandiser
    | Fulfilment
}
let role = (r: Roles.t) => Role.make((r :> string))

let identity = (groups): Identity.t => {userId: "u1", username: "u1", groups, provider: InMemory}

let reset = () => {
  Role.clearGroups()
  Role.clearProvidedGroups()
  OwnerScope.clearElevatedGroups()
}

describe("Role.groupOf", () => {
  beforeEach(reset)

  testSync("a role maps to the group of its own name by default", () =>
    expect(Role.groupOf(role(Merchandiser)))->toBe("Merchandiser")
  )

  testSync("a renamed role maps to its group", () => {
    Role.setGroups([(role(Merchandiser), "shop-merch-team")])
    expect((Role.groupOf(role(Merchandiser)), Role.groupOf(role(Admin))))->toEqual((
      "shop-merch-team",
      "Admin",
    ))
  })

  testSync("the environment form round-trips", () => {
    Role.setGroups([(role(Merchandiser), "shop-merch-team"), (role(Admin), "ops")])
    expect(Role.envValue()->Option.map(Role.parseGroups))->toEqual(
      Some([(role(Merchandiser), "shop-merch-team"), (role(Admin), "ops")]),
    )
  })

  testSync("no renamed role writes no environment entry", () =>
    expect(Role.envValue())->toEqual(None)
  )

  // A mapping stated after the platform rendered from it would split one
  // deployment between two answers.
  testSync("a mapping stated after the platform froze it is refused", () => {
    Role.freeze()
    expect(
      switch Role.setGroups([(role(Admin), "ops")]) {
      | () => false
      | exception _ => true
      },
    )->toBe(true)
  })
})

describe("Authorization with roles", () => {
  beforeEach(reset)

  testSync("AllowRoles admits a caller in the group a role maps to", () => {
    Role.setGroups([(role(Merchandiser), "shop-merch-team")])
    let rule = Authorization.AllowRoles([role(Merchandiser)])
    expect((
      rule->Authorization.isAllowed(identity(["shop-merch-team"])),
      rule->Authorization.isAllowed(identity(["Merchandiser"])),
    ))->toEqual((true, false))
  })

  // A spec writes its rule over its plugin's own roles; the framework reads the
  // same rule over their names.
  testSync("a rule over a plugin's roles reads as their names", () => {
    let rule: Authorization.rule<Roles.t> = AllowRoles([Admin, Merchandiser])
    expect(rule->Authorization.named->Authorization.rolesOf)->toEqual([
      role(Admin),
      role(Merchandiser),
    ])
  })

  testSync("a role that is not a case without a payload is refused", () => {
    let rule: Authorization.rule<(int, int)> = AllowRoles([(1, 2)])
    expect(
      switch rule->Authorization.named {
      | _ => false
      | exception _ => true
      },
    )->toBe(true)
  })

  testSync("the access keys are mapped and the roles are not", () => {
    Role.setGroups([(role(Merchandiser), "shop-merch-team")])
    let rule = Authorization.AllowRoles([role(Admin), role(Merchandiser)])
    expect((Authorization.groupsOf(rule), Authorization.rolesOf(rule)))->toEqual((
      ["Admin", "shop-merch-team"],
      [role(Admin), role(Merchandiser)],
    ))
  })

  testSync("admits decides from held roles alone", () => {
    let rule = Authorization.AllowRoles([role(Fulfilment)])
    expect((
      rule->Authorization.admits(~signedIn=true, ~holds=r => r == role(Fulfilment)),
      rule->Authorization.admits(~signedIn=true, ~holds=_ => false),
      Authorization.DenyAll->Authorization.admits(~signedIn=true, ~holds=_ => true),
      Authorization.AllowAnonymous->Authorization.admits(~signedIn=false, ~holds=_ => false),
    ))->toEqual((true, false, false, true))
  })
})

describe("OwnerScope elevated roles", () => {
  beforeEach(reset)

  testSync("are resolved to groups and joined with elevated groups", () => {
    OwnerScope.setElevatedRoles([role(Fulfilment)])
    OwnerScope.setElevatedGroups(["Support"])
    Role.setGroups([(role(Fulfilment), "shop-ops")])
    expect(OwnerScope.elevatedGroups())->toEqual(["Support", "shop-ops"])
  })

  testSync("a default does not overrule an explicit role list", () => {
    OwnerScope.setElevatedRoles([])
    OwnerScope.defaultElevatedRoles([Role.admin])
    expect(OwnerScope.elevatedGroups())->toEqual([])
  })
})

let command = (name, ~roles): Plugin.commandDef => {
  name,
  schema: "{}",
  level: Collection,
  aggregateIdField: None,
  mutationField: "",
  references: [],
  allowedStates: None,
  targetState: None,
  apiExposed: None,
  requiredAccess: None,
  requiredRoles: ?roles,
  ownerField: None,
}

let structure = (commands): Plugin.pluginStructure => {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [
    {
      name: "Product",
      commands,
      producedEventTypes: [],
      consumedEventTypes: [],
      linkedViews: [],
      consistencyRead: None,
      events: [],
      errors: [],
      chapter: None,
    },
  ],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
  requiredCapabilities: None,
  traitDeclarations: None,
}

let refusal = f =>
  switch f() {
  | () => None
  | exception JsExn(e) => JsExn.message(e)
  }

describe("RoleCoverage.check", () => {
  beforeEach(reset)

  let gated = structure([
    command("AddProduct", ~roles=Some(["Admin", "Merchandiser"])),
    command("ViewCart", ~roles=None),
  ])

  testSync("checks nothing where no platform said what it provides", () =>
    expect(refusal(() => RoleCoverage.check(gated, ~plugin="Catalog")))->toEqual(None)
  )

  testSync("passes when every role has a group", () => {
    Role.provideGroups(["Admin", "Merchandiser"])
    expect(refusal(() => RoleCoverage.check(gated, ~plugin="Catalog")))->toEqual(None)
  })

  testSync("names the plugin, the command and the role nobody provides", () => {
    Role.provideGroups(["Admin"])
    expect(
      refusal(() => RoleCoverage.check(gated, ~plugin="Catalog"))->Option.map(
        m => m->String.includes("Catalog: Product.AddProduct needs the role Merchandiser"),
      ),
    )->toEqual(Some(true))
  })

  testSync("a group the mapping names counts as provided", () => {
    Role.provideGroups(["Admin"])
    Role.setGroups([(role(Merchandiser), "shop-merch-team")])
    expect(refusal(() => RoleCoverage.check(gated, ~plugin="Catalog")))->toEqual(None)
  })

  testSync("a role mapped to a group nobody provides names both", () => {
    Role.setGroups([(role(Merchandiser), "shop-merch-team")])
    expect(
      RoleCoverage.needsOf(gated, ~plugin="Catalog")
      ->RoleCoverage.unmet(~provided=["Admin", "Merchandiser"])
      ->Array.map(RoleCoverage.describe),
    )->toEqual([
      "Catalog: Product.AddProduct needs the role Merchandiser (mapped to the group shop-merch-team)",
    ])
  })

  testSync("an elevated role nobody provides is refused too", () => {
    Role.provideGroups(["Admin", "Merchandiser"])
    OwnerScope.setElevatedRoles([role(Fulfilment)])
    expect(
      refusal(() => RoleCoverage.check(gated, ~plugin="Catalog"))->Option.map(
        m => m->String.includes("platform: elevated roles needs the role Fulfilment"),
      ),
    )->toEqual(Some(true))
  })
})

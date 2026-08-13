open JestGlobals

// The Cognito minting point, unit-tested with no pool attached to it. The
// pre-token-generation event shape is fixed and documented, so the decision and
// the response it produces are checkable before any pool exists — which is what
// makes the attach step the only unknown left when it runs.

module Trigger = Auth_ActiveRoleTrigger_Ops
module Contract = ReventlessCore.Auth_ActiveRole

let eventFor = (
  ~membership: array<string>,
  ~iamRoles: array<string>=[],
  ~preferredRole: option<string>=?,
): Trigger.event => {
  request: {
    userAttributes: {sub: "u-carol"},
    groupConfiguration: {
      groupsToOverride: membership,
      iamRolesToOverride: iamRoles,
      preferredRole: ?preferredRole->Option.map(Nullable.make),
    },
  },
  userName: "carol",
}

let overrideOf = (e: Trigger.event) =>
  e.response->Option.flatMap(r => r.claimsOverrideDetails)

let groupsOf = (e: Trigger.event) =>
  overrideOf(e)->Option.flatMap(c => c.groupOverrideDetails)->Option.map(g => g.groupsToOverride)

let claimOf = (e: Trigger.event, key) =>
  overrideOf(e)->Option.flatMap(c => c.claimsToAddOrOverride)->Option.flatMap(c => c->Dict.get(key))

// ── The shared conformance table ──────────────────────────────────────────
//
// The same cases the local minting path runs (`LocalAuthLoginTest`). The two
// implementations cannot be shared across a process boundary, so the table is
// what keeps them from drifting.
//
// The cases expecting a **refusal** read differently here, and deliberately:
// this path has no client to refuse — it is reading stored state on an ordinary
// refresh with nobody asking for anything. It mints the full set instead. What
// both paths must satisfy is the rule underneath: a role outside membership
// never ends up in the group claim, and what the caller is left holding is
// exactly what the pool granted.
//
// So the assertion is on the groups the token *ends up* carrying, not on how the
// trigger got there — an absent override and an override naming the full set are
// the same token. That an absent override really is absent (rather than an empty
// one, which is not the same thing) is asserted separately below.

let effectiveGroups = (e: Trigger.event, ~membership) =>
  groupsOf(e)->Option.getOr(membership)

describe("the conformance table, minted by the trigger", () => {
  Contract.conformanceCases->Array.forEach(({label, membership, requested, expected}) =>
    testSync(label, () => {
      let event = Trigger.respond(
        ~event=eventFor(~membership),
        ~decision=Trigger.decide(~membership, ~storedRole=requested),
      )
      expect(effectiveGroups(event, ~membership))->toEqual(expected->Option.getOr(membership))
    })
  )
})

describe("Auth_ActiveRoleTrigger_Ops.decide", () => {
  testSync("no stored role leaves the token alone", () =>
    expect(Trigger.decide(~membership=["Admin"], ~storedRole=None))->toEqual(Trigger.Unchanged)
  )

  testSync("an empty stored role is the same as none, not a request for nothing", () =>
    expect(Trigger.decide(~membership=["Admin"], ~storedRole=Some("")))->toEqual(Trigger.Unchanged)
  )

  testSync("a held role narrows", () =>
    expect(
      Trigger.decide(~membership=["Admin", "Shopper"], ~storedRole=Some("Shopper")),
    )->toEqual(Trigger.Narrow({role: "Shopper", membership: ["Admin", "Shopper"]}))
  )

  // The case the local path never had to answer: the row outlives the membership.
  testSync("a role the pool no longer grants is stale, not applied", () =>
    expect(Trigger.decide(~membership=["Shopper"], ~storedRole=Some("Admin")))->toEqual(
      Trigger.Stale({role: "Admin", membership: ["Shopper"]}),
    )
  )
})

describe("Auth_ActiveRoleTrigger_Ops.respond", () => {
  // The regression line for the whole feature.
  testSync("an unnarrowed refresh mints exactly what it minted before", () => {
    let input = eventFor(~membership=["Admin", "Shopper"])
    expect(Trigger.respond(~event=input, ~decision=Unchanged))->toEqual(input)
  })

  testSync("narrowing puts the chosen role alone in the group claim", () => {
    let event = Trigger.respond(
      ~event=eventFor(~membership=["Admin", "Shopper"]),
      ~decision=Narrow({role: "Shopper", membership: ["Admin", "Shopper"]}),
    )
    expect(groupsOf(event))->toEqual(Some(["Shopper"]))
  })

  testSync("a narrowed token records the choice and what it gave up", () => {
    let event = Trigger.respond(
      ~event=eventFor(~membership=["Admin", "Shopper"]),
      ~decision=Narrow({role: "Shopper", membership: ["Admin", "Shopper"]}),
    )
    expect((
      claimOf(event, Contract.activeRoleClaim),
      claimOf(event, Contract.availableRolesClaim),
    ))->toEqual((Some("Shopper"), Some("Admin,Shopper")))
  })

  // "…and says so where it can be seen": without this the caller is silently
  // un-narrowed with nothing to explain why their chosen role stopped applying.
  testSync("a stale role mints the full set and marks itself as stale", () => {
    let event = Trigger.respond(
      ~event=eventFor(~membership=["Shopper"]),
      ~decision=Stale({role: "Admin", membership: ["Shopper"]}),
    )
    expect((groupsOf(event), claimOf(event, Contract.staleRoleClaim)))->toEqual((
      Some(["Shopper"]),
      Some("Admin"),
    ))
  })

  testSync("a stale role is never the active role", () => {
    let event = Trigger.respond(
      ~event=eventFor(~membership=["Shopper"]),
      ~decision=Stale({role: "Admin", membership: ["Shopper"]}),
    )
    expect(claimOf(event, Contract.activeRoleClaim))->toEqual(None)
  })

  // 🚨 `groupOverrideDetails` replaces the whole group configuration. An override
  // that names only `groupsToOverride` silently drops the other two — the same
  // reset-by-omission shape `UpdateUserPool` has, and just as quiet.
  testSync("narrowing carries the caller's IAM roles through untouched", () => {
    let event = Trigger.respond(
      ~event=eventFor(
        ~membership=["Admin", "Shopper"],
        ~iamRoles=["arn:aws:iam::1:role/Shopper"],
        ~preferredRole="arn:aws:iam::1:role/Shopper",
      ),
      ~decision=Narrow({role: "Shopper", membership: ["Admin", "Shopper"]}),
    )
    let details = overrideOf(event)->Option.flatMap(c => c.groupOverrideDetails)
    expect((
      details->Option.map(d => d.iamRolesToOverride),
      details->Option.flatMap(d => d.preferredRole),
    ))->toEqual((Some(["arn:aws:iam::1:role/Shopper"]), Some(Nullable.make("arn:aws:iam::1:role/Shopper"))))
  })

  testSync("a stale mint carries them through too", () => {
    let event = Trigger.respond(
      ~event=eventFor(~membership=["Shopper"], ~iamRoles=["arn:aws:iam::1:role/Shopper"]),
      ~decision=Stale({role: "Admin", membership: ["Shopper"]}),
    )
    expect(
      overrideOf(event)
      ->Option.flatMap(c => c.groupOverrideDetails)
      ->Option.map(d => d.iamRolesToOverride),
    )->toEqual(Some(["arn:aws:iam::1:role/Shopper"]))
  })
})

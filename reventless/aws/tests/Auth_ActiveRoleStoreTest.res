open JestGlobals

// The subset rule on the Cognito path's write door, driven by the conformance
// table in `ReventlessCore.Auth_ActiveRole`.
//
// That table is the shared artifact §6 of the plan calls for: the check itself is
// written twice (this one runs in a resolver Lambda against an AppSync event, the
// trigger's runs in Cognito's runtime against Cognito's event shape), so the cases
// are what keeps the two from drifting on the question that carries the security.

module Ops = Auth_ActiveRoleStore_Ops
module Contract = ReventlessCore.Auth_ActiveRole

describe("Auth_ActiveRoleStore_Ops.mayActAs — the conformance table", () => {
  Contract.conformanceCases->Array.forEach(({label, membership, requested, expected}) =>
    switch requested {
    // "no role requested" has no subset decision to make — it is the clearing
    // path, exercised against the handler rather than the predicate.
    | None => ()
    | Some(role) =>
      testSync(label, () =>
        expect(Ops.mayActAs(~membership, ~requested=role))->toBe(expected->Option.isSome)
      )
    }
  )
})

// The table above is the contract; these are the properties it encodes, asserted
// directly so a future edit that weakens a case is visible as a failure here too.
describe("Auth_ActiveRoleStore_Ops.mayActAs — narrowing only", () => {
  testSync("a role outside membership is never permitted", () =>
    expect(Ops.mayActAs(~membership=["Shopper"], ~requested="Admin"))->toBe(false)
  )

  testSync("membership is matched exactly, so no case folding widens it", () =>
    expect(Ops.mayActAs(~membership=["Admin"], ~requested="ADMIN"))->toBe(false)
  )

  testSync("an empty membership permits nothing at all", () =>
    expect(Ops.mayActAs(~membership=[], ~requested="Shopper"))->toBe(false)
  )
})

// Which name goes to Cognito. `sub` keys the row and `AdminListGroupsForUser`
// takes a username, and a pool that makes neither an alias of the other answers
// `UserNotFoundException` when handed the wrong one — a signed-in caller holding
// the role they asked for, told they do not exist.
describe("Auth_ActiveRoleStore_Ops.cognitoLookupName", () => {
  testSync("the username is what addresses Cognito when the authorizer sent one", () =>
    expect(
      Ops.cognitoLookupName(~identity={sub: "d265d464-2091-706a-e5f9-3afafe7be29c", username: Value("merch")}),
    )->toEqual(Some("merch"))
  )

  testSync("an absent username falls back to the subject, as before it was forwarded", () =>
    expect(Ops.cognitoLookupName(~identity={sub: "sub-1"}))->toEqual(Some("sub-1"))
  )

  // The resolver sends `id.username ?? null`, so null is the shape an authorizer
  // that names no username actually produces — not a missing field.
  testSync("an explicitly null username falls back too", () =>
    expect(Ops.cognitoLookupName(~identity={sub: "sub-1", username: Null}))->toEqual(Some("sub-1"))
  )

  testSync("a blank username is not a name to look anyone up by", () =>
    expect(Ops.cognitoLookupName(~identity={sub: "sub-1", username: Value("   ")}))->toEqual(
      Some("sub-1"),
    )
  )

  testSync("neither name means there is nobody to ask about", () =>
    expect(Ops.cognitoLookupName(~identity={}))->toEqual(None)
  )
})

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

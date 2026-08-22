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

// Which store this deployment reads and writes. Two cases and no third: a stack
// that creates its own provider owns everything attached to it, and a stack given
// a provider owns none of it. See
// [docs/plans/active-role-store-scoped-to-the-pool.md].
describe("Auth_ActiveRoleStore.chooseStore", () => {
  testSync("a stack that creates its own provider keeps its own table", () =>
    expect(Auth_ActiveRoleStore.chooseStore(~identityProviderId=None))->toEqual(
      Auth_ActiveRoleStore.StackScoped,
    )
  )

  testSync("a stack given a provider reads that provider's derived store", () =>
    expect(Auth_ActiveRoleStore.chooseStore(~identityProviderId=Some("eu-west-1_CQTwafSeX")))
    ->toEqual(
      Auth_ActiveRoleStore.ProviderScoped("ReventlessActiveRoleStore-eu-west-1_CQTwafSeX"),
    )
  )

  // 🚨 The defect, expressed as the property that now prevents it. Two platform
  // stacks on one provider previously deployed a table each, so the pool's single
  // trigger read rows the other's resolver wrote — every switch succeeding and
  // doing nothing. There is no configuration either could carry that would make
  // them disagree.
  testSync("two deployments on one provider cannot choose different stores", () =>
    expect(Auth_ActiveRoleStore.chooseStore(~identityProviderId=Some("eu-west-1_Shared")))
    ->toEqual(Auth_ActiveRoleStore.chooseStore(~identityProviderId=Some("eu-west-1_Shared")))
  )
})

// The second half of the row key. Every other absent field in this handler has a
// defensible default; this one does not, and the test that matters is the one
// asserting it refuses rather than substituting something.
describe("Auth_ActiveRoleStore_Ops.appClientId", () => {
  testSync("the app client the authorizer resolved is the one used", () =>
    expect(Ops.appClientId(~identity={sub: "sub-1", clientId: Value("7cl13nt")}))->toEqual(
      Some("7cl13nt"),
    )
  )

  // 🚨 The trigger keys its read on the client id Cognito hands it, so a write
  // under any substitute — a constant, the subject, the empty string — is a row
  // the trigger never finds. Refusing is the only answer that does not recreate
  // the defect one level down.
  testSync("an absent client id yields nothing to key a row on", () =>
    expect(Ops.appClientId(~identity={sub: "sub-1"}))->toEqual(None)
  )

  // The resolver sends `appClientId(id)`, which returns null when the claims are
  // not there to read — so null is the shape that actually arrives, not a missing
  // field.
  testSync("an explicitly null client id is not a client id", () =>
    expect(Ops.appClientId(~identity={sub: "sub-1", clientId: Null}))->toEqual(None)
  )

  testSync("a blank client id is not a client id either", () =>
    expect(Ops.appClientId(~identity={sub: "sub-1", clientId: Value("   ")}))->toEqual(None)
  )

  // The subject is deliberately not a fallback: it would key every platform's row
  // identically and undo the per-platform narrowing the pair key exists for.
  testSync("the subject is never substituted for the app client", () =>
    expect(Ops.appClientId(~identity={sub: "sub-1", clientId: Null}))->toEqual(None)
  )
})

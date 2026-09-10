open JestGlobals

// The capability's refusal, which is the only behaviour it has until a backend
// lands. What matters is that refusing is *modelled* — a caller must be able to
// tell "this deployment has no identity provider" from "this person may not
// have an account", because the second is a verdict and the first is a gap.

let principal: IdentityProvider.principal = {providerId: "provider-handle"}

describe("IdentityProvider.unavailable", () => {
  let provider = IdentityProvider.unavailable(~reason="none configured")

  testPromise("createPrincipal is retryable, never a refusal", async () => {
    let answer = await provider.createPrincipal(
      ~contact=ToEmail(Email.fromString("a@example.com")->Result.getOr("a@example.com")),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(answer)->toEqual(Error(IdentityProvider.Unavailable("none configured")))
  })

  // 🚨 The distinction the three arms exist for. A caller reaching here has
  // already recorded that the address was proven, so `Refused` would strand
  // somebody who did everything asked of them; `Unavailable` keeps the work
  // queued until a provider exists.
  testPromise("every operation refuses the retryable way", async () => {
    let answers = [
      await provider.addToGroup(~principal, ~group="User"),
      await provider.removeFromGroup(~principal, ~group="User"),
      await provider.deletePrincipal(~principal),
    ]
    expect(answers)->toEqual(
      answers->Array.map(_ => Error(IdentityProvider.Unavailable("none configured"))),
    )
  })

  // The empty list and the retryable send say different true things and both are
  // needed: this is what a caller reads *before* offering a flow that cannot
  // complete, rather than discovering it on the last step.
  testSync("publishes no operations at all", () => expect(provider.operations)->toEqual([]))

  testSync("supports answers false for everything", () =>
    expect(
      [IdentityProvider.CreatePrincipal, AddToGroup, RemoveFromGroup, DeletePrincipal]->Array.map(
        operation => provider->IdentityProvider.supports(~operation),
      ),
    )->toEqual([false, false, false, false])
  )
})

describe("Capabilities.none", () => {
  testSync("carries a refusing identity provider rather than leaving a hole", () =>
    expect(Capabilities.none.identityProvider.operations)->toEqual([])
  )
})

// `setActiveRole` is absent on purpose: narrowing a caller's claims happens when
// a token is minted, which is the auth seam's work, not the principal store's.
// Asserted so that adding it becomes a deliberate decision rather than a drift.
describe("IdentityProvider.operation", () => {
  testSync("covers principal lifecycle and nothing else", () =>
    expect(
      [IdentityProvider.CreatePrincipal, AddToGroup, RemoveFromGroup, DeletePrincipal]->Array.map(
        IdentityProvider.operationToString,
      ),
    )->toEqual(["CreatePrincipal", "AddToGroup", "RemoveFromGroup", "DeletePrincipal"])
  )
})

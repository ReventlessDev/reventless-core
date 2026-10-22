open JestGlobals

// The identity store's name and key, shared by the deploy, the trigger and the
// provisioning scripts. The symptom of any two disagreeing is quiet: the claim
// is never added, and every new account silently keeps its `sub`.

module Schema = Auth_IdentityStore_Schema

describe("Auth_IdentityStore_Schema", () => {
  testSync("names the store after the provider whose trigger reads it", () =>
    expect(Schema.derivedStoreName(~identityProviderId="eu-west-1_CQTwafSeX"))->toBe(
      "ReventlessIdentityStore-eu-west-1_CQTwafSeX",
    )
  )

  testSync("does not collide with the active-role store on the same provider", () =>
    expect(
      Schema.derivedStoreName(~identityProviderId="eu-west-1_A") ==
        Auth_ActiveRoleStore_Schema.derivedStoreName(~identityProviderId="eu-west-1_A"),
    )->toBe(false)
  )

  testSync("is keyed on the subject alone", () =>
    expect(Schema.expectedKeySchema)->toEqual([("id", "HASH")])
  )

  testSync("adopts a table with the right key and refuses one with another", () => {
    expect(Schema.keySchemaRefusal(~tableName="t", ~actual=[("id", "HASH")]))->toEqual(None)
    expect(
      Schema.keySchemaRefusal(~tableName="t", ~actual=[("id", "HASH"), ("clientId", "RANGE")])
      ->Option.map(m => m->String.includes("identity store needs [id:HASH]"))
      ->Option.getOr(false),
    )->toBe(true)
  })
})

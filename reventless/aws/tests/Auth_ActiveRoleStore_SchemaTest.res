open JestGlobals

// The store's identity — its name and its key — is shared by four things that
// cannot see each other: the deploy, the write door, the pre-token trigger, and
// the provisioning script an operator runs by hand. Any two of them disagreeing
// produces one symptom, and it is the symptom this whole area exists to end: a
// row written where nothing looks for it, so a role switch reports success and
// changes nothing.
//
// These assert the contract itself rather than any one consumer's use of it.

module Schema = Auth_ActiveRoleStore_Schema

describe("Auth_ActiveRoleStore_Schema.derivedStoreName", () => {
  testSync("names the store after the provider whose trigger reads it", () =>
    expect(Schema.derivedStoreName(~identityProviderId="eu-west-1_CQTwafSeX"))->toBe(
      "ReventlessActiveRoleStore-eu-west-1_CQTwafSeX",
    )
  )

  // The property the whole design turns on: two platforms on one provider cannot
  // name different stores, so the defect stops being something to detect and
  // becomes something that cannot be expressed.
  testSync("two deployments on one provider derive the same store", () =>
    expect(Schema.derivedStoreName(~identityProviderId="eu-west-1_Shared"))->toBe(
      Schema.derivedStoreName(~identityProviderId="eu-west-1_Shared"),
    )
  )

  testSync("different providers do not collide", () =>
    expect(
      Schema.derivedStoreName(~identityProviderId="eu-west-1_A") ==
        Schema.derivedStoreName(~identityProviderId="eu-west-1_B"),
    )->toBe(false)
  )

  // A pool id carries an underscore and a hyphen; DynamoDB accepts both, and a
  // name that needed escaping would make the script and the deploy disagree about
  // what "the same name" is.
  testSync("the derived name is a legal DynamoDB table name", () => {
    let name = Schema.derivedStoreName(~identityProviderId="eu-west-1_CQTwafSeX")
    expect((
      RegExp.test(RegExp.fromString("^[A-Za-z0-9_.-]+$"), name),
      name->String.length >= 3 && name->String.length <= 255,
    ))->toEqual((true, true))
  })
})

describe("Auth_ActiveRoleStore_Schema.keySchemaRefusal", () => {
  let store = "ReventlessActiveRoleStore-eu-west-1_x"

  testSync("the expected pair is adopted without complaint", () =>
    expect(
      Schema.keySchemaRefusal(~tableName=store, ~actual=[("id", "HASH"), ("clientId", "RANGE")]),
    )->toEqual(None)
  )

  // DescribeTable promises no ordering, and a refusal that depended on one would
  // reject a table that is perfectly correct.
  testSync("order is not part of the comparison", () =>
    expect(
      Schema.keySchemaRefusal(~tableName=store, ~actual=[("clientId", "RANGE"), ("id", "HASH")]),
    )->toEqual(None)
  )

  // 🚨 The upgrade case. A store keyed on the subject alone is what every
  // deployment had before the active role became per-platform, and adopting it
  // silently would write rows under a two-part key that nothing reads.
  testSync("the pre-clientId store is refused rather than adopted", () =>
    expect(
      Schema.keySchemaRefusal(~tableName=store, ~actual=[("id", "HASH")])->Option.isSome,
    )->toBe(true)
  )

  testSync("the refusal names the table, what it found, and what is needed", () => {
    let message = Schema.keySchemaRefusal(~tableName=store, ~actual=[("id", "HASH")])->Option.getOr("")
    expect((
      message->String.includes(store),
      message->String.includes("id:HASH"),
      message->String.includes("clientId:RANGE"),
    ))->toEqual((true, true, true))
  })

  testSync("a table keyed on something else entirely is refused", () =>
    expect(
      Schema.keySchemaRefusal(
        ~tableName=store,
        ~actual=[("pk", "HASH"), ("sk", "RANGE")],
      )->Option.isSome,
    )->toBe(true)
  )

  // Not a table anyone would build on purpose — but `DescribeTable`'s KeySchema is
  // optional in the SDK's types, and the caller resolves an absent one to this.
  testSync("an empty key schema is refused, not treated as a match", () =>
    expect(Schema.keySchemaRefusal(~tableName=store, ~actual=[])->Option.isSome)->toBe(true)
  )
})

open JestGlobals

// What the role check compares a plugin's roles with on AWS: the groups the user
// pool reports, found through the platform stack's exports.

module Cognito = AwsSdk.CognitoIdentityServiceProvider

let group = (name): Cognito.ListGroupsCommand.group => {groupName: name}

describe("Platform_ProvidedGroups.listAll", () => {
  test("follows NextToken until the last page", async () => {
    let seen = []
    let send = async (input: Cognito.ListGroupsCommand.input): Cognito.ListGroupsCommand.output => {
      seen->Array.push(input.nextToken)
      switch input.nextToken {
      | None => {groups: [group("Admin"), group("Shopper")], nextToken: "p2"}
      | Some(_) => {groups: [group("Merchandiser")]}
      }
    }
    let groups = await Platform_ProvidedGroups.listAll(~send, ~userPoolId="p1")
    expect((groups, seen))->toEqual((["Admin", "Shopper", "Merchandiser"], [None, Some("p2")]))
  })
})

describe("Platform_ProvidedGroups.poolFromExports", () => {
  let from = (pairs: array<(string, JSON.t)>) => {
    let exports = Dict.fromArray(pairs)
    Platform_ProvidedGroups.poolFromExports(~get=key => exports->Dict.get(key))
  }

  testSync("reads the pool id and region", () =>
    expect(
      from([
        ("identityProviderId", JSON.Encode.string("p1")),
        ("identityProviderRegion", JSON.Encode.string("eu-west-1")),
      ]),
    )->toEqual(Some({Platform_ProvidedGroups.id: "p1", region: Some("eu-west-1")}))
  )

  testSync("reads them nested under default, as an ESM platform exports them", () =>
    expect(
      from([
        (
          "default",
          JSON.Encode.object(Dict.fromArray([("cognitoUserPoolId", JSON.Encode.string("p-old"))])),
        ),
      ]),
    )->toEqual(Some({Platform_ProvidedGroups.id: "p-old", region: None}))
  )

  testSync("no pool id is no pool to list", () => expect(from([]))->toEqual(None))
})

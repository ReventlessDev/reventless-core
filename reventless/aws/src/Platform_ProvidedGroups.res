/***
The user pool's groups, read before a plugin is built so the role check compares
its roles with the pool, not a manifest (`Role.provideListedGroups`). A group the
pool lacks refuses every caller, which nothing at runtime can tell from a caller
without the role. Works in a preview: `ListGroups` is a read, and the pool id is
read outside any `Output.apply`.
*/

module Cognito = AwsSdk.CognitoIdentityServiceProvider

type pool = {id: string, region: option<string>}

type send = Cognito.ListGroupsCommand.input => promise<Cognito.ListGroupsCommand.output>

/** Every group of the pool, following `NextToken` across pages. */
let listAll = async (~send: send, ~userPoolId: string): array<string> => {
  let rec page = async (nextToken, acc) => {
    let out = await send({userPoolId, limit: 60, ?nextToken})
    let names = out.groups->Option.getOr([])->Array.filterMap(g => g.groupName)
    let acc = acc->Array.concat(names)
    switch out.nextToken {
    | Some(_) as next => await page(next, acc)
    | None => acc
    }
  }
  await page(None, [])
}

/** A plugin stack's pool, from the platform stack's exports. The new key before
    the old one, and each directly before under `default`, where ESM programs
    nest their exports. */
let poolFromExports = (~get: string => option<JSON.t>): option<pool> => {
  let nested = get("default")->Option.flatMap(JSON.Decode.object)
  let read = key =>
    get(key)
    ->Option.orElse(nested->Option.flatMap(d => d->Dict.get(key)))
    ->Option.flatMap(JSON.Decode.string)
  read("identityProviderId")
  ->Option.orElse(read("cognitoUserPoolId"))
  ->Option.map(id => {
    id,
    region: read("identityProviderRegion")->Option.orElse(read("cognitoRegion")),
  })
}

/**
The pool this program deploys against, or `None` where it cannot be listed yet:
a pool this program creates does not exist before its first deploy.

A plugin stack reads its platform stack's exports, the same ones its resolvers
use. A program that is its own platform reads a supplied pool's id from config.
*/
let resolvePool = async (~stackRef: option<Pulumi.StackReference.t>): option<pool> =>
  switch stackRef {
  | Some(stackRef) =>
    let keys = [
      "identityProviderId",
      "cognitoUserPoolId",
      "identityProviderRegion",
      "cognitoRegion",
      "default",
    ]
    let values = await Promise.all(
      keys->Array.map(key => stackRef->Pulumi.StackReference.getOutputValue(key)),
    )
    let exports = Dict.fromArray(
      keys->Array.mapWithIndex((key, i) => (key, values->Array.getUnsafe(i))),
    )
    poolFromExports(~get=key => exports->Dict.get(key)->Option.flatMap(v => v))
  | None =>
    Platform_Stack._identityProviderId(
      ~cfg=Pulumi.Config.make(Some("platform")),
    )->Option.map(id => {
      id,
      region: Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region"),
    })
  }

let sendTo = (~region: option<string>): send => {
  let client = Cognito.Raw.client(~options={region: ?region})
  input => Cognito.ListGroupsCommand.make(input)->Cognito.ListGroupsCommand.Raw.send(client, _)
}

/** List the pool's groups and record them for the role check. Leaves the check
    on its other sources where there is no pool to ask yet. */
let load = async (~stackRef: option<Pulumi.StackReference.t>): unit =>
  switch await resolvePool(~stackRef) {
  | None => ()
  | Some({id, region}) =>
    let groups = try await listAll(~send=sendTo(~region), ~userPoolId=id) catch {
    | exn if exn->Util_AwsError.hasCode(~code="AccessDeniedException") =>
      JsError.throwWithMessage(
        `Cannot list the groups of the user pool ${id}: the deploying principal needs ` ++ `cognito-idp:ListGroups on it, so the deploy can check that every role a plugin needs has a group.`,
      )
    }
    Reventless.Role.provideListedGroups(~source=`the user pool ${id}`, groups)
  }

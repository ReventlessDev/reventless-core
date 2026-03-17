// AppSync_Adapter — implements ReventlessInfra.Api_Adapter.Provider for AWS AppSync.
//
// Creates a new AppSync GraphQL API and IAM execution role.
// updateSchema uses the AWS AppSync SDK to push a stitched SDL whenever plugins connect.

open PulumiAws

// ── Inline AppSync SDK binding ─────────────────────────────────────────────

type appSyncClient

// AWS SDK v3 command pattern: client.send(new StartSchemaCreationCommand({...}))
type startSchemaCreationInput = {
  apiId: string,
  definition: unknown,
}

type startSchemaCreationCommand

@module("@aws-sdk/client-appsync") @new
external makeAppSyncClient: unit => appSyncClient = "AppSyncClient"

@module("@aws-sdk/client-appsync") @new
external makeStartSchemaCreationCommand: startSchemaCreationInput => startSchemaCreationCommand =
  "StartSchemaCreationCommand"

@send
external send: (appSyncClient, startSchemaCreationCommand) => promise<unknown> = "send"

let startSchemaCreation = (client: appSyncClient, input: startSchemaCreationInput) =>
  client->send(input->makeStartSchemaCreationCommand)

// Lazy singleton AppSync client (runtime only)
let _client: ref<option<appSyncClient>> = ref(None)
let getClient = () =>
  switch _client.contents {
  | Some(c) => c
  | None =>
    let c = makeAppSyncClient()
    _client.contents = Some(c)
    c
  }

// ── @aws_auth directive injection ─────────────────────────────────────────
// Injects @aws_auth(cognito_groups: [...]) directives into SDL field strings
// based on authorization metadata from schema entries.

let injectAwsAuth = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)

  // Build authorization lookup from mutation entries: fieldName -> group
  let mutationAuthMap: Dict.t<string> = Dict.make()
  mutationEntries->Array.forEach(entry => {
    switch entry.authorization {
    | Some({group}) =>
      entry.fieldNames->Array.forEach(fieldName =>
        mutationAuthMap->Dict.set(fieldName, group)
      )
    | None => ()
    }
  })

  // Build authorization lookup from query entries: fieldName -> group
  let queryAuthMap: Dict.t<string> = Dict.make()
  queryEntries->Array.forEach(entry => {
    switch entry.authorization {
    | Some({group}) =>
      queryAuthMap->Dict.set(entry.singleFieldName, group)
      queryAuthMap->Dict.set(entry.listFieldName, group)
    | None => ()
    }
  })

  let augmentedMutations = parts.mutations->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    switch mutationAuthMap->Dict.get(fieldName) {
    | Some(group) => `${field}\n    @aws_auth(cognito_groups: ["${group}"])`
    | None => field
    }
  })

  let augmentedQueries = parts.queries->Array.map(field => {
    let fieldName = ReventlessCore.GraphQL_Stitcher.extractLeadingName(field)
    switch queryAuthMap->Dict.get(fieldName) {
    | Some(group) => `${field} @aws_auth(cognito_groups: ["${group}"])`
    | None => field
    }
  })

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(augmentedMutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(augmentedQueries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}

// Injects @aws_auth with the given group on ALL mutation and query fields in a fragment.
// Used for the base fragment where all fields share the same authorization group.
let injectAwsAuthAll = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  ~group: string,
): Reventless.Plugin.apiSchemaFragment => {
  let parts = ReventlessCore.GraphQL_Stitcher.decode(fragment)

  let augmentedMutations = parts.mutations->Array.map(field =>
    `${field}\n    @aws_auth(cognito_groups: ["${group}"])`
  )
  let augmentedQueries = parts.queries->Array.map(field =>
    `${field} @aws_auth(cognito_groups: ["${group}"])`
  )

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(augmentedMutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(augmentedQueries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}

// ── Provider implementation ────────────────────────────────────────────────

type api = AppSync.GraphQLApi.t
type role = IAM.Role.t

let makeApiResource = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
): (Pulumi.Output.t<api>, Pulumi.Output.t<role>) => {
  let customOpts: Pulumi.CustomResourceOptions.t = {
    parent: ?opts.parent,
  }

  // Create IAM role for AppSync
  let iamRole = IAM.Role.make(
    ~name=`${name}-appsync-role`,
    ~args={
      assumeRolePolicy: `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"appsync.amazonaws.com"},"Action":"sts:AssumeRole"}]}`
        ->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )

  // Create the AppSync GraphQL API (schema pushed at runtime via updateSchema)
  let graphQLApi = AppSync.GraphQLApi.make(
    ~name,
    ~args={
      AppSync.GraphQLApi.authenticationType: AppSync.GraphQLApi.AWS_IAM->Pulumi.Input.make,
      name: name->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )

  (graphQLApi->Pulumi.Output.make, iamRole->Pulumi.Output.make)
}

let generateFragment = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): Reventless.Plugin.apiSchemaFragment => {
  let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
  injectAwsAuth(fragment, ~mutationEntries, ~queryEntries)
}

let updateSchema = (
  ~api: Pulumi.Output.t<api>,
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): promise<unit> => {
  // Inject @aws_auth(cognito_groups: ["Admin"]) into all base fragment fields.
  // The base fragment contains core Plugin aggregate queries/mutations — all Admin-only.
  // Plugin fragments already have @aws_auth injected via generateFragment.
  let augmentedBaseFragment = injectAwsAuthAll(baseFragment, ~group="Admin")
  let sdl = ReventlessCore.GraphQL_Stitcher.stitch(~baseFragment=augmentedBaseFragment, ~pluginFragments)
  // Resolve the API ID from the Output chain. In mock mode (tests) and in Lambda runtime
  // (where the Output is backed by already-known values), this completes synchronously.
  // The resulting promise wraps the AppSync SDK call.
  let resultPromise: ref<promise<unit>> = ref(Promise.resolve())
  let _ =
    api
    ->Pulumi.Output.apply(graphQLApi =>
      graphQLApi.id->Pulumi.Output.apply(apiId => {
        let definition: unknown = sdl->Obj.magic
        let p =
          getClient()
          ->startSchemaCreation({apiId, definition})
          ->Promise.then(_ => Promise.resolve())
        resultPromise.contents = p
      })
    )
  resultPromise.contents
}

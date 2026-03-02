// AppSync_Adapter — implements ReventlessInfra.Api_Adapter.Provider for AWS AppSync.
//
// Creates a new AppSync GraphQL API and IAM execution role.
// updateSchema uses the AWS AppSync SDK to push a stitched SDL whenever plugins connect.

open PulumiAws

// ── Inline AppSync SDK binding ─────────────────────────────────────────────

type appSyncClient

// AppSync SDK accepts string | Uint8Array for definition — use string via Obj.magic
type startSchemaCreationInput = {
  apiId: string,
  definition: unknown,
}

@module("@aws-sdk/client-appsync") @new
external makeAppSyncClient: unit => appSyncClient = "AppSyncClient"

@send
external startSchemaCreation: (
  appSyncClient,
  startSchemaCreationInput,
) => promise<unknown> = "startSchemaCreation"

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
): Reventless.Plugin.apiSchemaFragment =>
  ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)

let updateSchema = (
  ~api: Pulumi.Output.t<api>,
  ~baseFragment: Reventless.Plugin.apiSchemaFragment,
  ~pluginFragments: array<Reventless.Plugin.apiSchemaFragment>,
): promise<unit> => {
  let sdl = ReventlessCore.GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)
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

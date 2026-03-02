// Api_Builder — creates the Api component backed by a Provider (AppSync / in-memory yoga).
//
// Usage:
//   module AwsApi = Api_Builder.Make(AppSync_Adapter)
//   let api = AwsApi.make(~name="MyApi", ~baseFragment, ~opts)

module Make = (Provider: ReventlessInfra.Api_Adapter.Provider) => {
  let construct = (~name, ~baseFragment: Reventless.Plugin.apiSchemaFragment, self) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let (api, _role) = Provider.makeApiResource(~name, ~opts)

    // Outputs — the cloud API ID
    let apiId = api->Pulumi.Output.apply(a => (a->Obj.magic)["id"]->Option.getOr(name))
    let _ = self->Component.setOutputs({ReventlessInfra.Api.apiId: apiId})

    // Operations — updateSchema rebuilds the stitched SDL and publishes it
    self->Component.setOperations(
      api->Pulumi.Output.apply(apiValue => {
        ReventlessInfra.Api.updateSchema: pluginFragments =>
          Provider.updateSchema(
            ~api=Pulumi.Output.make(apiValue),
            ~baseFragment,
            ~pluginFragments,
          ),
      }),
    )
  }

  let make = (
    ~name: string,
    ~baseFragment: Reventless.Plugin.apiSchemaFragment,
    ~opts: option<Pulumi.ComponentResource.options>=?,
  ): ReventlessInfra.Api.component =>
    Component.make(
      ~componentType="reventless:index:Api",
      ~name,
      ~construct=construct(~name, ~baseFragment, ...),
      ~opts,
    )
}

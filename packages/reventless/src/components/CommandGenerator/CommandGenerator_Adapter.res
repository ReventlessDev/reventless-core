type resolvers = {resources: array<ReventlessSpec.Adapter.resource>}

type resolversMaker<'api> = (
  ~name: string,
  ~api: 'api,
  ~fields: array<string>,
  ~commandGenerator: CommandGenerator_Callback.commandGenerator,
  ~opts: Pulumi.CustomResourceOptions.t,
) => resolvers

module type Resolvers = {
  type api

  let make: resolversMaker<api>
}

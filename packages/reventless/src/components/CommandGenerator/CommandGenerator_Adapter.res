type resolvers = {resources: array<ReventlessSpec.Adapter.resource>}

type resolversMaker<'api> = (
  ~name: string,
  ~api: 'api,
  ~fields: array<string>,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.CustomResourceOptions.t,
) => resolvers

module type Resolvers = {
  type api

  let makeHandler: CommandGenerator.commandGenerator => Pulumi.Output.t<
    Runtime.eventHandler<CommandGenerator.payload, 'context, string>,
  >

  let make: resolversMaker<api>
}

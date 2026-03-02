type resolvers = {resources: array<ReventlessInfra.Adapter.resource>}

type resolversMaker<'api, 'runtimeParts> = (
  ~name: string,
  ~api: 'api,
  ~fields: array<string>,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~resources: array<ReventlessInfra.Adapter.resource>,
  ~opts: Pulumi.ComponentResource.options,
) => resolvers

module type Resolvers = {
  type api
  type runtimeParts

  let handleResolversEvent: CommandGenerator.commandGenerator => Pulumi.Output.t<
    Runtime.eventHandler<CommandGenerator.payload, 'context, string>,
  >

  let make: resolversMaker<api, runtimeParts>
}

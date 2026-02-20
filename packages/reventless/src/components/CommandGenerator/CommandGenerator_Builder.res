module Make = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  Resolvers: CommandGenerator_Adapter.Resolvers,
): (CommandGenerator.T with type runtimeParts := Resolvers.runtimeParts and type api := Resolvers.api) => {
  let construct = (self, _name) => {
    let resources = Behavior.resolverConfig.fields->Array.map(field => {
      ReventlessSpec.Adapter.id: ""->Pulumi.Output.make,
      info: `Mutation.${field}`->Pulumi.Output.make,
      name: ""->Pulumi.Output.make,
      urn: ""->Pulumi.Output.make,
      service: ""->Pulumi.Output.make,
    })
    let _ = self->Component.setOutputs({CommandGenerator.resources: resources})
  }

  let connect = (~api: Resolvers.api, ~resources, ~runtime, commandGenerator) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let name =
      commandGeneratorResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(CommandGenerator.componentType)
    let opts = {Pulumi.ComponentResource.parent: commandGeneratorResource}

    let resolvers = Resolvers.make(
      ~name,
      ~api,
      ~fields=Behavior.resolverConfig.fields,
      ~runtime,
      ~resources,
      ~opts,
    )

    let _ =
      commandGenerator->Component.setOutputs({CommandGenerator.resources: resolvers.resources})
  }

  let makeHandler = (~publishJsons) => {
    module Callback = CommandGenerator_Callback.Make(
      {
        let publishJsons = publishJsons
      },
      Spec,
      Behavior,
    )

    Resolvers.handleResolversEvent(Callback.generateCommand)
  }

  let make = (~name, ~opts=?): CommandGenerator.component =>
    Component.make(
      ~componentType=CommandGenerator.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}

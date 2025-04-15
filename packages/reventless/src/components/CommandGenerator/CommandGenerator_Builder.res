module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  Resolvers: CommandGenerator_Adapter.Resolvers with type api := Config.api,
): (CommandGenerator.T with type runtimeParts := Resolvers.runtimeParts) => {
  let construct = (_self, _name) => ()

  let connect = (~resources, ~runtime, commandGenerator) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let name =
      commandGeneratorResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(CommandGenerator.componentType)
    let opts = {Pulumi.ComponentResource.parent: commandGeneratorResource}

    let resolvers = Resolvers.make(
      ~name,
      ~api=Config.api,
      ~fields=Behaviour.resolverConfig.fields,
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
      Behaviour,
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

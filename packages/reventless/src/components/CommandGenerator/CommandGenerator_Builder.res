module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  Resolvers: CommandGenerator_Adapter.Resolvers with type api := Config.api,
): CommandGenerator.T => {
  let construct = (self, name, ~api, ~runtime) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let resolvers = Resolvers.make(
      ~name=name->ComponentType.name(CommandGenerator.componentType),
      ~api,
      ~fields=Behaviour.resolverConfig.fields,
      ~runtime,
      ~opts,
    )

    self->Component.setOutputs({CommandGenerator.resources: resolvers.resources})
  }

  let makeHandler = (~publishJsons) => {
    module Callback = CommandGenerator_Callback.Make(
      {
        let publishJsons = publishJsons
      },
      Spec,
      Behaviour,
    )

    Resolvers.makeHandler(Callback.generateCommand)
  }

  let make = (~name, ~runtime, ~opts=?): CommandGenerator.component =>
    Component.make(
      ~componentType=CommandGenerator.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~api=Config.api, ~runtime, ...),
      ~opts
    )
}

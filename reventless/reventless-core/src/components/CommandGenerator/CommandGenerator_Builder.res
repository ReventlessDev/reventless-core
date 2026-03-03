module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  Resolvers: CommandGenerator_Adapter.Resolvers,
): (
  CommandGenerator.T with type runtimeParts := Resolvers.runtimeParts and type api := Resolvers.api
) => {
  let construct = (self, _name) => {
    let resources = Behavior.resolverConfig.fields->Array.map(field => {
      let r: ReventlessInfra.Adapter.resource = {
        id: ""->Pulumi.Output.make,
        info: `Mutation.${field}`->Pulumi.Output.make,
        name: ""->Pulumi.Output.make,
        urn: ""->Pulumi.Output.make,
        service: ""->Pulumi.Output.make,
      }
      r
    })
    let outputs: CommandGenerator.outputs = {resources: resources}
    let _ = self->Component.setOutputs(outputs)
  }

  let connect = (~api: Resolvers.api, ~resources, ~runtime, commandGenerator) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let name =
      commandGeneratorResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(CommandGenerator.componentType)
    let opts = {Pulumi.ComponentResource.parent: commandGeneratorResource}

    // Use plugin-prefixed field names from registry when available;
    // fall back to Behavior.resolverConfig.fields for backward compat.
    let fields = switch Plugin_Helpers.aggregateMutationFieldsRegistry.contents->Dict.get(Spec.name) {
    | Some(registeredFields) if registeredFields->Array.length > 0 => registeredFields
    | _ => Behavior.resolverConfig.fields
    }

    let resolvers = Resolvers.make(
      ~name,
      ~api,
      ~fields,
      ~commandSchema=Behavior.resolverConfig.commandSchema->S.castToUnknown,
      ~runtime,
      ~resources,
      ~opts,
    )

    let cgOutputs: CommandGenerator.outputs = {resources: resolvers.resources}
    let _ = commandGenerator->Component.setOutputs(cgOutputs)
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

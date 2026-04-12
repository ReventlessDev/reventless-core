module Make = (
  Spec: Reventless.Aggregate.Spec,
  Resolvers: CommandGenerator_Adapter.Resolvers,
): (
  CommandGenerator.T with type runtimeParts := Resolvers.runtimeParts and type api := Resolvers.api
) => {
  let construct = (self, _name) => {
    let resources = Plugin_Helpers.aggregateMutationFieldsRegistry.contents->Dict.get(Spec.name)->Option.getOr([])->Array.map(field => {
      let r: ReventlessInfra.Adapter.resource = {
        id: ""->Pulumi.Output.make,
        resourceInfo: ReventlessInfra.Adapter.ApiResolver({typeName: "Mutation", fieldName: field})->Pulumi.Output.make,
        name: ""->Pulumi.Output.make,
        urn: ""->Pulumi.Output.make,
        service: ""->Pulumi.Output.make,
        role: "commandGenerator"->Pulumi.Output.make,
        region: ""->Pulumi.Output.make,
        resourceType: ""->Pulumi.Output.make,
        configuration: Dict.make()->Pulumi.Output.make,
        tags: Dict.make()->Pulumi.Output.make,
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

    let fields = Plugin_Helpers.aggregateMutationFieldsRegistry.contents->Dict.get(Spec.name)->Option.getOr([])

    let resolvers = Resolvers.make(
      ~name,
      ~api,
      ~fields,
      ~commandSchema=Spec.commandSchema->S.castToUnknown,
      ~runtime,
      ~resources,
      ~opts,
    )

    let cgOutputs: CommandGenerator.outputs = {resources: resolvers.resources}
    let _ = commandGenerator->Component.setOutputs(cgOutputs)
  }

  let makeHandler = (~publishJsons, ~publishJsonsAndWait: option<CommandTopic.publishJsonsAndWait>) => {
    module Callback = CommandGenerator_Callback.Make(
      {
        let publishJsons = publishJsons
        let publishJsonsAndWait = publishJsonsAndWait
      },
      Spec,
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

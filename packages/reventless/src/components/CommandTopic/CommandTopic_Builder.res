module Make = (Spec: CommandTopic.Spec, Connector: CommandTopic_Adapter.Connector): (
  CommandTopic.T with module Spec = Spec
) => {
  module Spec = Spec

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>
  type operations = {publish: publish, publishJsons: CommandTopic.publishJsons}
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  let construct = (self, name, ~commandsHandler, ~memorySize, ~timeout) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    module CallbackOps = {
      module Spec = Spec
      let commandsHandler = commandsHandler
    }
    module Callback = CommandTopicConnector_Runtime.Make(Spec, CallbackOps)
    let connector = Connector.make(
      ~name=name->ComponentType.name(CommandTopic.componentType),
      ~handleCommands=Callback.handleCommands,
      ~memorySize,
      ~timeout,
      ~opts,
    )

    self->Component.setOperations(
      connector.publishJsons->Pulumi.Output.apply(publishJsons => {
        module Ops = {
          let publishJsons = publishJsons
        }
        module Runtime = CommandTopic_Runtime.Make(Spec, Ops)

        {
          publish: Runtime.publish,
          publishJsons: Runtime.publishJsons,
        }
      }),
    )

    self->Component.setOutputs({CommandTopic.resources: connector.resources})
  }

  let make = (~name, ~commandsHandler, ~memorySize=1024, ~timeout=30, ~opts=?): component =>
    Component.make(
      ~componentType=CommandTopic.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~commandsHandler, ~memorySize, ~timeout, ...),
      ~opts,
    )
}

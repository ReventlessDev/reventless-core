module Make = (
  Spec: CommandTopic.Spec,
  Channel: CommandTopic_Adapter.Channel,
  RuntimeEnvironment: Runtime.Environment,
): (CommandTopic.T with module Spec = Spec) => {
  module Spec = Spec

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>
  type operations = {publish: publish, publishJsons: CommandTopic.publishJsons}
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  let construct = (self, name, ~channel: CommandTopic.channel, ~commandsHandler) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    module CallbackOps = {
      module Spec = Spec
      let commandsHandler = commandsHandler
    }
    module Callback = CommandTopic_Callback.Make(Spec, CallbackOps)

    let runtime = RuntimeEnvironment.make(
      ~name,
      ~channelResources=channel.resources,
      ~handleJsons=Callback.handleJsonCommands,
      ~opts,
    )

    self->Component.setOperations(
      channel.publishJsons->Pulumi.Output.apply(publishJsons => {
        module Ops = {
          let publishJsons = publishJsons
        }
        module Operations = CommandTopic_Operations.Make(Spec, Ops)

        {
          publish: Operations.publish,
          publishJsons: Operations.publishJsons,
        }
      }),
    )

    self->Component.setOutputs({
      CommandTopic.resources: channel.resources->Array.concat(runtime.resources),
    })
  }

  let makeChannel = (~name, ~opts=?): CommandTopic.channel => {
    let name = name->ComponentType.name(CommandTopic.componentType)
    Channel.make(~name, ~opts?)
  }

  let make = (~name, ~channel, ~commandsHandler, ~opts=?): component =>
    Component.make(
      ~componentType=CommandTopic.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~channel, ~commandsHandler, ...),
      ~opts,
    )
}

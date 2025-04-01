module Make = (Spec: CommandTopic.Spec, Channel: CommandTopic_Adapter.Channel): (
  CommandTopic.T with module Spec = Spec and type callbackEvent = Channel.callbackEvent
) => {
  module Spec = Spec
  type callbackEvent = Channel.callbackEvent

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: CommandTopic.publishJsons,
  }
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(CommandTopic.componentType)

    let channel = Channel.make(~name, ~opts)
    self->CommandTopic_Adapter.setChannel(channel)

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
      CommandTopic.resources: channel.resources,
    })
  }

  let connect = (~name, ~commandTopic, ~runtime, ~resources, ~opts) => {
    let name = name->ComponentType.name(CommandTopic.componentType)
    let channel = commandTopic->CommandTopic_Adapter.channel

    let subscribeResources = channel.connect(~name, ~channel, ~runtime, ~resources, ~opts)

    // let _ = commandTopic->Component.setOutputs({
    //   CommandTopic.resources: channel.resources->Belt.Array.concat(subscribeResources),
    // })
  }

  let makeHandler = (~commandTopic, ~commandsHandler: commandsHandler) => {
    let channel = commandTopic->CommandTopic_Adapter.channel
    module CallbackOps = {
      module Spec = Spec
      let commandsHandler = commandsHandler
    }
    module Callback = CommandTopic_Callback.Make(Spec, CallbackOps)

    channel.handleChannelEvent(Callback.handleJsonCommands)
  }

  let make = (~name, ~opts=?): component =>
    Component.make(
      ~componentType=CommandTopic.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}

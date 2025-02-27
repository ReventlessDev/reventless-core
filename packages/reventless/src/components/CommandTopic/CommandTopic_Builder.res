module Make = (Spec: CommandTopic.Spec, Channel: CommandTopic_Adapter.Channel): (
  CommandTopic.T with module Spec = Spec and type callbackEvent = Channel.callbackEvent
) => {
  module Spec = Spec
  type callbackEvent = Channel.callbackEvent
  type channel<'context> = CommandTopic.channel<callbackEvent, 'context>

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: CommandTopic.publishJsons,
  }
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  let construct = (self, name, ~channel: channel<'context>, ~runtime) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(CommandTopic.componentType)

    let subscribeResources = channel.subscribe(~name, ~channel, ~runtime, ~opts)

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
      CommandTopic.resources: channel.resources->Belt.Array.concat(subscribeResources),
    })
  }

  let makeChannel = (~name, ~opts=?): channel<'context> => {
    let name = name->ComponentType.name(CommandTopic.componentType)
    Channel.make(~name, ~opts?)
  }

  let makeHandler = (~channel: channel<'context>, ~commandsHandler: commandsHandler) => {
    module CallbackOps = {
      module Spec = Spec
      let commandsHandler = commandsHandler
    }
    module Callback = CommandTopic_Callback.Make(Spec, CallbackOps)

    channel.handleChannelEvent(Callback.handleJsonCommands)
  }

  let make = (~name, ~channel, ~runtime, ~opts=?): component =>
    Component.make(
      ~componentType=CommandTopic.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~channel, ~runtime, ...),
      ~opts,
    )
}

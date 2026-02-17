module Make = (
  Spec: CommandHandler.Spec,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
): (CommandHandler.T with type dcbEvent = Spec.DcbEventLogSpec.event and module Spec = Spec) => {
  type dcbEvent = Spec.DcbEventLogSpec.event
  module Spec = Spec

  module CommandTopicSpec = {
    module Id = ReventlessSpec.Id.String
    @schema
    type command = Spec.command
  }

  module SpecificCommandTopic = CommandTopic_Builder.Make(CommandTopicSpec, CommandTopicChannel)

  let construct = (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    self,
    name,
  ) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(CommandHandler.componentType)

    let commandTopic =
      dcbEventLog
      ->Component.operations
      ->Pulumi.Output.apply(dcbEventLogOps => {
        module Callback = CommandHandler_Callback.Make(
          Spec,
          {
            module Spec = Spec
            let dcbEventLog = dcbEventLogOps
          },
        )
        let commandTopic = SpecificCommandTopic.make(
          ~name,
          ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
        )
        let _handler = SpecificCommandTopic.makeHandler(
          ~commandTopic,
          ~commandsHandler=Callback.handleCommands,
        )
        commandTopic
      })

    self->Component.setOperations(
      commandTopic->Pulumi.Output.flatMap(commandTopic =>
        commandTopic
        ->Component.operations
        ->Pulumi.Output.apply(({publishJsons}) => {CommandHandler.publishJsons: publishJsons})
      ),
    )
    self->Component.setOutputs({
      CommandHandler.resources: (dcbEventLog->Component.outputs).resources,
      commandTopic: commandTopic->Component.wrappedOutputs,
    })
  }

  let make = (~dcbEventLog, ~opts=?): CommandHandler.component =>
    Component.make(
      ~componentType=CommandHandler.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~dcbEventLog, ...),
      ~opts,
    )
}

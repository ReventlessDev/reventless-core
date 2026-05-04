module type T = {
  type context
  type runtimeParts
  module CommandTopicChannel: CommandTopic_Adapter.Channel

  let forCommandTopic: (
    ~handler: Pulumi.Output.t<
      Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit, string>,
    >,
    ~connect: Runtime.connect<runtimeParts>,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~specModulePath: string,
    ~mappingsModulePath: string,
    ~publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
    CommandTopic.component<'op>,
  ) => unit
}

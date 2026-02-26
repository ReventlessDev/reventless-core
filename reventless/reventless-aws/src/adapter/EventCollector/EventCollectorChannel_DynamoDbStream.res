type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = unit
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
  ~name,
  ~channelSpecs: array<
    ReventlessCore.EventCollector_Adapter.channelSpec<callbackEvent, 'context, channelParts>,
  >,
  ~runtime: ReventlessCore.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  open EventCollectorChannel_Helpers

  let queues = []
  let eventTopics =
    channelSpecs->Array.reduce(Dict.make(), (acc, {eventTopics}) => acc->Dict.assign(eventTopics))
  let resources = channelSpecs->Array.map(({resources}) => resources)->Array.flat

  lambda->connectLambda(name, lambdaRole, queues, eventTopics, resources, opts)
}

let make: ReventlessCore.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name as _,
  ~eventTopics,
  ~opts as _,
) => {
  let eventTopicResources =
    eventTopics
    ->Dict.valuesToArray
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0)) // FIXME

  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Console.log4(
      __MODULE__ ++ " supports no enqueueEvent:",
      delay,
      id,
      messageBody,
    )->Promise.resolve

  let handleChannelEvent = handleEvents =>
    EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...)->Pulumi.Output.make

  {
    ReventlessCore.EventCollector_Adapter.parts: (),
    resources: eventTopicResources,
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    handleChannelEvent,
  }
}

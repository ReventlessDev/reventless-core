type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = unit
type runtimeParts = Util.Lambda.runtimeParts

let connect = (
  ~name,
  ~channelSpecs: array<
    Reventless.EventCollector_Adapter.channelSpec<callbackEvent, 'context, channelParts>,
  >,
  ~runtime: Reventless.Runtime.environment<runtimeParts>,
  ~opts,
) => {
  let opts = opts->Reventless.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions

  let lambda = runtime.parts.lambda
  let lambdaRole = runtime.parts.lambdaRole

  open EventCollectorChannel_Helpers

  let queues = []
  let eventTopics =
    channelSpecs->Array.reduce(Js.Dict.empty(), (acc, {eventTopics}) =>
      acc->Dict.assign(eventTopics)
    )
  let resources = channelSpecs->Array.map(({resources}) => resources)->Array.flat

  lambda->connectLambda(name, lambdaRole, queues, eventTopics, resources, opts)
}

let make: Reventless.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
  ~name as _,
  ~eventTopics,
  ~opts as _,
) => {
  let eventTopicResources =
    eventTopics
    ->Js.Dict.values
    ->Array.map(outputs => outputs.resources->Array.getUnsafe(0)) // FIXME

  let enqueueEventNotSupported = (delay, id, messageBody) =>
    // TODO: can we check this at deploy time ?
    Js.log4(__MODULE__ ++ " supports no enqueueEvent:", delay, id, messageBody)->Js.Promise.resolve

  let handleChannelEvent = handleEvents =>
    (EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...))->Pulumi.Output.make

  {
    Reventless.EventCollector_Adapter.parts: (),
    resources: eventTopicResources,
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    handleChannelEvent,
  }
}

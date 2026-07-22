type callbackEvent = PulumiAws.Lambda.CallbackFunction.event
type channelParts = unit
type runtimeParts = Util.Lambda.runtimeParts

let log = ReventlessCore.Logger.fromEnv()

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
  ~owner as _, ~opts as _,
) => {
  // Postgres-backed event logs have NO storage resources (no table, no stream) —
  // skip them instead of producing undefined entries; their events arrive via the
  // PgProjectionFeed SQS queue (B3.0), not a stream ESM.
  let eventTopicResources =
    eventTopics
    ->Dict.valuesToArray
    ->Array.filterMap(outputs => outputs.resources->Array.get(0))

  let enqueueEventNotSupported = (delay, id, messageBody) => {
    // TODO: can we check this at deploy time ?
    log.debug(
      ~comp="EventCollectorChannel_DynamoDbStream",
      ~data=Dict.fromArray([
        ("delay", delay->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string),
        ("id", id->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string),
        ("messageBody", messageBody->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string),
      ])->JSON.Encode.object,
      "supports no enqueueEvent",
    )
    Promise.resolve()
  }

  let handleChannelEvent = handleEvents =>
    EventCollectorChannel_SQS_Runtime.handleDynamoDbEvent(handleEvents, ...)->Pulumi.Output.make

  {
    ReventlessCore.EventCollector_Adapter.parts: (),
    resources: eventTopicResources,
    enqueueEvent: enqueueEventNotSupported->Pulumi.Output.make,
    handleChannelEvent,
  }
}

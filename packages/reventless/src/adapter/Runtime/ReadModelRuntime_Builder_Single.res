module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (
  ReadModelRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module EventCollectorChannel = EventCollectorChannel

  type runtimeSpec = {
    readModel: Pulumi.Resource.t,
    connects: array<Runtime.connect<runtimeParts>>,
    memorySize: int,
    timeout: int,
  }

  let readModelRuntimeSpecs = Js.Dict.empty()
  let eventCollectorHandlers = Js.Dict.empty()

  let readModelHandler = readModelName => async (event: RuntimeEnvironment.event, context) => {
    let desc = `readModelHandler for ${readModelName}:`
    let _ =
      await event
      ->RuntimeEnvironment.groupBySource
      ->Dict.toArray
      ->Array.map(async ((urn, event)) => {
        switch eventCollectorHandlers->Js.Dict.get(urn) {
        | Some(handler) =>
          Js.log2(`----- ${desc} found handler for eventCollector`, urn)
          await handler(event, context)
        | None => Js.log2(`${desc} no handler found:`, urn)
        }
      })
      ->Promise.all
  }

  let registerRuntimeSpec = (~connect, ~memorySize, ~timeout, readModel: Pulumi.Resource.t) => {
    let readModelName = readModel.name->Option.getOr("Unnamed")
    let spec =
      readModelRuntimeSpecs
      ->Dict.get(readModelName)
      ->Option.getOr({readModel, connects: [], memorySize: 0, timeout: 0})
    readModelRuntimeSpecs->Dict.set(
      readModelName,
      {
        readModel,
        connects: spec.connects->Array.concat([connect]),
        memorySize: Math.Int.max(spec.memorySize, memorySize),
        timeout: Math.Int.max(spec.timeout, timeout),
      },
    )
  }

  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector: EventCollector.component,
  ) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")
    switch eventCollectorResource.parent {
    | Some(readModelResource) =>
      readModelResource->registerRuntimeSpec(~connect, ~memorySize, ~timeout)
      let urns =
        (eventCollector->Component.outputs).resources
        ->Array.map(({urn}) => urn)
        ->Pulumi.Output.all
      let _ =
        (urns, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urns, handler)) => {
          Js.log2(`***** forEventCollector ${eventCollectorName}: set handler for`, urns)
          urns->Array.map(urn =>
            eventCollectorHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
          )
        })
    | None =>
      Js.Exn.raiseError(
        `forEventCollector: eventCollector ${eventCollectorName} has no ReadModel parent`,
      )
    }
  }

  let finished = ref(false)

  let finish = () =>
    if !finished.contents {
      let specs = readModelRuntimeSpecs->Dict.valuesToArray
      let (parent, memorySize, timeout) = specs->Array.reduce((None, 0, 0), (
        (_, accMemorySize, accTimeout),
        {readModel, memorySize, timeout},
      ) => {
        (
          readModel.parent,
          Math.Int.max(accMemorySize, memorySize),
          Math.Int.max(accTimeout, timeout),
        )
      })
      switch parent {
      | Some(parent) =>
        let runtime = RuntimeEnvironment.make(
          ~name="AllReadModels",
          ~handler=readModelHandler("AllReadModels")->Pulumi.Output.make,
          ~memorySize,
          ~timeout,
          ~opts={Pulumi.ComponentResource.parent: parent},
        )
        let _ = specs->Array.map(({connects}) => {
          connects->Array.forEach(connect => connect(~runtime))
        })
      | None => ()
      }
      finished := true
    }
}

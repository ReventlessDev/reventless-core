// In-memory EventCollector channel.
// connect subscribes to all event topics in the bus using the resource name as topic key.
// Each published event awaits the handler Deferred before delivery — eliminating the race
// where consumers see None and silently drop events.
// The runtime's subscriptionLatch is opened after each subscription is registered so
// callers can await it to know subscriptions are ready before publishing.

module Make = (Bus: InMemory_Bus.T) => {
  type callbackEvent = JSON.t
  type channelParts = unit
  type runtimeParts = RuntimeEnvironment_InMemory.parts

  let make: ReventlessCore.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
    ~name as _,
    ~eventTopics,
    ~opts as _,
  ) => {
    // Collect all event topic resources as our channel resources
    let eventTopicResources =
      eventTopics
      ->Dict.valuesToArray
      ->Array.flatMap((outputs: ReventlessCore.EventTopic.outputs) => outputs.resources)

    {
      parts: (),
      resources: eventTopicResources,
      enqueueEvent: ((_, _, _) => Promise.resolve())->Pulumi.Output.make,
      handleChannelEvent: (handleEvents: ReventlessCore.EventCollector.jsonEventsHandler) =>
        ((json: JSON.t, _ctx) => handleEvents([json]))->Pulumi.Output.make,
    }
  }

  let connect: ReventlessCore.EventCollector_Adapter.connect<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  > = (~name as _, ~channelSpecs, ~runtime, ~opts as _) => {
    channelSpecs->Array.forEach(({eventTopics}: ReventlessCore.EventCollector_Adapter.channelSpec<
      callbackEvent,
      'context,
      channelParts,
    >) => {
      eventTopics
      ->Dict.valuesToArray
      ->Array.forEach((topicOutputs: ReventlessCore.EventTopic.outputs) => {
        topicOutputs.resources->Array.forEach(resource => {
          // resource.name is the bus topic key set by EventTopicPublisher_InMemory
          let _ = resource.name->Pulumi.Output.apply(topicName => {
            Bus.subscribeToEvents(topicName, async (_service, _meta, json) => {
              let handler =
                await runtime.parts.handlerDeferred->Deferred.await_->Effect.runPromise
              await handler(json, ())
            })
            // Signal that this topic's subscription is registered.
            // Latch.open_ is idempotent — calling it for multiple topics is safe.
            runtime.parts.subscriptionLatch->Latch.open_->Effect.runPromise->ignore
          })
        })
      })
    })
    []
  }
}

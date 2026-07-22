// In-memory EventCollector channel.
// connect subscribes to all event topics in the bus using the resource name as topic key.
// Each published event awaits the handler Deferred before delivery — eliminating the race
// where consumers see None and silently drop events.
// The runtime's subscriptionLatch is opened after each subscription is registered so
// callers can await it to know subscriptions are ready before publishing.

module Make = (Bus: LocalBus.T) => {
  type callbackEvent = JSON.t
  type channelParts = unit
  type runtimeParts = LocalRuntimeEnvironment.parts

  let make: ReventlessCore.EventCollector_Adapter.channelMaker<callbackEvent, 'context, channelParts> = (
    ~name as _,
    ~eventTopics,
    ~owner as _, ~opts as _,
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
        ((json: JSON.t, _ctx) =>
          handleEvents(Stream.fromIterable([json]))->Effect.map(_ => ())
        )->Pulumi.Output.make,
    }
  }

  let connect: ReventlessCore.EventCollector_Adapter.connect<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  > = (~name, ~channelSpecs, ~runtime, ~opts as _) => {
    // Register handler in Bus once resolved — allows makePlatform to wire cross-plugin
    // Extension → EP EventTopic subscriptions after all plugins are built.
    let _reg =
      runtime.parts.handlerDeferred
      ->Deferred.await_
      ->Effect.flatMap(handler => Effect.sync(() => Bus.registerEventCollectorHandler(name, handler)))
      ->Effect.runPromise
      ->ignore

    channelSpecs->Array.forEach(({eventTopics}: ReventlessCore.EventCollector_Adapter.channelSpec<
      callbackEvent,
      'context,
      channelParts,
    >) => {
      eventTopics
      ->Dict.valuesToArray
      ->Array.forEach((topicOutputs: ReventlessCore.EventTopic.outputs) => {
        topicOutputs.resources->Array.forEach(resource => {
          // resource.name is the bus topic key set by LocalEventTopicPublisher
          let _ = resource.name->Pulumi.Output.apply(topicName => {
            // Stream-based drain: subscribeToEventStream returns a scoped Effect that
            // yields Stream<queuedEvent>. done_ is run explicitly after each handler call
            // to unblock publishEvent.
            let drainEffect = Effect.scoped(
              Bus.subscribeToEventStream(topicName)
              ->Effect.flatMap(stream =>
                stream->Stream.runForEach(msg =>
                  Effect.promise(async () => {
                    let handler =
                      await runtime.parts.handlerDeferred->Deferred.await_->Effect.runPromise
                    await handler(msg.json, ())
                  })
                  ->Effect.zipRight(msg.done_)
                )
              ),
            )
            let _ = Effect.runFork(drainEffect)
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

// Projection-flavoured channel: identical wiring to `Make`, plus registers the
// resolved handler in the Bus projection catch-up registry so the SQLite
// backend's startup catch-up (ProjectionCheckpoint) can replay missed stored
// events into it. Only projection collectors (the ReadModel builders) use this
// — automation/translation collectors must never receive catch-up events (they
// would re-run side effects and re-dispatch commands), so they stay on `Make`.
module MakeProjection = (Bus: LocalBus.T) => {
  module Base = Make(Bus)

  type callbackEvent = Base.callbackEvent
  type channelParts = Base.channelParts
  type runtimeParts = Base.runtimeParts

  let make = Base.make

  let connect: ReventlessCore.EventCollector_Adapter.connect<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  > = (~name, ~channelSpecs, ~runtime, ~opts) => {
    let _reg =
      runtime.parts.handlerDeferred
      ->Deferred.await_
      ->Effect.flatMap(handler =>
        Effect.sync(() => Bus.registerProjectionCatchupHandler(name, handler))
      )
      ->Effect.runPromise
      ->ignore
    Base.connect(~name, ~channelSpecs, ~runtime, ~opts)
  }
}

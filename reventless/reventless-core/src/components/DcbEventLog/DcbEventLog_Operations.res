module type Ops = {
  let name: string
  // The `service` value stamped on every published event's meta — and used as the
  // first arg to publishJson. Must equal the key under which Plugin_Builder
  // registers this DcbEventLog's EventTopic in `allEventTopics` so that
  // `Mapping.sourceName` matches at dispatch time. See Plan 03 / Phase 1.5.
  let serviceName: string
  let storage: DcbEventLog_Adapter.operations
  let publishJson: EventTopic.publishJson
}

module type T = {
  let read: DcbEventLog.read
  let append: DcbEventLog.append
  let readStream: DcbEventLog.readStream
  let appendStream: DcbEventLog.appendStream
}

module Make = (Ops: Ops): T => {
  let name = Ops.name
  let serviceName = Ops.serviceName

  let publishToEventTopic = async (rawEvents: array<DcbEventLog.rawEvent>) => {
    // Meta is now carried per-event by `rawEvent.meta` (set by the slice callback
    // via `Message.deriveMeta(~parent=command.meta, …)` so causationId / correlationId
    // propagate correctly). The publish-time `generateMeta(~service=serviceName)` is
    // gone — each event publishes under its own envelope.
    //
    // The publishedEvent hook contract still carries a single `meta` per batch
    // (its callers expect that shape); we use the first event's meta as the
    // representative envelope for the batch. Hook authors who need per-event
    // meta should read it off the eventsJson dicts.
    let representativeMeta = switch rawEvents->Array.get(0) {
    | Some(re) => re.meta
    | None => Message.generateMeta(~service=serviceName)
    }

    let rawEventsJson = rawEvents->Array.map(rawEvent =>
      Message.combineMessage(
        rawEvent.eventType,
        rawEvent.data->JSON.Decode.object->Option.getOr(Dict.make()),
      )
    )

    // Run beforePublish hook — if it throws, log the error and publish original events.
    let finalRawEventsJson = switch EventPublish_Callback.beforePublishHook.contents {
    | None => rawEventsJson
    | Some(hook) =>
      let published: EventPublish_Callback.publishedEvent = {
        componentName: name,
        entityId: name,
        eventCount: rawEventsJson->Array.length,
        eventsJson: rawEventsJson,
        meta: representativeMeta,
      }
      try {
        let result = await hook(published)
        result.eventsJson
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`DcbEventLog(${name})`,
          `beforePublishHook error: ${errMsg}`,
        )->Effect.runSync
        rawEventsJson
      }
    }

    let _ = await Array.zip(rawEvents, finalRawEventsJson)
    ->Array.map(async ((rawEvent, eventJson)) => {
      let entityId =
        rawEvent.tags->Array.get(0)->Option.map(t => t.value)->Option.getOr(name)
      let eventJson' = Message.composeEventJson'(entityId, rawEvent.meta, eventJson)
      try await Ops.publishJson(serviceName, rawEvent.meta, eventJson') catch {
      | JsExn(err) =>
        let errMsg = err->JsExn.message->Option.getOr("unknown")
        EffectLogger.logError(~comp=`DcbEventLog(${name})`, `EventTopic.publish Error: ${errMsg}`)->Effect.runSync
      }
    })
    ->Promise.all

    // Run afterPublish hook — fire-and-forget, errors are caught and logged.
    switch EventPublish_Callback.afterPublishHook.contents {
    | None => ()
    | Some(hook) =>
      try {
        let published: EventPublish_Callback.publishedEvent = {
          componentName: name,
          entityId: name,
          eventCount: finalRawEventsJson->Array.length,
          eventsJson: finalRawEventsJson,
          meta: representativeMeta,
        }
        let _ = await hook(published)
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`DcbEventLog(${name})`,
          `afterPublishHook error: ${errMsg}`,
        )->Effect.runSync
      }
    }
  }

  let append: DcbEventLog.append = async (
    rawEvents,
    ~condition=?,
  ) => {
    // Normalise `meta.service` to the DcbEventLog's serviceName on every event
    // before BOTH storage append and SNS publish. EventCollector dispatch (via
    // Plugin_Callback.handleJsonEvents) keys on `meta.service`, and the catalog
    // plugin's own EC consumes its own DcbEventLog's DDB stream for outgoing EP
    // routing — so the stored row's service must match the same identity SNS
    // consumers see (`<plugin>DcbEventLog`), not the original caller's plugin
    // name. Causation / correlation / tracing / headers carry through unchanged.
    let normalisedEvents = rawEvents->Array.map(re => {
      ...re,
      meta: {...re.meta, service: serviceName},
    })
    // Adapter rawStoredEvent is structurally identical to infra rawEvent
    let adapterEvents: array<DcbEventLog_Adapter.rawStoredEvent> = normalisedEvents->Obj.magic
    let result = await Ops.storage.append(adapterEvents, ~condition?)
    switch result {
    | Ok(position) =>
      await publishToEventTopic(normalisedEvents)
      Ok(position)
    | Error(_) as err => err
    }
  }

  let read: DcbEventLog.read = async (
    ~query,
    ~after=?,
  ) => {
    let rawResult = await Ops.storage.read(~query, ~after?)
    // Adapter rawSequencedEvent is structurally identical to infra rawSequencedEvent
    let events: array<DcbEventLog.rawSequencedEvent> = rawResult.events->Obj.magic
    let result: DcbEventLog.readResult = {
      events,
      headPosition: ?rawResult.headPosition,
    }
    result
  }

  let readStream: DcbEventLog.readStream = (~query, ~after=?, ~strongConsistency=?) =>
    Ops.storage.readStream(~query, ~after?, ~strongConsistency?)->Stream.map(raw => (raw->Obj.magic: DcbEventLog.rawSequencedEvent))

  // Streaming append — collects the stream into an array, then makes a single
  // storage.append call to preserve atomicity of the condition check.
  // Does not publish to EventTopic (use case: migration / bulk seeding).
  let appendStream: DcbEventLog.appendStream = (stream, ~condition=?) =>
    stream
    ->Stream.map(rawEvent => (rawEvent->Obj.magic: DcbEventLog_Adapter.rawStoredEvent))
    ->Stream.runCollect
    ->Effect.flatMap(rawEvents => Effect.promise(() => Ops.storage.append(rawEvents, ~condition?)))
}

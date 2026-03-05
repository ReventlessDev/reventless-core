module type Spec = {
  let sideEffects: array<module(Reventless.SideEffect.T)>
  let queryEngine: Reventless.QueryEngine.operations
}

module type T = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  let findSideEffect = (sideEffects, eventJson') =>
    eventJson'
    ->JSON.Decode.object
    ->Option.flatMap(eventObj' => {
      let metaJson = eventObj'->Dict.get("meta")
      switch metaJson->Option.map(meta => meta->S.parseJsonOrThrow(Message.metaSchema)) {
      | Some(eventMeta) =>
        let sideEffect =
          sideEffects->Array.find((module(SideEffect: Reventless.SideEffect.T)) =>
            SideEffect.Source.name == eventMeta.service
          )
        switch sideEffect {
        | None => None
        | Some(sideEffect) => Some((eventObj', eventMeta, sideEffect))
        }
      | exception err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(`SideEffects.map: Couldn't decode meta: ${errMsg}`)->Effect.runSync
        None
      | _ =>
        Effect.logError("SideEffects.map: Invalid JSON object")->Effect.runSync
        None
      }
    })

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' =>
      switch Spec.sideEffects->findSideEffect(eventJson') {
      | Some((eventObj, eventMeta, sideEffect)) =>
        Effect.promise(async () => {
          module SideEffect = unpack(sideEffect)
          let sourceName = SideEffect.Source.name
          Effect.logInfo(
            `SideEffectHandler.eventsHandler: handling event from source ${sourceName}: ${LogFormat.event'JsonToLogMessage(
                eventJson',
              )}`,
          )->Effect.runSync
          try {
            let idDecoded =
              eventObj
              ->Dict.get("id")
              ->Option.map(id => id->Message.decode(SideEffect.Source.Id.schema))
            let eventDecoded =
              eventObj
              ->Dict.get("event")
              ->Option.map(json => json->Message.decode(SideEffect.Source.eventSchema))
            switch (idDecoded, eventDecoded) {
            | (Some(eventId), Some(event)) =>
              try await SideEffect.execute(eventId, eventMeta, event, Spec.queryEngine) catch {
              | err =>
                let errMsg =
                  err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
                Effect.logError(`SideEffect: Error while processing: ${errMsg}`)->Effect.runSync
              }
            | (None, _)
            | (_, None) =>
              Effect.logError(
                `SideEffectHandler.eventHandler: Invalid event ${eventJson'->JSON.stringify}`,
              )->Effect.runSync
            }
          } catch {
          | err =>
            let errMsg =
              err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            Effect.logError(
              `SideEffectHandler.eventHandler: Couldn't decode event: ${eventJson'->JSON.stringify} ${errMsg}`,
            )->Effect.runSync
          }
        })
      | None => Effect.succeed()
      }
    )
    ->Stream.runDrain
}

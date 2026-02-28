module type Spec = {
  let sideEffects: array<module(Reventless.SideEffect.T)>
  let queryEngine: Reventless.QueryEngine.operations
}

module type T = {
  let eventsHandler: EventCollector.jsonEventsHandler
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
        Console.log2("SideEffects.map: Couldn't decode meta:", err)
        None
      | _ =>
        Console.log("SideEffects.map: Invalid JSON object")
        None
      }
    })

  let eventsHandlerImpl = (eventsJson': array<JSON.t>) => {
    eventsJson'
    ->Array.map(async eventJson' =>
      switch Spec.sideEffects->findSideEffect(eventJson') {
      | Some((eventObj, eventMeta, sideEffect)) =>
        module SideEffect = unpack(sideEffect)
        let sourceName = SideEffect.Source.name
        eventJson'->Logger.logJsonEvent(
          `SideEffectHandler.eventsHandler: handling event from source ${sourceName}:`,
        )
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
            | err => Console.log2("SideEffect: Error while processing:", err)
            }

          | (None, _)
          | (_, None) =>
            Console.log2("SideEffectHandler.eventHandler: Invalid event", eventJson')
          }
        } catch {
        | err =>
          Console.log3("SideEffectHandler.eventHandler: Couldn't decode event:", eventJson', err)
        }

      | None => ()
      }
    )
    ->Promise.all
    ->Util.Promise.toUnit
  }
  let eventsHandler = EventCollector.fromArrayHandler(eventsHandlerImpl)
}

module type Spec = {
  let sideEffects: array<module(ReventlessSpec.SideEffect.T)>
  let queryEngine: ReventlessSpec.QueryEngine.operations
}

module type T = {
  let eventsHandler: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  let findSideEffect = (sideEffects, eventJson') =>
    eventJson'
    ->Js.Json.decodeObject
    ->Option.flatMap(eventObj' => {
      let metaJson = eventObj'->Js.Dict.get("meta")
      switch metaJson->Option.map(meta => meta->S.parseJsonOrThrow(Message.metaSchema)) {
      | Some(eventMeta) =>
        let sideEffect =
          sideEffects->Array.find((module(SideEffect: ReventlessSpec.SideEffect.T)) =>
            SideEffect.Source.name == eventMeta.service
          )
        switch sideEffect {
        | None => None
        | Some(sideEffect) => Some((eventObj', eventMeta, sideEffect))
        }
      | exception err =>
        Js.log2("SideEffects.map: Couldn't decode meta:", err)
        None
      | _ =>
        Js.log("SideEffects.map: Invalid JSON object")
        None
      }
    })

  let eventsHandler = eventsJson' => {
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
            ->Js.Dict.get("id")
            ->Option.map(id => id->Message.decode(SideEffect.Source.Id.schema))
          let eventDecoded =
            eventObj
            ->Js.Dict.get("event")
            ->Option.map(json => json->Message.decode(SideEffect.Source.eventSchema))
          switch (idDecoded, eventDecoded) {
          | (Some(eventId), Some(event)) =>
            try await SideEffect.execute(eventId, eventMeta, event, Spec.queryEngine) catch {
            | err => Js.log2("SideEffect: Error while processing:", err)
            }

          | (None, _)
          | (_, None) =>
            Js.log2("SideEffectHandler.eventHandler: Invalid event", eventJson')
          }
        } catch {
        | err => Js.log3("SideEffectHandler.eventHandler: Couldn't decode event:", eventJson', err)
        }

      | None => ()
      }
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}

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
      let meta = eventObj'->Js.Dict.get("meta")->Option.map(Message.meta_decode)

      switch meta {
      | Some(Ok(eventMeta)) =>
        let sideEffect =
          sideEffects->Array.find((module(SideEffect: ReventlessSpec.SideEffect.T)) =>
            SideEffect.Source.name == eventMeta.service
          )
        switch sideEffect {
        | None => None
        | Some(sideEffect) => Some((eventObj', eventMeta, sideEffect))
        }
      | Some(Error(err)) =>
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
        let idDecoded = eventObj->Js.Dict.get("id")->Option.map(SideEffect.Source.Id.t_decode)
        let eventDecoded =
          eventObj->Js.Dict.get("event")->Option.map(SideEffect.Source.event_decode)

        switch (idDecoded, eventDecoded) {
        | (Some(Ok(eventId)), Some(Ok(event))) =>
          try await SideEffect.execute(eventId, eventMeta, event, Spec.queryEngine) catch {
          | err => Js.log2("SideEffect: Error while processing:", err)
          }

        | (None, _)
        | (_, None) =>
          Js.log("SideEffectHandler.eventHandler: Invalid event")
        | (_, Some(Error(err)))
        | (Some(Error(err)), _) =>
          Js.log2("SideEffectHandler.eventHandler: Couldn't decode event:", err)
        }
      | None => ()
      }
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}

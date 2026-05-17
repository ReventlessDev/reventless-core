module type Spec = {
  let sideEffects: array<module(Reventless.SideEffect.T)>
  let queryEngine: Reventless.QueryEngine.operations
}

module type T = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  // Pair each registered SideEffect with the variant TAGs declared by its
  // Source.eventSchema. Used to pre-filter incoming envelopes — sibling
  // variants on the same source that the SideEffect does not declare are
  // silently skipped instead of producing decode-failure noise.
  let sideEffectsWithTags =
    Spec.sideEffects->Array.map((module(SideEffect: Reventless.SideEffect.T)) => (
      module(SideEffect: Reventless.SideEffect.T),
      Reventless.DcbTag.extractVariantNames(SideEffect.Source.eventSchema),
    ))

  // Matches an incoming event JSON to a registered SideEffect module by comparing
  // the event's meta.service against each SideEffect.Source.name.
  let findSideEffect = (sideEffectsWithTags, eventJson') =>
    eventJson'
    ->JSON.Decode.object
    ->Option.flatMap(eventObj' => {
      let metaJson = eventObj'->Dict.get("meta")
      switch metaJson->Option.map(meta => meta->Reventless.Util_Sury.fromJson(Message.metaSchema)) {
      | Some(eventMeta) =>
        let entry =
          sideEffectsWithTags->Array.find(((module(SideEffect: Reventless.SideEffect.T), _)) =>
            SideEffect.Source.name == eventMeta.service
          )
        switch entry {
        | None => None
        | Some((sideEffect, acceptedTags)) =>
          // Pre-filter by TAG: skip silently when the variant is not declared.
          let tag =
            eventObj'
            ->Dict.get("event")
            ->Option.map(Message.variantNameOfJson)
            ->Option.getOr("unknown")
          if !(acceptedTags->Array.includes(tag)) {
            None
          } else {
            Some((eventObj', eventMeta, sideEffect))
          }
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

  // EventCollector handler — for each event, finds the matching SideEffect module,
  // decodes the event id+payload, and calls SideEffect.execute.
  // Decode and execution errors are logged and swallowed (side effects are fire-and-forget).
  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' =>
      switch sideEffectsWithTags->findSideEffect(eventJson') {
      | Some((eventObj, eventMeta, sideEffect)) =>
        module SideEffect = unpack(sideEffect)
        let sourceName = SideEffect.Source.name
        Effect.logInfo(
          `SideEffectHandler.eventsHandler: handling event from source ${sourceName}: ${LogFormat.event'JsonToLogMessage(
              eventJson',
            )}`,
        )->Effect.zipRight(
          Effect.trySync(
            ~catch=err => {
              let errMsg = Util.Error.messageFromUnknown(err, "unknown")
              `SideEffectHandler.eventHandler: Couldn't decode event: ${eventJson'->JSON.stringify} ${errMsg}`
            },
            () => {
              let idDecoded =
                eventObj
                ->Dict.get("id")
                ->Option.map(id => id->Message.decode(SideEffect.Source.Id.schema))
              let eventDecoded =
                eventObj
                ->Dict.get("event")
                ->Option.map(json => json->Message.decode(SideEffect.Source.eventSchema))
              (idDecoded, eventDecoded)
            },
          )
          ->Effect.flatMap(decoded =>
            switch decoded {
            | (Some(eventId), Some(event)) =>
              Effect.tryPromise(
                ~catch=err => {
                  let errMsg = Util.Error.messageFromUnknown(err, "unknown")
                  `SideEffect: Error while processing: ${errMsg}`
                },
                () => SideEffect.execute(eventId, eventMeta, event, Spec.queryEngine),
              )->Effect.catchAll(errMsg => Effect.logError(errMsg))
            | _ =>
              Effect.logError(
                `SideEffectHandler.eventHandler: Invalid event ${eventJson'->JSON.stringify}`,
              )
            }
          )
          ->Effect.catchAll(errMsg => Effect.logError(errMsg))
        )
      | None => Effect.succeed()
      }
    )
    ->Stream.runDrain
}

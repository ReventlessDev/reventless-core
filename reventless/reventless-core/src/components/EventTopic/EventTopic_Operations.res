module type Ops = {
  let publishJson: EventTopic.publishJson
}

module Make = (Spec: ReventlessInfra.EventTopic.T, Ops: Ops) => {
  let publish = async events' => {
    let eventCount = events'->Array.length
    await events'
    ->Array.mapWithIndex(async (event', idx) => {
      let eventJson' = event'->Message.encodeEvent'(Spec.Id.schema, Spec.eventSchema)

      let id = event'.id
      let idx = idx + 1

      switch await Ops.publishJson(id->Spec.Id.toString, event'.meta, eventJson') {
      | exception e =>
        Effect.logError(
          `Couldn't publish event ${idx->Int.toString}/${eventCount->Int.toString}: ${LogFormat.event'JsonToLogMessage(
              eventJson',
            )}`,
        )->Effect.runSync
        throw(e)
      | _ =>
        Effect.logInfo(
          `Published event ${idx->Int.toString}/${eventCount->Int.toString}: ${LogFormat.event'JsonToLogMessage(
              eventJson',
            )}`,
        )->Effect.runSync
      }
    })
    ->Promise.all
    ->Util.Promise.toUnit
  }
}

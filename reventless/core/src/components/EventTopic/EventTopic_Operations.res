module type Ops = {
  let publishJson: EventTopic.publishJson
}

module Make = (Spec: ReventlessInfra.EventTopic.T, Ops: Ops) => {
  let comp = `EventTopic(${Spec.name})`

  let publish = async events' => {
    let eventCount = events'->Array.length
    await events'
    ->Array.mapWithIndex(async (event', idx) => {
      let eventJson' = event'->Message.encodeEvent'(Spec.Id.schema, Spec.eventSchema)

      let id = event'.id
      let idx = idx + 1

      let idxStr = `${idx->Int.toString}/${eventCount->Int.toString}`
      switch await Ops.publishJson(id->Spec.Id.toString, event'.meta, eventJson') {
      | exception e =>
        EffectLogger.logError(
          ~comp,
          ~detail=eventJson',
          `publish failed ${idxStr}: ${LogFormat.eventDetail(eventJson')}`,
        )->Effect.runSync
        throw(e)
      | _ =>
        EffectLogger.logInfo(
          ~comp,
          ~detail=eventJson',
          `published event ${idxStr}: ${LogFormat.eventDetail(eventJson')}`,
        )->Effect.runSync
      }
    })
    ->Promise.all
    ->Util.Promise.toUnit
  }
}

module type Ops = {
  let publishJson: EventTopic.publishJson
}

module Make = (Spec: EventTopic.Spec, Ops: Ops) => {
  let publish = async events' => {
    let eventCount = events'->Array.length
    await events'
    ->Array.mapWithIndex(async (event', idx) => {
      let eventJson' = event'->Message.encodeEvent'(Spec.Id.schema, Spec.eventSchema)

      let id = event'.id
      let idx = idx + 1

      switch await Ops.publishJson(id->Spec.Id.toString, event'.meta, eventJson') {
      | exception e =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          ~level=Error,
          `Couldn't publish event ${idx->Int.toString}/${eventCount->Int.toString}:`,
        )
        throw(e)
      | _ =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          `Published event ${idx->Int.toString}/${eventCount->Int.toString}:`,
        )
      }
    })
    ->Promise.all
    ->Util.Promise.toUnit
  }
}

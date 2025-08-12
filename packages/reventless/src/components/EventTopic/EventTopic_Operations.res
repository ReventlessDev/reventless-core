module type Spec = {
  let publishJson: EventTopic.publishJson
}

module Make = (Spec: Spec, EventTopicSpec: EventTopic.Spec) => {
  let publish = async events' => {
    let eventCount = events'->Array.length
    await events'
    ->Array.mapWithIndex(async (event', idx) => {
      let eventJson' =
        event'->Message.encodeEvent'(EventTopicSpec.Id.schema, EventTopicSpec.eventSchema)

      let id = event'.id
      let idx = idx + 1

      switch await Spec.publishJson(id->EventTopicSpec.Id.toString, event'.meta, eventJson') {
      | exception e =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          ~level=Error,
          `Couldn't publish event ${idx->Int.toString}/${eventCount->Int.toString}:`,
        )
        raise(e)
      | _ =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          `Published event ${idx->Int.toString}/${eventCount->Int.toString}:`,
        )
      }
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}

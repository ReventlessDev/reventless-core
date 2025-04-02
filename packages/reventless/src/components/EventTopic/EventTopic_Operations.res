module type Spec = {
  let publishJson: EventTopic.publishJson
}

module Make = (Spec: Spec, EventTopicSpec: EventTopic.Spec) => {
  let publish = async events' => {
    let eventCount = events'->Array.length
    await events'
    ->Array.mapWithIndex(async (event', idx) => {
      let eventJson' = Message.event'_encode(
        EventTopicSpec.Id.t_encode,
        EventTopicSpec.event_encode,
        event',
      )

      let id = event'.id
      let idx = idx + 1

      switch await Spec.publishJson(id->EventTopicSpec.Id.toString, event'.meta, eventJson') {
      | exception e =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          ~level=Error,
          `Couldn't publish event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
        )
        raise(e)
      | _ =>
        eventJson'->Logger.logJsonEvent(
          ~loc=__LOC__,
          `Published event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
        )
      }
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}

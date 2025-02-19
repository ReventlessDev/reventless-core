module type Spec = {
  module Id: ReventlessSpec.Id.T

  @decco
  type event
}

module Make = (Spec: Spec) => {
  let publish = publishJson =>
    async events' => {
      let eventCount = events'->Belt.Array.length
      await events'
      ->Belt.Array.mapWithIndex(async (idx, event') => {
        let event'Json = Message.event'_encode(Spec.Id.t_encode, Spec.event_encode, event')

        let id = event'.id
        let idx = idx + 1

        switch await publishJson(id->Spec.Id.toString, event'.meta, event'Json) {
        | exception e =>
          event'Json->Logger.logEvent'Json(
            ~loc=__LOC__,
            ~level=Error,
            `Couldn't publish event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
          )
          raise(e)
        | _ =>
          event'Json->Logger.logEvent'Json(
            ~loc=__LOC__,
            `Published event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
          )
        }
      })
      ->Js.Promise.all
      ->Util.Promise.toUnit
    }
}

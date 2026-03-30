module type T = {
  module Spec: Reventless.StateViewSlice.Spec
  type queryDbOperations

  let eventsHandler: (
    queryDbOperations,
    array<ReventlessInfra.DcbEventLog.rawSequencedEvent>,
  ) => promise<unit>
}

module Make = (Spec: Reventless.StateViewSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  type queryDbOperations = QueryDb.operations<string, Spec.state>

  let comp = `StateViewSlice(${Spec.name})`
  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let eventsHandler = async (
    queryDbOps: queryDbOperations,
    rawEvents: array<ReventlessInfra.DcbEventLog.rawSequencedEvent>,
  ) => {
    let count = rawEvents->Array.length->Int.toString
    let idx = ref(0)
    let allActions = []
    let events = rawEvents->Array.filterMap(raw => {
      let decoded = decoder.decode(
        ~eventType=raw.eventType,
        ~data=raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
      )
      switch decoded {
      | Some(event) =>
        idx := idx.contents + 1
        let id = raw.tags->Array.get(0)->Option.map(tag => tag.value)->Option.getOr("?")
        let actions = Spec.project(event)
        let actionsStr = LogFormat.actionNames(actions)
        EffectLogger.logInfo(
          ~comp,
          ~detail=raw.data,
          `handling event ${idx.contents->Int.toString}/${count}: ${raw.eventType}(${id}) ${actionsStr}`,
        )->Effect.runSync
        allActions->Array.pushMany(actions)
        Some(event)
      | None => None
      }
    })
    let skipped = rawEvents->Array.length - events->Array.length
    if skipped > 0 {
      EffectLogger.logWarn(
        ~comp,
        `skipped=${skipped->Int.toString} events (decode mismatch)`,
      )->Effect.runSync
    }
    await Projection.handleActions(allActions, queryDbOps, None)
  }
}

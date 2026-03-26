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

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)

  let eventsHandler = async (
    queryDbOps: queryDbOperations,
    rawEvents: array<ReventlessInfra.DcbEventLog.rawSequencedEvent>,
  ) => {
    let events =
      rawEvents->Array.filterMap(raw =>
        decoder.decode(
          ~eventType=raw.eventType,
          ~data=raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
        )
      )
    let actions = events->Array.flatMap(event => Spec.project(event))
    await Projection.handleActions(actions, queryDbOps, None)
  }
}

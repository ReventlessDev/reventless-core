module type T = {
  module Spec: Reventless.StateViewSlice.Spec
  type queryDbOperations

  let eventsHandler: (
    queryDbOperations,
    array<Spec.DcbEventLogSpec.event>,
  ) => promise<unit>
}

module Make = (Spec: Reventless.StateViewSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  type queryDbOperations = QueryDb.operations<string, Spec.state>

  let eventsHandler = async (
    queryDbOps: queryDbOperations,
    events: array<Spec.DcbEventLogSpec.event>,
  ) => {
    let actions = events->Array.flatMap(event => Spec.project(event))
    await Projection.handleActions(actions, queryDbOps, None)
  }
}

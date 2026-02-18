module type T = {
  module Spec: StateViewSlice.Spec
  type queryDbOperations

  let eventsHandler: (
    queryDbOperations,
    array<Message.event'<ReventlessSpec.Id.String.t, Spec.DcbEventLogSpec.event>>,
  ) => promise<unit>
}

module Make = (Spec: StateViewSlice.Spec): (T with module Spec = Spec) => {
  module Spec = Spec

  type queryDbOperations = QueryDb.operations<string, Spec.state>

  let eventsHandler = async (
    queryDbOps: queryDbOperations,
    events: array<Message.event'<ReventlessSpec.Id.String.t, Spec.DcbEventLogSpec.event>>,
  ) => {
    Logger.debug(
      ~loc=__LOC__,
      `StateViewSlice(${Spec.name})`,
      `${events->Array.length->Int.toString} event(s) received`,
    )

    // For each event, apply the projection function to generate actions
    // The project function takes the event and returns projection actions
    let actions =
      events
      ->Array.map(event => {
        // Use a default/initial state for projection
        // The actual state loading happens in Projection.handleActions for actions like Update
        let initialState = None // Will be handled by UpdateWithDefault in projection
        let projectedActions = Spec.project(initialState, event.event)
        projectedActions
      })
      ->Array.flat

    // Handle the actions using Projection
    await Projection.handleActions(actions, queryDbOps, None)
  }
}

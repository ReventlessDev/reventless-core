// Decode one source event and run its mappings' `collect`/`resolve`, with no
// side effects. Shared by the runtime callback, which applies the result to its
// to-do list, and by the GWT sweep, which must route exactly as the runtime does.

/** What one mapping made of one event. */
type routed<'item> = {
  collected: array<(string, 'item)>,
  resolved: option<string>,
}

module Make = (
  Spec: Reventless.AutomationSlice.Spec,
  Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
) => {
  type dispatch = {
    sourceName: string,
    handle: (
      JSON.t,
      ~sourceId: string,
      Reventless.AutomationSlice.context,
    ) => option<routed<Spec.todoItem>>,
  }

  // Decoders are compiled once, per mapping.
  let dispatches: array<
    dispatch,
  > = Automation.mappings->Array.map((module(M: Automation.Mapping)) => {
    let decoder = Reventless.DcbDecode.makeDecoder(M.sourceEventSchema)
    let handle = (json: JSON.t, ~sourceId: string, ctx: Reventless.AutomationSlice.context) => {
      let (eventType, dataDict) = json->Message.splitMessage
      decoder.decode(~eventType, ~data=dataDict)->Option.map(event => {
        collected: M.collect(event, ~sourceId, ctx),
        resolved: M.resolve(event),
      })
    }
    {sourceName: M.sourceName, handle}
  })

  /** Every mapping registered for `sourceName` that understood the payload, in
      registration order. `payload` is the inner event, not the envelope. */
  let route = (
    payload: JSON.t,
    ~sourceName: string,
    ~sourceId: string,
    ctx: Reventless.AutomationSlice.context,
  ): array<routed<Spec.todoItem>> =>
    dispatches->Array.filterMap(d =>
      d.sourceName == sourceName ? d.handle(payload, ~sourceId, ctx) : None
    )
}

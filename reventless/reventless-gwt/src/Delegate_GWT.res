open ReventlessCore

// Delegate_GWT — GWT for ExtensionPoint mappings and Extension delegates.
//
// Both are pure input → published-actions translations and form the one
// cross-plugin behavioural seam (per `.claude/rules/app-developer.md`):
//
//   * an ExtensionPoint mapping turns an internal aggregate/DCB event into
//     public extension-point EVENTS (via `mapOutgoingEvent`);
//   * an Extension delegate turns an extension-point event into delegate
//     COMMANDS (via `mapIncomingEvent`).
//
// This DSL drives the user-level mapping function with the inert `StubRuntime`
// handles and asserts the SET of published actions — including one-to-many
// fan-out (e.g. `OrderPlaced{productIds:[…]}` → N × `ItemOrdered`).
//
// `FromExtensionPoint(M)` / `FromExtension(M)` mirror the From* adapter pattern
// of `Mapping_GWT` / `Query_GWT`: one comparison core, two ways to feed it.
// `whenInboundEvent` returns the normalised published-action JSON, so the
// cross-plugin `Flow_GWT` boundary steps reuse these adapters directly.
//
// See `docs/plans/done/gwt-flow-and-extension-test-kinds.md` Phase 1.

module EPMapping = ReventlessInfra.ExtensionPointMapping
module ExtMapping = ReventlessInfra.ExtensionMapping

// A published action normalised for comparison: a routing target plus the
// encoded payload. EP events are keyed by entity id; delegate commands by the
// component (slice/aggregate) or extension-point they route to.
let encPublished = (~target: string, payload: JSON.t): JSON.t => {
  let d = Dict.make()
  d->Dict.set("target", JSON.Encode.string(target))
  d->Dict.set("payload", payload)
  JSON.Encode.object(d)
}

// -- Comparison core ---------------------------------------------------------

module type Delegate = {
  let name: string
  type inbound
  // Drive the underlying mapping with StubRuntime, returning the published
  // actions already normalised to JSON.
  let run: inbound => promise<array<JSON.t>>
}

module type T = {
  type inbound

  let describe: (string, unit => unit) => unit
  let test: (string, ~timeout: int=?, unit => promise<Outcome.outcome>) => unit

  let whenInboundEvent: inbound => promise<array<JSON.t>>
  let thenPublishedJson: (promise<array<JSON.t>>, array<JSON.t>) => promise<Outcome.outcome>
  let thenPublishesNothing: promise<array<JSON.t>> => promise<Outcome.outcome>
}

module Make = (D: Delegate): (T with type inbound = D.inbound) => {
  type inbound = D.inbound

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=D.name, name, ~timeout?, body)

  let whenInboundEvent = ev => D.run(ev)

  // Published actions form a SET — fan-out order is non-deterministic, so the
  // comparison sorts by stringified JSON before comparing.
  let sortJson = (arr: array<JSON.t>) =>
    arr->Array.toSorted((a, b) => String.compare(JSON.stringify(a), JSON.stringify(b)))

  let thenPublishedJson = async (actionsP, expected) => {
    let actual = await actionsP
    if sortJson(actual) == sortJson(expected) {
      Outcome.pass
    } else {
      Outcome.fail(PublishedActionsMismatch({expected, actual}))
    }
  }

  let thenPublishesNothing = actionsP => thenPublishedJson(actionsP, [])
}

// -- FromExtensionPoint: an EP mapping's `mapOutgoingEvent` ------------------

module FromExtensionPoint = (M: EPMapping.Mapping) => {
  let encEvent = (e: M.ExtensionPoint.event) => e->Message.encode(M.ExtensionPoint.eventSchema)

  module Core = Make({
    let name = M.ExtensionPoint.name
    type inbound = M.Delegate.event
    let run = async (event: M.Delegate.event) =>
      switch M.mapOutgoingEvent {
      | None => []
      | Some(f) =>
        let nested =
          await f("gwt-id", event, StubRuntime.meta, StubRuntime.queryEngine)
          ->Array.map(async action =>
            switch action {
            | EPMapping.PublishEvent(id, ev) => [encPublished(~target=id, encEvent(ev))]
            | EPMapping.PublishEventAsync(p) =>
              let (id, ev) = await p
              [encPublished(~target=id, encEvent(ev))]
            | EPMapping.Call(_, _) => []
            }
          )
          ->Promise.all
        nested->Array.flat
      }
  })

  type inbound = M.Delegate.event
  let describe = Core.describe
  let test = Core.test
  let whenInboundEvent = Core.whenInboundEvent
  let thenPublishesNothing = Core.thenPublishesNothing

  let thenPublishesEvent = (actionsP, id, event: M.ExtensionPoint.event) =>
    Core.thenPublishedJson(actionsP, [encPublished(~target=id, encEvent(event))])

  let thenPublishesEvents = (actionsP, pairs: array<(string, M.ExtensionPoint.event)>) =>
    Core.thenPublishedJson(
      actionsP,
      pairs->Array.map(((id, ev)) => encPublished(~target=id, encEvent(ev))),
    )
}

// -- FromExtension: an Extension delegate's `mapIncomingEvent` ---------------

module FromExtension = (M: ExtMapping.Mapping) => {
  let encCmd = (c: M.Delegate.command) => c->Message.encode(M.Delegate.commandSchema)
  let encEpCmd = (c: M.ExtensionPoint.command) => c->Message.encode(M.ExtensionPoint.commandSchema)

  module Core = Make({
    let name = M.Delegate.name
    type inbound = M.ExtensionPoint.event
    let run = async (event: M.ExtensionPoint.event) => {
      let nested =
        await M.mapIncomingEvent(
          "gwt-id",
          event,
          StubRuntime.meta,
          StubRuntime.pluginDefinition,
          StubRuntime.queryEngine,
        )
        ->Array.map(async action =>
          switch action {
          | ExtMapping.PublishStateChangeSliceCommand(cmd) => [
              encPublished(~target=M.Delegate.name, encCmd(cmd)),
            ]
          | ExtMapping.PublishStateChangeSliceCommandAsync(p) =>
            let cmd = await p
            [encPublished(~target=M.Delegate.name, encCmd(cmd))]
          | ExtMapping.PublishStateChangeSliceCommandsAsync(p) =>
            (await p)->Array.map(cmd => encPublished(~target=M.Delegate.name, encCmd(cmd)))
          | ExtMapping.PublishAggregateCommand(id, cmd) => [encPublished(~target=id, encCmd(cmd))]
          | ExtMapping.PublishAggregateCommandAsync(p) =>
            let (id, cmd) = await p
            [encPublished(~target=id, encCmd(cmd))]
          | ExtMapping.PublishAggregateCommandsAsync(p) =>
            (await p)->Array.map(((id, cmd)) => encPublished(~target=id, encCmd(cmd)))
          | ExtMapping.PublishExtensionPointCommand(id, cmd) => [
              encPublished(~target=id, encEpCmd(cmd)),
            ]
          | ExtMapping.ForwardCommand({extensionPointName, id, commandJson}) => [
              encPublished(~target=`${extensionPointName}:${id}`, commandJson),
            ]
          | ExtMapping.Call(_, _) => []
          }
        )
        ->Promise.all
      nested->Array.flat
    }
  })

  type inbound = M.ExtensionPoint.event
  let describe = Core.describe
  let test = Core.test
  let whenInboundEvent = Core.whenInboundEvent
  let thenPublishesNothing = Core.thenPublishesNothing

  let thenPublishesCommand = (actionsP, cmd: M.Delegate.command) =>
    Core.thenPublishedJson(actionsP, [encPublished(~target=M.Delegate.name, encCmd(cmd))])

  let thenPublishesCommands = (actionsP, cmds: array<M.Delegate.command>) =>
    Core.thenPublishedJson(
      actionsP,
      cmds->Array.map(cmd => encPublished(~target=M.Delegate.name, encCmd(cmd))),
    )

  let thenPublishesAggregateCommand = (actionsP, id, cmd: M.Delegate.command) =>
    Core.thenPublishedJson(actionsP, [encPublished(~target=id, encCmd(cmd))])
}

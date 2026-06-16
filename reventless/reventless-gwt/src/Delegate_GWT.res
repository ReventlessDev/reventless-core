open ReventlessCore

// Delegate_GWT — GWT for ExtensionPoint mappings and Extension delegates.
//
// Both are pure input → published-actions translations and form the one
// cross-plugin behavioural seam (per `.claude/rules/app-developer.md`). Each
// mapping has TWO directions, and each adapter drives both:
//
//   * an ExtensionPoint mapping turns an internal `Delegate` event into public
//     extension-point EVENTS (`mapOutgoingEvent`), and an incoming protocol
//     COMMAND into a wrapped-aggregate command (`mapIncomingCommand`);
//   * an Extension delegate turns an incoming extension-point EVENT into delegate
//     COMMANDS (`mapIncomingEvent`), and an internal `Delegate` event into an
//     outgoing protocol COMMAND (`mapOutgoingEvent`).
//
// The stimulus you inject names what arrives at the mapping, NOT what it emits:
//   * `whenDelegateEvent`  — an internal delegate event occurs (both adapters'
//     `mapOutgoingEvent`);
//   * `whenIncomingEvent`  — a protocol event arrives (Extension `mapIncomingEvent`);
//   * `whenIncomingCommand`— a protocol command arrives (EP `mapIncomingCommand`).
//
// This DSL drives the user-level mapping function with the inert `StubRuntime`
// handles and asserts the SET of published actions — including one-to-many
// fan-out (e.g. `OrderPlaced{productIds:[…]}` → N × `ItemOrdered`).
//
// `FromExtensionPoint(M)` / `FromExtension(M)` mirror the From* adapter pattern
// of `Mapping_GWT` / `Query_GWT`: one comparison core per direction.
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

  // Feed the stimulus into the mapping; returns the normalised published actions.
  // The adapters re-export this under direction-specific names (whenDelegateEvent
  // / whenIncomingEvent / whenIncomingCommand).
  let whenInput: inbound => promise<array<JSON.t>>
  let thenPublishedJson: (promise<array<JSON.t>>, array<JSON.t>) => promise<Outcome.outcome>
  let thenPublishesNothing: promise<array<JSON.t>> => promise<Outcome.outcome>
}

module Make = (D: Delegate): (T with type inbound = D.inbound) => {
  type inbound = D.inbound

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, ~timeout=?, body) =>
    JestBind.testPromise(~slice=D.name, name, ~timeout?, body)

  let whenInput = ev => D.run(ev)

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

// -- FromExtensionPoint: an EP mapping (both directions) ---------------------

module FromExtensionPoint = (M: EPMapping.Mapping) => {
  let encEvent = (e: M.ExtensionPoint.event) => e->Message.encode(M.ExtensionPoint.eventSchema)
  let encCommand = (c: M.Delegate.command) => c->Message.encode(M.Delegate.commandSchema)

  // Internal delegate event → outgoing extension-point events (`mapOutgoingEvent`).
  module EvCore = Make({
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

  // Incoming extension-point command → wrapped-aggregate commands (`mapIncomingCommand`).
  module CmdCore = Make({
    let name = M.ExtensionPoint.name
    type inbound = M.ExtensionPoint.command
    let run = async (command: M.ExtensionPoint.command) =>
      M.mapIncomingCommand("gwt-id", command, StubRuntime.meta)->Array.filterMap(action =>
        switch action {
        | EPMapping.PublishCommand(id, cmd) => Some(encPublished(~target=id, encCommand(cmd)))
        | EPMapping.Call(_, _) => None
        }
      )
  })

  type inbound = M.Delegate.event
  let describe = EvCore.describe
  let test = EvCore.test
  // `thenPublishesNothing` is direction-agnostic (compares to []), usable after
  // either `whenDelegateEvent` or `whenIncomingCommand`.
  let thenPublishesNothing = EvCore.thenPublishesNothing

  // Delegate event → outgoing protocol events.
  let whenDelegateEvent = EvCore.whenInput
  let thenPublishesEvent = (actionsP, id, event: M.ExtensionPoint.event) =>
    EvCore.thenPublishedJson(actionsP, [encPublished(~target=id, encEvent(event))])
  let thenPublishesEvents = (actionsP, pairs: array<(string, M.ExtensionPoint.event)>) =>
    EvCore.thenPublishedJson(
      actionsP,
      pairs->Array.map(((id, ev)) => encPublished(~target=id, encEvent(ev))),
    )

  // Incoming protocol command → wrapped-aggregate commands.
  let whenIncomingCommand = CmdCore.whenInput
  let thenPublishesCommand = (actionsP, id, cmd: M.Delegate.command) =>
    CmdCore.thenPublishedJson(actionsP, [encPublished(~target=id, encCommand(cmd))])
  let thenPublishesCommands = (actionsP, pairs: array<(string, M.Delegate.command)>) =>
    CmdCore.thenPublishedJson(
      actionsP,
      pairs->Array.map(((id, cmd)) => encPublished(~target=id, encCommand(cmd))),
    )
}

// -- FromExtension: an Extension delegate (both directions) ------------------

module FromExtension = (M: ExtMapping.Mapping) => {
  let encCmd = (c: M.Delegate.command) => c->Message.encode(M.Delegate.commandSchema)
  let encEpCmd = (c: M.ExtensionPoint.command) => c->Message.encode(M.ExtensionPoint.commandSchema)

  // Incoming extension-point event → delegate commands (`mapIncomingEvent`).
  module EvCore = Make({
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

  // Internal delegate event → outgoing protocol commands (`mapOutgoingEvent`, optional).
  module OutCore = Make({
    let name = M.Delegate.name
    type inbound = M.Delegate.event
    let run = async (event: M.Delegate.event) =>
      switch M.mapOutgoingEvent {
      | None => []
      | Some(f) =>
        f("gwt-id", event, StubRuntime.meta, StubRuntime.pluginDefinition)->Array.filterMap(action =>
          switch action {
          | ExtMapping.PublishExtensionPointCommand(id, cmd) =>
            Some(encPublished(~target=id, encEpCmd(cmd)))
          | ExtMapping.ForwardCommand({extensionPointName, id, commandJson}) =>
            Some(encPublished(~target=`${extensionPointName}:${id}`, commandJson))
          | ExtMapping.Call(_, _) => None
          }
        )
      }
  })

  type inbound = M.ExtensionPoint.event
  let describe = EvCore.describe
  let test = EvCore.test
  let thenPublishesNothing = EvCore.thenPublishesNothing

  // Incoming protocol event → delegate commands.
  let whenIncomingEvent = EvCore.whenInput
  let thenPublishesCommand = (actionsP, cmd: M.Delegate.command) =>
    EvCore.thenPublishedJson(actionsP, [encPublished(~target=M.Delegate.name, encCmd(cmd))])
  let thenPublishesCommands = (actionsP, cmds: array<M.Delegate.command>) =>
    EvCore.thenPublishedJson(
      actionsP,
      cmds->Array.map(cmd => encPublished(~target=M.Delegate.name, encCmd(cmd))),
    )
  let thenPublishesAggregateCommand = (actionsP, id, cmd: M.Delegate.command) =>
    EvCore.thenPublishedJson(actionsP, [encPublished(~target=id, encCmd(cmd))])

  // Internal delegate event → outgoing protocol commands.
  let whenDelegateEvent = OutCore.whenInput
  let thenPublishesExtensionPointCommand = (actionsP, id, cmd: M.ExtensionPoint.command) =>
    OutCore.thenPublishedJson(actionsP, [encPublished(~target=id, encEpCmd(cmd))])
}

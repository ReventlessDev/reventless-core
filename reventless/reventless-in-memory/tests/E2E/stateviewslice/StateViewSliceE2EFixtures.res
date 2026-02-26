// E2E test fixtures for StateViewSlice builder.
// Builds a StateViewSlice on top of a DcbEventLog and verifies projection into QueryDb.

open ReventlessSpec.Projection

// ─────────────────────────────────────────────────────────────
// DcbEventLog spec with Add/Rename/Remove events
// ─────────────────────────────────────────────────────────────

module ItemEventLog = {
  @schema
  type event =
    | ItemAdded({id: @s.matches(ReventlessSpec.DcbTag.string) string, name: string})
    | ItemRenamed({id: @s.matches(ReventlessSpec.DcbTag.string) string, name: string})
    | ItemRemoved({id: @s.matches(ReventlessSpec.DcbTag.string) string})
}

// ─────────────────────────────────────────────────────────────
// StateViewSlice spec: project ItemEventLog events to {id, name} state
// ─────────────────────────────────────────────────────────────

module ItemsViewSpec = {
  let name = "ItemsView"
  module DcbEventLogSpec = ItemEventLog

  @schema
  type event = ItemEventLog.event

  @schema
  type state = {id: string, name: string}

  let project = (_, event) =>
    switch event {
    | ItemEventLog.ItemAdded({id, name}) => [Set(id, {id, name})]
    | ItemEventLog.ItemRenamed({id, name}) => [Update(id, s => {...s, name})]
    | ItemEventLog.ItemRemoved({id}) => [Delete(id)]
    }
}

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module DcbEventLogMaker = DcbEventLog_Builder.Make(Bus)
module ItemEventLogMaker = DcbEventLogMaker.Make(ItemEventLog)
let eventLog = ItemEventLogMaker.make(~name="ItemEventLog")

// ─────────────────────────────────────────────────────────────
// Build StateViewSlice
// ─────────────────────────────────────────────────────────────

module SVMaker = StateViewSlice_Builder.Make(Bus)
module ItemsViewMaker = SVMaker.Make(ItemsViewSpec)
let sv = ItemsViewMaker.make(~dcbEventLog=eventLog)

// DcbEventLog eventTopic resource — needed for 2nd beforeAllAsync resolve to
// trigger EventCollectorChannel.connect registration.
let dcbEventTopicResource =
  (eventLog->Reventless.Component.outputs).eventTopic.resources->Array.getUnsafe(0)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

// Append an event to the DcbEventLog (publishes to event topic automatically)
let appendEvent = async event => {
  let ops = await eventLog->ItemEventLogMaker.operations->TestRunner.resolve
  let _ = await ops.append([event])
}

// Load projected state from the in-memory QueryDb.
// QueryDb is registered as "ItemsViewQueryDB"
// (= ItemsViewSpec.name ++ "QueryDB").
let loadState = async id => {
  switch Bus.getQueryDb("ItemsViewQueryDB") {
  | None => []
  | Some(ops) =>
    switch await ops.load(id) {
    | Error(_) => []
    | Ok(states) =>
      states->Array.map(json => json->S.parseJsonOrThrow(ItemsViewSpec.stateSchema))
    }
  }
}

// ItemView StateViewSlice specification.
// Projects item catalog events to a read-side view of each item.

let name = "ItemView"

module DcbEventLogSpec = ItemEventLog

@schema
type event = ItemEventLog.event

@schema
type state = {itemId: string, name: string, archived: bool}

let project = (existingState, event) =>
  switch event {
  | ItemEventLog.ItemCreated({itemId, name}) => [
      ReventlessSpec.Projection.Set(itemId, {itemId, name, archived: false}),
    ]
  | ItemEventLog.ItemRenamed({itemId, newName}) =>
    switch existingState {
    | Some(state) => [ReventlessSpec.Projection.Set(itemId, {...state, name: newName})]
    | None => []
    }
  | ItemEventLog.ItemArchived({itemId}) =>
    switch existingState {
    | Some(state) => [ReventlessSpec.Projection.Set(itemId, {...state, archived: true})]
    | None => []
    }
  }

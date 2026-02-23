// CatalogItem aggregate behavior.
// Implements the state machine for creating, updating, and archiving catalog items.

open CatalogItemSpec

module Spec = CatalogItemSpec

@schema
type state =
  | Active({name: string, description: string})
  | Archived

let resolverConfig: Reventless.Behavior.resolverConfig<command> = {
  commandSchema: commandSchema,
  fields: [],
}

let init: Reventless.Behavior.init<state, event> = event =>
  switch event {
  | ItemCreated({name, description}) => Active({name, description})
  | ItemUpdated(_)
  | ItemArchived(_) =>
    throw(Reventless.Message.InvalidEvent(event->Reventless.Message.encode(eventSchema)))
  }

let apply: Reventless.Behavior.apply<state, event> = (state, event) =>
  switch (state, event) {
  | (Active(_), ItemCreated({name, description})) => Active({name, description})
  | (Active(_), ItemUpdated({name, description})) => Active({name, description})
  | (Active(_), ItemArchived(_)) => Archived
  | (Archived, _) => state
  }

let create: Reventless.Behavior.create<command, event, error> = (command, _context, errorHandler) =>
  switch command {
  | CreateItem({itemId: id, name: n, description: d}) => [
      ItemCreated({itemId: id, name: n, description: d}),
    ]
  | UpdateItem(_)
  | ArchiveItem(_) =>
    errorHandler(ItemNotFound, command, _context)
  }

let execute: Reventless.Behavior.execute<state, command, event, error> = (
  state,
  command,
  context,
  errorHandler,
) =>
  switch (state, command) {
  | (Active(_), CreateItem(_)) => errorHandler(ItemAlreadyExists, command, context)
  | (Active(_), UpdateItem({itemId: id, name: n, description: d})) => [
      ItemUpdated({itemId: id, name: n, description: d}),
    ]
  | (Active(_), ArchiveItem({itemId: id})) => [ItemArchived({itemId: id})]
  | (Archived, CreateItem(_)) => errorHandler(ItemAlreadyArchived, command, context)
  | (Archived, UpdateItem(_)) => errorHandler(ItemAlreadyArchived, command, context)
  | (Archived, ArchiveItem(_)) => [] // idempotent
  }

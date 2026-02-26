// Category aggregate behavior.
// Implements the state machine for adding, renaming, and archiving categories.

open Reventless
open Category

module Spec = Category

@schema
type state =
  | Active({name: string})
  | Archived

let resolverConfig = {
  Behavior.commandSchema,
  fields: [],
}

let init = event =>
  switch event {
  | CategoryAdded({name}) => Active({name: name})
  | CategoryRenamed(_)
  | CategoryArchived(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Active(_), CategoryAdded({name})) => Active({name: name})
  | (Active(_), CategoryRenamed({name})) => Active({name: name})
  | (Active(_), CategoryArchived(_)) => Archived
  | (Archived, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | AddCategory({categoryId, name}) => [CategoryAdded({categoryId, name})]
  | RenameCategory(_)
  | ArchiveCategory(_) =>
    errorHandler(CategoryNotFound, command, _context)
  }

let execute = (
  state,
  command,
  context,
  errorHandler,
) =>
  switch (state, command) {
  | (Active(_), AddCategory(_)) => errorHandler(CategoryAlreadyExists, command, context)
  | (Active(s), RenameCategory({name})) when name == s.name => []
  | (Active(_), RenameCategory({categoryId, name})) => [CategoryRenamed({categoryId, name})]
  | (Active(_), ArchiveCategory({categoryId: cid})) => [CategoryArchived({categoryId: cid})]
  | (Archived, AddCategory(_)) => errorHandler(CategoryAlreadyArchived, command, context)
  | (Archived, RenameCategory(_)) => errorHandler(CategoryAlreadyArchived, command, context)
  | (Archived, ArchiveCategory(_)) => [] // idempotent
  }

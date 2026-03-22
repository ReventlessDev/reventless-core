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

let moduleUrl: string = %raw(`import.meta.url`)

let init = event =>
  switch event {
  | Added({name}) => Active({name: name})
  | Renamed(_)
  | Archived =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Active(_), Added({name})) => Active({name: name})
  | (Active(_), Renamed({name})) => Active({name: name})
  | (Active(_), Category.Archived) => Archived
  | (Archived, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | Add({name}) => [Added({name: name})]
  | Rename(_)
  | Archive =>
    errorHandler(CategoryNotFound, command, _context)
  }

let execute = (
  state,
  command,
  context,
  errorHandler,
) =>
  switch (state, command) {
  | (Active(_), Add(_)) => errorHandler(CategoryAlreadyExists, command, context)
  | (Active(s), Rename({name})) when name == s.name => []
  | (Active(_), Rename({name})) => [Renamed({name: name})]
  | (Active(_), Archive) => [Category.Archived]
  | (Archived, Add(_)) => errorHandler(CategoryAlreadyArchived, command, context)
  | (Archived, Rename(_)) => errorHandler(CategoryAlreadyArchived, command, context)
  | (Archived, Archive) => [] // idempotent
  }

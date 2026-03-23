// CatalogProduct aggregate behavior.
// Idempotently syncs Catalog product state into Ordering.

open CatalogProduct

module Spec = CatalogProduct

@schema
type state =
  | NotCreated
  | Created({name: string, price: float})

let resolverConfig = {Reventless.Behavior.commandSchema, fields: []}

let moduleUrl: string = %raw(`import.meta.url`)

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Synced({name, price})) => Created({name, price})
  | (Created(_), Synced({name, price})) => Created({name, price})
  | (Created(s), PriceUpdated({price})) => Created({...s, price})
  | (NotCreated, PriceUpdated(_)) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Sync({name, price})) => Ok([Synced({name, price})])
  | (NotCreated, UpdatePrice(_)) => Ok([]) // no aggregate yet — idempotent
  | (Created(_), Sync(_)) => Ok([]) // already exists — idempotent
  | (Created(_), UpdatePrice({price})) => Ok([PriceUpdated({price: price})])
  }

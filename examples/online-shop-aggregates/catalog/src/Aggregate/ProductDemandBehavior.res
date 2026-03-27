// ProductDemand aggregate behavior.
// Idempotently records and revokes order demand per product.

open ProductDemand

module Spec = ProductDemand

@schema
type state =
  | NotCreated
  | Created({recordedOrderIds: array<string>})

let moduleUrl: string = %raw(`import.meta.url`)

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Recorded({orderId})) => Created({recordedOrderIds: [orderId]})
  | (Created(s), Recorded({orderId})) =>
    Created({recordedOrderIds: Array.concat(s.recordedOrderIds, [orderId])})
  | (Created(s), Revoked({orderId})) =>
    Created({recordedOrderIds: s.recordedOrderIds->Array.filter(id => id !== orderId)})
  | (NotCreated, Revoked(_)) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Record({orderId})) => Ok([Recorded({orderId: orderId})])
  | (NotCreated, Revoke(_)) => Ok([]) // nothing recorded yet — idempotent
  | (Created(s), Record({orderId})) =>
    if s.recordedOrderIds->Array.includes(orderId) {
      Ok([]) // idempotent
    } else {
      Ok([Recorded({orderId: orderId})])
    }
  | (Created(s), Revoke({orderId})) =>
    if !(s.recordedOrderIds->Array.includes(orderId)) {
      Ok([]) // idempotent
    } else {
      Ok([Revoked({orderId: orderId})])
    }
  }

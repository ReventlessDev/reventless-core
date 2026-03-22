// E2E test fixtures for AutomationSlice (TODO list pattern).
// Tests the Callback logic directly — the core collect/resolve/process phases.

// ─────────────────────────────────────────────────────────────
// Minimal DcbEventLog spec
// ─────────────────────────────────────────────────────────────

module OrderEventLog = {
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type event =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string, address: string})
    | ShipmentCreated({orderId: @s.matches(Reventless.DcbTag.string) string})
}

// ─────────────────────────────────────────────────────────────
// AutomationSlice spec — TODO list pattern
// ─────────────────────────────────────────────────────────────

module ShipOrderSpec = {
  let name = "ShipOrder"
  let moduleUrl: string = %raw(`import.meta.url`)
  module DcbEventLogSpec = OrderEventLog

  @schema
  type todoItem = {orderId: string, address: string}

  @schema
  type command = CreateShipment({orderId: @s.matches(Reventless.DcbTag.string) string})

  let collect = event =>
    switch event {
    | OrderEventLog.OrderPlaced({orderId, address}) => [(orderId, {orderId, address})]
    | _ => []
    }

  let resolve = event =>
    switch event {
    | OrderEventLog.ShipmentCreated({orderId}) => Some(orderId)
    | _ => None
    }

  let process = (id, _item) => Some((id, CreateShipment({orderId: id})))

  let maxRetries = 3
  let heartbeatInterval = 60
}

// Spec where process returns None (skips processing)
module SkipProcessSpec = {
  let name = "SkipProcess"
  let moduleUrl: string = %raw(`import.meta.url`)
  module DcbEventLogSpec = OrderEventLog

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = Noop

  let collect = event =>
    switch event {
    | OrderEventLog.OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
    | _ => []
    }

  let resolve = event =>
    switch event {
    | OrderEventLog.ShipmentCreated({orderId}) => Some(orderId)
    | _ => None
    }

  let process = (_id, _item) => None

  let maxRetries = 0
  let heartbeatInterval = 60
}

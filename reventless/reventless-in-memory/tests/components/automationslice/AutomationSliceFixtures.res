// Test fixtures for AutomationSlice — Plan 04 mixed-source shape.
// Single-source mapping wired up so Callback unit tests exercise the per-source
// dispatch and context plumbing introduced by Plan 04.

// ─────────────────────────────────────────────────────────────
// Source — slice's own DcbEventLog (hand-rolled DcbSource shape)
// ─────────────────────────────────────────────────────────────

module ShipOrderSource = {
  module Id = Reventless.Id.String
  let name = "ShipOrderDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string, address: string})
    | ShipmentCreated({orderId: @s.matches(Reventless.DcbTag.string) string})
}

module SkipProcessSource = {
  module Id = Reventless.Id.String
  let name = "SkipProcessDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: @s.matches(Reventless.DcbTag.string) string})
    | ShipmentCreated({orderId: @s.matches(Reventless.DcbTag.string) string})
}

// ─────────────────────────────────────────────────────────────
// AutomationSlice specs (target of mappings)
// ─────────────────────────────────────────────────────────────

module ShipOrderSpec = {
  let name = "ShipOrder"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {orderId: string, address: string}

  @schema
  type command = CreateShipment({orderId: @s.matches(Reventless.DcbTag.string) string})

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = "CreateShipment"
}

module SkipProcessSpec = {
  let name = "SkipProcess"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = Noop

  let maxRetries = 0
  let heartbeatInterval = 60
  let targetName = "Noop"
}

// ─────────────────────────────────────────────────────────────
// Automation impls — `process` plus per-source `mappings` (the merged
// shape the Automation module type now requires after the 2-arg Make
// rework; collect/resolve still live on each per-source Mapping module).
// Forward-declared below the per-source Mapping modules to keep the
// declaration order self-contained.
// ─────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
// Mappings — collect/resolve over each source's event type
// ─────────────────────────────────────────────────────────────

module ShipOrderMapping = Reventless.AutomationSlice.Mapping.Make(
  ShipOrderSource,
  ShipOrderSpec,
  {
    let collect = (event: ShipOrderSource.event, _ctx) =>
      switch event {
      | OrderPlaced({orderId, address}) => [(orderId, ({orderId, address}: ShipOrderSpec.todoItem))]
      | ShipmentCreated(_) => []
      }
    let resolve = (event: ShipOrderSource.event) =>
      switch event {
      | ShipmentCreated({orderId}) => Some(orderId)
      | OrderPlaced(_) => None
      }
  },
)

module SkipProcessMapping = Reventless.AutomationSlice.Mapping.Make(
  SkipProcessSource,
  SkipProcessSpec,
  {
    let collect = (event: SkipProcessSource.event, _ctx) =>
      switch event {
      | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: SkipProcessSpec.todoItem))]
      | ShipmentCreated(_) => []
      }
    let resolve = (event: SkipProcessSource.event) =>
      switch event {
      | ShipmentCreated({orderId}) => Some(orderId)
      | OrderPlaced(_) => None
      }
  },
)

module ShipOrderAutomation: Reventless.AutomationSlice.Automation
  with module Spec := ShipOrderSpec = {
  let process = (id, _item: ShipOrderSpec.todoItem) =>
    Some((id, ShipOrderSpec.CreateShipment({orderId: id})))
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = Reventless.AutomationSlice.Mappings.Make(ShipOrderSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(ShipOrderMapping)]
}

module SkipProcessAutomation: Reventless.AutomationSlice.Automation
  with module Spec := SkipProcessSpec = {
  let process = (_id, _item: SkipProcessSpec.todoItem) => None
  let moduleUrl: string = %raw(`import.meta.url`)
  module M = Reventless.AutomationSlice.Mappings.Make(SkipProcessSpec)
  module type Mapping = M.Mapping
  let mappings: array<module(Mapping)> = [module(SkipProcessMapping)]
}

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testContext: Reventless.AutomationSlice.context = {
  environment: "test",
  platformName: "in-memory",
  pluginName: "TestPlugin",
  sliceName: "ShipOrder",
}

// Encode a ShipOrderSource.event into the JSON shape phase1 receives — wraps
// the event payload with a `meta.service` matching the source name so the
// callback's per-source dispatch picks the right mapping.
let encodeShipOrderEvent = (event: ShipOrderSource.event): JSON.t => {
  let payloadJson = event->Reventless.Util_Sury.toJson(ShipOrderSource.eventSchema)
  let dict = switch payloadJson->JSON.Decode.object {
  | Some(d) => d->Dict.copy
  | None =>
    // Payload-less variants serialise to bare strings — wrap into object form.
    let d = Dict.make()
    switch payloadJson->JSON.Decode.string {
    | Some(name) => d->Dict.set("TAG", JSON.Encode.string(name))
    | None => ()
    }
    d
  }
  let meta: Reventless.Message.meta = {
    service: ShipOrderSource.name,
    time: "2026-01-01T00:00:00Z",
    ip: "",
    user: "",
    msgId: "msg-1",
    correlationId: "",
  }
  dict->Dict.set("meta", meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema))
  dict->Dict.set("id", JSON.Encode.string("env-id"))
  JSON.Encode.object(dict)
}

let encodeSkipProcessEvent = (event: SkipProcessSource.event): JSON.t => {
  let payloadJson = event->Reventless.Util_Sury.toJson(SkipProcessSource.eventSchema)
  let dict = switch payloadJson->JSON.Decode.object {
  | Some(d) => d->Dict.copy
  | None =>
    let d = Dict.make()
    switch payloadJson->JSON.Decode.string {
    | Some(name) => d->Dict.set("TAG", JSON.Encode.string(name))
    | None => ()
    }
    d
  }
  let meta: Reventless.Message.meta = {
    service: SkipProcessSource.name,
    time: "2026-01-01T00:00:00Z",
    ip: "",
    user: "",
    msgId: "msg-1",
    correlationId: "",
  }
  dict->Dict.set("meta", meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema))
  dict->Dict.set("id", JSON.Encode.string("env-id"))
  JSON.Encode.object(dict)
}

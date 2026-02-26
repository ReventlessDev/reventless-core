open Reventless
open Reventless.Projection

S.enableJson()

// ─────────────────────────────────────────────────────────────
// Source event spec (aggregate events)
// ─────────────────────────────────────────────────────────────

module SourceSpec = {
  module Id = Reventless.Id.String
  let name = "SourceAggregate"

  @schema
  type event =
    | ItemCreated({name: string, price: float})
    | ItemPriceUpdated({newPrice: float})
    | ItemRemoved
}

// ─────────────────────────────────────────────────────────────
// Target read model spec
// ─────────────────────────────────────────────────────────────

module TargetSpec = {
  module Id = Reventless.Id.String
  let name = "ItemCatalog"

  @schema
  type state = {name: string, price: float}

  let config = ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Mapping: SourceSpec events → TargetSpec projection actions
// ─────────────────────────────────────────────────────────────

module ItemMapping = Mapping.Make(
  SourceSpec,
  TargetSpec,
  {
    let map = (msg: Message.event'<string, SourceSpec.event>) =>
      switch msg.event {
      | ItemCreated({name, price}) => Create(msg.id, ({name, price}: TargetSpec.state))
      | ItemPriceUpdated({newPrice}) => Update(msg.id, s => {...s, price: newPrice})
      | ItemRemoved => Delete(msg.id)
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "SourceAggregate",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let makeSourceEvent' = (id, event) => ({
  Message.id,
  meta: testMeta,
  event,
}: Message.event'<string, SourceSpec.event>)

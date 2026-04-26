// Verifies Phase 2 of Plan 03: a ReadModel whose `Mapping.sourceName` doesn't
// match any key in `allEventTopics` fails plugin assembly (here: ReadModel
// construction) with a clear error, instead of silently producing zero events.

open Jest
open Expect
open Reventless
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// Bus setup (isolated from the happy-path E2E test)
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Source whose name DOES NOT match any key in allEventTopics
// (intentional typo: "MissingDcb" vs the real "ProductCatalogDcbEventLog")
// ─────────────────────────────────────────────────────────────

module TypoSource = {
  module Id = Reventless.Id.String
  let name = "MissingDcb"

  @schema
  type event = ProductAdded({productId: string, name: string})
}

module RmSpec = {
  module Id = Reventless.Id.String
  let name = "TypoCheckReadModel"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {productId: string, name: string}

  let config = ReadModel.config()
  let subIdConfig = None
}

module TypoMapping = Mapping.Make(
  TypoSource,
  RmSpec,
  {
    let project = (msg: Message.event'<string, TypoSource.event>) =>
      switch msg.event {
      | ProductAdded({productId, name}) => Set(productId, ({productId, name}: RmSpec.state))
      }
  },
)

module TypoMappings: Mappings with module Target := RmSpec = {
  module Mappings = Mappings.Make(RmSpec)
  module type Mapping = Mappings.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(TypoMapping)]
}

// allEventTopics has ONE entry — but with a different key than the Mapping uses.
let topicResource: ReventlessInfra.Adapter.resource = ReventlessInfra.Adapter.make(
  ~name="ProductCatalogDcbEventLog"->Pulumi.Output.make,
  ~id="ProductCatalogDcbEventLog"->Pulumi.Output.make,
  ~urn="ProductCatalogDcbEventLog"->Pulumi.Output.make,
  ~service="memory:InMemory"->Pulumi.Output.make,
)
let allEventTopics: ReventlessInfra.EventTopic.allOutputs = Dict.fromArray([
  ("ProductCatalogDcbEventLog", {ReventlessInfra.EventTopic.resources: [topicResource]}),
])

module ReadModelMaker = ReadModel_Builder.Make(Bus)
module RmMaker = ReadModelMaker.Make(RmSpec, TypoMappings)

describe("ReadModel source-name fail-fast:", () => {
  test("constructing a ReadModel whose Mapping.sourceName is missing throws", () => {
    let threw = ref(false)
    let msg = ref("")
    try {
      let _ = RmMaker.make(~api=(), ~apiRole=(), ~allEventTopics)
    } catch {
    | JsExn(err) =>
      threw := true
      msg := err->JsExn.message->Option.getOr("")
    }
    expect(threw.contents)->toBe(true)->ignore
    expect(msg.contents->String.includes("MissingDcb"))->toBe(true)->ignore
    expect(msg.contents->String.includes("ProductCatalogDcbEventLog"))->toBe(true)
  })
})

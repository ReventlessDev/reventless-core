// A ReadModel whose `Mapping.sourceName` doesn't match any key in `allEventTopics`
// fails plugin assembly (here: ReadModel construction) with a clear error, instead
// of silently producing zero events. A dotted name is an extension point's, and
// the error then also says how another plugin's facts do reach a read model.

open JestGlobals
open Reventless
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// Bus setup (isolated from the happy-path E2E test)
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()
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
    let project = (msg: Message.event'<TypoSource.Id.t, TypoSource.event>) =>
      switch msg.event {
      | ProductAdded({productId, name}) =>
        Set(RmSpec.Id.makeFromString(productId), ({productId, name}: RmSpec.state))
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

// A Source named like an extension point ("Ordering.Orders"): a read model
// cannot subscribe to one, so the message must say where to go instead.
module ExtensionPointSource = {
  module Id = Reventless.Id.String
  let name = "Ordering.Orders"

  @schema
  type event = ItemOrdered({productId: string, orderId: string})
}

module EpRmSpec = {
  module Id = Reventless.Id.String
  let name = "EpCheckReadModel"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {productId: string, orderCount: int}

  let config = ReadModel.config()
  let subIdConfig = None
}

module EpMapping = Mapping.Make(
  ExtensionPointSource,
  EpRmSpec,
  {
    let project = (msg: Message.event'<ExtensionPointSource.Id.t, ExtensionPointSource.event>) =>
      switch msg.event {
      | ItemOrdered({productId}) =>
        Set(EpRmSpec.Id.makeFromString(productId), ({productId, orderCount: 1}: EpRmSpec.state))
      }
  },
)

module EpMappings: Mappings with module Target := EpRmSpec = {
  module Mappings = Mappings.Make(EpRmSpec)
  module type Mapping = Mappings.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(EpMapping)]
}

module ReadModelMaker = ReadModel_Builder.Make(Bus)
module RmMaker = ReadModelMaker.Make(RmSpec, TypoMappings)
module EpRmMaker = ReadModelMaker.Make(EpRmSpec, EpMappings)

let messageOf = make => {
  let msg = ref(None)
  try {
    let _ = make()
  } catch {
  | JsExn(err) => msg := Some(err->JsExn.message->Option.getOr(""))
  }
  msg.contents
}

describe("ReadModel source-name fail-fast:", () => {
  testSync("constructing a ReadModel whose Mapping.sourceName is missing throws", () => {
    let msg =
      messageOf(() => RmMaker.make(~api=(), ~apiRole=(), ~allEventTopics))->Option.getOrThrow
    expect(msg->String.includes("MissingDcb"))->toBe(true)
    expect(msg->String.includes("ProductCatalogDcbEventLog"))->toBe(true)
    // A typo keeps the plain message: no extension point is being named.
    expect(msg->String.includes("extension point"))->toBe(false)
  })

  testSync("a dotted sourceName names the Extension → slice route instead", () => {
    let msg =
      messageOf(() => EpRmMaker.make(~api=(), ~apiRole=(), ~allEventTopics))->Option.getOrThrow
    expect(msg->String.includes("Ordering.Orders"))->toBe(true)
    expect(msg->String.includes("looks like an extension point name"))->toBe(true)
    expect(msg->String.includes("Declare an Extension"))->toBe(true)
    expect(msg->String.includes("Targeting a StateChangeSlice instead of an Aggregate"))->toBe(true)
  })
})

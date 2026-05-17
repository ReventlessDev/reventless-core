// E2E test fixtures for DcbEventLog → ReadModel projection.
// Wires a real DcbEventLog + StateChangeSlice + ReadModel and verifies that
// events appended to the DCB log flow through the EventTopic and update the
// ReadModel's QueryDb. Exercises the Phase 1.5 fix that aligns
// `meta.service` with the `allEventTopics` dict key, plus the Phase 3
// `Reventless.Projection.DcbSource` helper.
//
// Plan 03: docs/plans/mixed-source-readmodel.md

open TestFixtures
open Reventless
open Reventless.Projection

// ─────────────────────────────────────────────────────────────
// DCB StateChangeSlice — emits events into a DCB EventLog
// ─────────────────────────────────────────────────────────────

module AddProductSpec = {
  let name = "AddProduct"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    ProductAdded({
      productId: @s.matches(Reventless.DcbTag.string) string,
      name: string,
    })

  @schema
  type consumedEvent = ProductAdded

  @schema
  type command = AddProduct({
    productId: @s.matches(Reventless.DcbTag.string) string,
    name: string,
  })

  @schema
  type error = ProductAlreadyExists

  let commandSchema = commandSchema
}

module AddProductBehavior = {
  module Spec = AddProductSpec
  let moduleUrl: string = %raw(`import.meta.url`)

  type state = bool
  let initialState = false

  let evolve = (_state: state, _event: Spec.consumedEvent) => true

  let decide = (state: state, command: Spec.command): result<array<Spec.event>, Spec.error> =>
    if state {
      Error(ProductAlreadyExists)
    } else {
      switch command {
      | AddProduct({productId, name}) => Ok([Spec.ProductAdded({productId, name})])
      }
    }
}

// ─────────────────────────────────────────────────────────────
// DCB Source — name MUST match `<dcbName>DcbEventLog`
// (= the dict key Plugin_Builder uses + the service stamped by
//   DcbEventLog_Operations after Phase 1.5).
//
// Hand-rolled `Source`-shaped module: this is the canonical pattern. The
// `Reventless.Projection.DcbSource.Make` helper is also available but requires
// binding the inline definition to a name first (ReScript abstract-type
// limitation), and the hand-rolled form is shorter for most cases.
// ─────────────────────────────────────────────────────────────

module ProductCatalogDcbSource = {
  module Id = Reventless.Id.String
  let name = "ProductCatalogDcbEventLog"

  @schema
  type event = ProductAdded({productId: string, name: string})
}

// ─────────────────────────────────────────────────────────────
// ReadModel spec
// ─────────────────────────────────────────────────────────────

module ProductsReadModelSpec = {
  module Id = Reventless.Id.String
  let name = "TestProductsReadModel"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {productId: string, name: string}

  let config = ReadModel.config()
  let subIdConfig = None
}

module ProductsFromDcb = Mapping.Make(
  ProductCatalogDcbSource,
  ProductsReadModelSpec,
  {
    let project = (msg: Message.event'<string, ProductCatalogDcbSource.event>) =>
      switch msg.event {
      | ProductAdded({productId, name}) =>
        Set(productId, ({productId, name}: ProductsReadModelSpec.state))
      }
  },
)

module ProductsMappings: Mappings with module Target := ProductsReadModelSpec = {
  module Mappings = Mappings.Make(ProductsReadModelSpec)
  module type Mapping = Mappings.Mapping
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings: array<module(Mapping)> = [module(ProductsFromDcb)]
}

// ─────────────────────────────────────────────────────────────
// Bus + Pulumi mock setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog (~name="ProductCatalog") and StateChangeSlice
// ─────────────────────────────────────────────────────────────

module DcbLogMaker = DcbEventLog_Builder.Make(Bus)
let dcbEventLog = DcbLogMaker.make(
  ~name="ProductCatalog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "productId"}),
)

module AddProductMaker = StateChangeSlice_Builder.Make(AddProductSpec, AddProductBehavior)

let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async cmdJsons => {
  let _ = await cmdJsons
  ->Array.map(async cmdJson => {
    let typeName = switch cmdJson.commandJson {
    | JSON.Object(dict) =>
      dict
      ->Dict.get("TAG")
      ->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      ->Option.getOr("")
    | _ => ""
    }
    let fullBody = JSON.Encode.object(
      Dict.fromArray([
        ("id", JSON.Encode.string(cmdJson.id)),
        ("meta", cmdJson.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema)),
        ("command", cmdJson.commandJson),
      ]),
    )
    let handlers = ReventlessCore.CommandTopic.getHandlers(typeName)
    let _ = await handlers
    ->Array.map(async entry => {
      let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {
        reference: cmdJson.id,
        command: fullBody,
      }
      let _ = await entry.handler(Stream.fromIterable([item]))->Effect.runPromise
    })
    ->Promise.all
  })
  ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make
let _addProductSlice = AddProductMaker.make(~dcbEventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Build allEventTopics and the ReadModel.
// Mirrors how Plugin_Builder merges the DCB EventTopic into allEventTopics
// under the key `<name> ++ "DcbEventLog"`.
// ─────────────────────────────────────────────────────────────

let dcbTopicOutputs: ReventlessInfra.EventTopic.outputs = (dcbEventLog->ReventlessInfra.Component.outputs).eventTopic

let allEventTopics: ReventlessInfra.EventTopic.allOutputs = Dict.fromArray([
  ("ProductCatalogDcbEventLog", dcbTopicOutputs),
])

module ReadModelMaker = ReadModel_Builder.Make(Bus)
module ProductsReadModel = ReadModelMaker.Make(ProductsReadModelSpec, ProductsMappings)
let rm = ProductsReadModel.make(~api=(), ~apiRole=(), ~allEventTopics)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let dispatch = async (commandJson, id) =>
  await publishJsons([{Reventless.Message.id, meta: testMeta, commandJson}])

let addProductCmd = (productId, name) =>
  AddProductSpec.AddProduct({productId, name})
  ->Reventless.Util_Sury.toJson(AddProductSpec.commandSchema)

let loadState = async productId => {
  switch Bus.getQueryDb("TestProductsReadModel") {
  | None => []
  | Some(ops) =>
    let states =
      await ops.loadStream(productId)
      ->Stream.runCollect
      ->Effect.catchAll(_ => Effect.succeed([]))
      ->Effect.runPromise
    states->Array.map(json => json->Reventless.Util_Sury.fromJson(ProductsReadModelSpec.stateSchema))
  }
}

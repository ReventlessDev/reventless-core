// E2E fixtures for the inferred cross-partition read (sibling-exclusion) — the
// AddProduct scenario through real in-memory DcbEventLog storage.
//
// The slice is built with the values the inference derives and Dcb_Builder threads:
//   crossPartitionTagKeys = ["categoryId"]   (a foreign reference, read in its own clause)
//   tagKeysByEventType     = {ProductAdded: ["productId"], CategoryAdded: ["categoryId"]}
// so the `categoryId` clause narrows `ProductAdded` out and reads only the category's
// lifecycle — sibling products tagged the same `categoryId` are never returned.

open TestFixtures

// ─── DcbEventLog event types (used to encode preseeded events) ───
module CatalogLog = {
  @schema
  type event =
    | ProductAdded({
        productId: @s.matches(Reventless.DcbTag.partition) string,
        categoryId: @s.matches(Reventless.DcbTag.string) string,
        name: string,
      })
    | CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})
}

// ─── AddProduct StateChangeSlice ───
module AddProductSpec = {
  let name = "AddProduct"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | ProductAdded({
        productId: @s.matches(Reventless.DcbTag.partition) string,
        categoryId: @s.matches(Reventless.DcbTag.string) string,
        name: string,
      })

  @schema
  type consumedEvent =
    | ProductAdded({productId: string})
    | CategoryAdded({categoryId: string})

  @schema
  type command =
    | AddProduct({
        productId: @s.matches(Reventless.DcbTag.partition) string,
        categoryId: @s.matches(Reventless.DcbTag.string) string,
        name: string,
      })

  @schema
  type error =
    | ProductAlreadyExists
    | CategoryNotFound

  let commandSchema = commandSchema
}

module AddProductBehavior = {
  module Spec = AddProductSpec
  let moduleUrl: string = %raw(`import.meta.url`)

  // `exists` flips true if the decision read returns ANY ProductAdded — so if a
  // sibling leaked into the read, p2 would be wrongly rejected. `liveCats` holds
  // categories seen via CategoryAdded.
  type state = {exists: bool, liveCats: array<string>}
  let initialState = {exists: false, liveCats: []}

  let evolve = (state: state, event: Spec.consumedEvent): state =>
    switch event {
    | ProductAdded(_) => {...state, exists: true}
    | CategoryAdded({categoryId}) => {...state, liveCats: Array.concat(state.liveCats, [categoryId])}
    }

  let decide = (state: state, command: Spec.command): result<array<Spec.event>, Spec.error> =>
    switch command {
    | AddProduct({productId, categoryId, name}) =>
      if state.exists {
        Error(ProductAlreadyExists)
      } else if !(state.liveCats->Array.includes(categoryId)) {
        Error(CategoryNotFound)
      } else {
        Ok([Spec.ProductAdded({productId, categoryId, name})])
      }
    }
}

// ─── Isolated bus + event-topic counter ───
module Bus = LocalBus.Make()

let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CatalogLogEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

let _ = TestRunner.setup()

// ─── DcbEventLog (partitioned by productId, with a categoryId secondary index) ───
module CatalogLogMaker = DcbEventLog_Builder.Make(Bus)
let eventLog = CatalogLogMaker.make(
  ~name="CatalogLog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "productId"}),
  ~indexes=["tag_categoryId"],
)

// ─── StateChangeSlice, threaded with the INFERRED scope ───
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

let _addProductSlice = AddProductMaker.make(
  ~dcbEventLog=eventLog,
  ~publishJsons=publishJsonsOutput,
  ~tagKeysByEventType=Dict.fromArray([("ProductAdded", ["productId"]), ("CategoryAdded", ["categoryId"])]),
  ~crossPartitionTagKeys=["categoryId"],
)

// ─── Helpers ───
let dispatch = async (commandJson, id) =>
  await publishJsons([{Reventless.Message.id, meta: testMeta, commandJson}])

let encodeEvent = (event: CatalogLog.event): ReventlessInfra.DcbEventLog.rawEvent => {
  let json = event->Reventless.Util_Sury.toJson(CatalogLog.eventSchema)
  let (eventType, data) = json->ReventlessCore.Message.splitMessage
  let tags = Reventless.DcbTag.extractTags(CatalogLog.eventSchema, event)
  let meta = ReventlessCore.Message.generateMeta(~service="test")
  {eventType, data: JSON.Object(data), tags, meta}
}

let addProductJson = (productId, categoryId, name) =>
  AddProductSpec.AddProduct({productId, categoryId, name})->Reventless.Util_Sury.toJson(
    AddProductSpec.commandSchema,
  )

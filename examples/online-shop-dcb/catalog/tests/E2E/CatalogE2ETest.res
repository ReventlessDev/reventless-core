// End-to-end test for the CatalogPlugin DCB using the in-memory platform.
// Verifies the full command → DCB event log → event topic pipeline for both
// Product and Category entities without any cloud infrastructure.

open Reventless
open ReventlessInMemory.AsyncTest
open ReventlessInMemory.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = DcbEventLog name ++ "EventTopic" = "CatalogEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CatalogEventTopic", async (_, _, _) => {
  capturedEventCount := capturedEventCount.contents + 1
})

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = ReventlessInMemory.TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog
// ─────────────────────────────────────────────────────────────

module DcbEventLogMaker = ReventlessInMemory.DcbEventLog_Builder.Make(Bus)
module CatalogEventLogMaker = DcbEventLogMaker.Make(CatalogEventLog)
let eventLog = CatalogEventLogMaker.make(~name="Catalog")

// ─────────────────────────────────────────────────────────────
// Build StateChangeSlices
// ─────────────────────────────────────────────────────────────

module AddProductMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(AddProduct)
module ChangeProductNameMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ChangeProductName)
module ChangeProductDescriptionMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(
  ChangeProductDescription,
)
module ChangeProductPriceMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ChangeProductPrice)
module AddCategoryMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(AddCategory)
module RenameCategoryMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(RenameCategory)
module ArchiveCategoryMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ArchiveCategory)

// publishJsons routing — dispatches each command to its registered StateChangeSlice handler.
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
        ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(Message.metaSchema)),
        ("command", cmdJson.commandJson),
      ]),
    )
    let handlers = ReventlessInMemory.CommandTopic.getHandlers(typeName)
    let _ = await handlers
    ->Array.map(async entry => {
      let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {
        reference: cmdJson.id,
        command: fullBody,
      }
      let _ = await ReventlessInMemory.CommandTopic.callHandlerWithArray(entry.handler, [item])
    })
    ->Promise.all
  })
  ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make

let _addProductSlice =
  AddProductMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _updateProductNameSlice =
  ChangeProductNameMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _updateProductDescriptionSlice =
  ChangeProductDescriptionMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _updateProductPriceSlice =
  ChangeProductPriceMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _addCategorySlice =
  AddCategoryMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _renameCategorySlice =
  RenameCategoryMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _archiveCategorySlice =
  ArchiveCategoryMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "online-shop-dcb-catalog-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let dispatch = async (commandJson, entityId) =>
  await publishJsons([{Message.id: entityId, meta: testMeta, commandJson}])

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("Catalog DCB E2E:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->CatalogEventLogMaker.operations->ReventlessInMemory.TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  // — Product —

  testPromise("AddProduct publishes 1 event", async () => {
    let cmd =
      AddProduct.AddProduct({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      })->Message.encode(AddProduct.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate AddProduct produces 0 events (ProductAlreadyExists)", async () => {
    let cmd =
      AddProduct.AddProduct({
        productId: "prod-1",
        name: "Duplicate",
        description: "Dup",
        price: 1.0,
      })->Message.encode(AddProduct.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("ChangeProductName on existing product publishes 1 event", async () => {
    let cmd =
      ChangeProductName.ChangeProductName({productId: "prod-1", name: "Gaming Laptop"})
      ->Message.encode(ChangeProductName.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("ChangeProductName on non-existent product produces 0 events (ProductNotFound)", async () => {
    let cmd =
      ChangeProductName.ChangeProductName({productId: "no-such-product", name: "Ghost"})
      ->Message.encode(ChangeProductName.commandSchema)
    await dispatch(cmd, "no-such-product")
    expect(capturedEventCount.contents)->toBe(0)
  })

  // — Category —

  testPromise("AddCategory publishes 1 event", async () => {
    let cmd =
      AddCategory.AddCategory({categoryId: "cat-1", name: "Electronics"})
      ->Message.encode(AddCategory.commandSchema)
    await dispatch(cmd, "cat-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate AddCategory produces 0 events (CategoryAlreadyExists)", async () => {
    let cmd =
      AddCategory.AddCategory({categoryId: "cat-1", name: "Duplicate"})
      ->Message.encode(AddCategory.commandSchema)
    await dispatch(cmd, "cat-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("RenameCategory on existing category publishes 1 event", async () => {
    let cmd =
      RenameCategory.RenameCategory({categoryId: "cat-1", name: "Consumer Electronics"})
      ->Message.encode(RenameCategory.commandSchema)
    await dispatch(cmd, "cat-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("ArchiveCategory publishes 1 event", async () => {
    let cmd =
      ArchiveCategory.ArchiveCategory({categoryId: "cat-1"})
      ->Message.encode(ArchiveCategory.commandSchema)
    await dispatch(cmd, "cat-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate ArchiveCategory is idempotent (0 events)", async () => {
    let cmd =
      ArchiveCategory.ArchiveCategory({categoryId: "cat-1"})
      ->Message.encode(ArchiveCategory.commandSchema)
    await dispatch(cmd, "cat-1")
    expect(capturedEventCount.contents)->toBe(0)
  })
})

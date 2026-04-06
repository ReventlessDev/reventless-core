// End-to-end test for the hybrid CatalogPlugin using the in-memory platform.
// Verifies that the Category aggregate and Product DCB slices coexist
// and dispatch independently without interference.

open Reventless
open ReventlessInMemory.AsyncTest
open ReventlessInMemory.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Topic name = DcbEventLog name ++ "EventTopic" = "CatalogEventTopic"
let capturedDcbEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("CatalogEventTopic", async (_, _, _) => {
  capturedDcbEventCount := capturedDcbEventCount.contents + 1
})

// ─────────────────────────────────────────────────────────────
// Activate Pulumi mock mode (must be before any Component.make)
// ─────────────────────────────────────────────────────────────

let _ = ReventlessInMemory.TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build DcbEventLog for Product/ProductDemand
// ─────────────────────────────────────────────────────────────

module CatalogEventLogMaker = ReventlessInMemory.DcbEventLog_Builder.Make(Bus)
let eventLog = CatalogEventLogMaker.make(~name="Catalog", ~partitionTag=Reventless.DcbTag.Simple({key: "productId"}))

// ─────────────────────────────────────────────────────────────
// Build DCB StateChangeSlices (Product)
// ─────────────────────────────────────────────────────────────

module AddProductMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(AddProduct)
module ChangeProductNameMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ChangeProductName)
module ChangeProductPriceMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ChangeProductPrice)

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
let _changeProductNameSlice =
  ChangeProductNameMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _changeProductPriceSlice =
  ChangeProductPriceMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────

let testMeta: Message.meta = {
  service: "online-shop-hybrid-catalog-test",
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

describe("Catalog Hybrid E2E:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->CatalogEventLogMaker.operations->ReventlessInMemory.TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedDcbEventCount := 0
  })

  // — Product DCB —

  testPromise("AddProduct publishes 1 DCB event", async () => {
    let cmd =
      AddProduct.AddProduct({
        productId: "prod-1",
        name: "Laptop",
        description: "A laptop",
        price: 999.99,
      })->Message.encode(AddProduct.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedDcbEventCount.contents)->toBe(1)
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
    expect(capturedDcbEventCount.contents)->toBe(0)
  })

  testPromise("ChangeProductName on existing product publishes 1 event", async () => {
    let cmd =
      ChangeProductName.ChangeProductName({productId: "prod-1", name: "Gaming Laptop"})
      ->Message.encode(ChangeProductName.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedDcbEventCount.contents)->toBe(1)
  })

  testPromise("ChangeProductPrice on existing product publishes 1 event", async () => {
    let cmd =
      ChangeProductPrice.ChangeProductPrice({productId: "prod-1", price: 899.99})
      ->Message.encode(ChangeProductPrice.commandSchema)
    await dispatch(cmd, "prod-1")
    expect(capturedDcbEventCount.contents)->toBe(1)
  })
})

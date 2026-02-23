// End-to-end test for the ItemCatalog DCB plugin using the in-memory platform.
// Verifies the full command → DCB event log → event topic pipeline without any cloud infrastructure.
//
// Architecture:
//   1. Create an isolated in-memory Bus
//   2. Subscribe to the DcbEventLog's event topic before building components
//   3. Activate Pulumi mock mode (TestRunner.setup)
//   4. Build DcbEventLog + StateChangeSlices with publishJsons routing
//   5. Dispatch commands via publishJsons and assert event counts
//
// Note: publishJsons routes commands through the global CommandTopic registry
// (same mechanism as production CommandTopic filtering handler).
//
// Note on testPromise: uses Reventless.AsyncTest which binds directly to Jest's
// global `test` and properly awaits async tests (unlike @glennsl/rescript-jest's
// broken testPromise). See docs/fixes/rescript-jest-testpromise-async.md.

open Reventless.AsyncTest
open Reventless.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Isolated bus for this test suite
// ─────────────────────────────────────────────────────────────

module Bus = ReventlessInMemory.InMemory_Bus.Make()

// Subscribe to the DcbEventLog event topic before building components.
// Topic name = DcbEventLog name ++ "EventTopic" = "ItemCatalogEventTopic"
let capturedEventCount: ref<int> = ref(0)
let _ = Bus.subscribeToEvents("ItemCatalogEventTopic", async (_, _, _) => {
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
module ItemEventLogMaker = DcbEventLogMaker.Make(ItemEventLog)
let eventLog = ItemEventLogMaker.make(~name="ItemCatalog")

// ─────────────────────────────────────────────────────────────
// Build StateChangeSlices
// ─────────────────────────────────────────────────────────────

module CreateItemMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(CreateItem)
module RenameItemMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(RenameItem)
module ArchiveItemMaker = ReventlessInMemory.StateChangeSlice_Builder.Make(ArchiveItem)

// publishJsons routing — mirrors CommandTopic_Builder.filteringHandler.
// Routes each command JSON through the global CommandTopic registry so each
// StateChangeSlice receives only the commands it handles.
let publishJsons: ReventlessSpec.CommandTopic.publishJsons = async cmdJsons => {
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
        ("meta", cmdJson.meta->S.reverseConvertToJsonOrThrow(ReventlessSpec.Message.metaSchema)),
        ("command", cmdJson.commandJson),
      ]),
    )
    let handlers = Reventless.CommandTopic.getHandlers(typeName)
    let _ = await handlers
    ->Array.map(async entry => {
      let _ = await entry.handler([
        {ReventlessSpec.CommandTopic.reference: cmdJson.id, command: fullBody},
      ])
    })
    ->Promise.all
  })
  ->Promise.all
}

let publishJsonsOutput = publishJsons->Pulumi.Output.make

// Wire each StateChangeSlice to the shared event log and publishJsons router.
// In Pulumi mock mode, Output.apply runs synchronously, so handlers are
// registered in the global CommandTopic registry immediately.
let _createItemSlice = CreateItemMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _renameItemSlice = RenameItemMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)
let _archiveItemSlice = ArchiveItemMaker.make(~dcbEventLog=eventLog, ~publishJsons=publishJsonsOutput)

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: ReventlessSpec.Message.meta = {
  service: "example-dcb-test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

let dispatch = async (commandJson, itemId) =>
  await publishJsons([
    {
      ReventlessSpec.Message.id: itemId,
      meta: testMeta,
      commandJson,
    },
  ])

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

describe("ItemCatalog DCB E2E:", () => {
  // Resolve the eventLog operations Output before the first test runs.
  // This causes all Output.apply callbacks — including the StateChangeSlice
  // handler-registration callbacks — to fire, ensuring CommandTopic.registerHandler
  // has been called for CreateItem, RenameItem, and ArchiveItem.
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->Reventless.Component.operations->ReventlessInMemory.TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise("CreateItem publishes 1 event to the event topic", async () => {
    let cmd =
      CreateItem.CreateItem({itemId: "item-1", name: "Widget"})
      ->Reventless.Message.encode(CreateItem.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate CreateItem produces 0 events (ItemAlreadyExists)", async () => {
    // item-1 was created in the previous test — state persists in in-memory storage
    let cmd =
      CreateItem.CreateItem({itemId: "item-1", name: "Duplicate"})
      ->Reventless.Message.encode(CreateItem.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("RenameItem on existing item publishes 1 event", async () => {
    let cmd =
      RenameItem.RenameItem({itemId: "item-1", newName: "Super Widget"})
      ->Reventless.Message.encode(RenameItem.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("ArchiveItem publishes 1 event", async () => {
    let cmd =
      ArchiveItem.ArchiveItem({itemId: "item-1"})
      ->Reventless.Message.encode(ArchiveItem.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(1)
  })

  testPromise("duplicate ArchiveItem is idempotent (0 events)", async () => {
    // item-1 was archived in the previous test — archived branch returns Ok([])
    let cmd =
      ArchiveItem.ArchiveItem({itemId: "item-1"})
      ->Reventless.Message.encode(ArchiveItem.commandSchema)
    await dispatch(cmd, "item-1")
    expect(capturedEventCount.contents)->toBe(0)
  })

  testPromise("RenameItem on non-existent item produces 0 events (ItemNotFound)", async () => {
    let cmd =
      RenameItem.RenameItem({itemId: "no-such-item", newName: "Ghost Widget"})
      ->Reventless.Message.encode(RenameItem.commandSchema)
    await dispatch(cmd, "no-such-item")
    expect(capturedEventCount.contents)->toBe(0)
  })
})

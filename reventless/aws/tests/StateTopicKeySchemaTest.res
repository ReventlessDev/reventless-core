open JestGlobals

// Guards the key-schema check that stands between a self-provisioned table and
// the state-topic relay. The relay derives a change descriptor's entity key from
// the record's `Keys` on one convention — the partition attribute is named `id`.
// A table that breaks it does not fail at runtime; it publishes descriptors whose
// id does not match the row, which surfaces as clients refetching the wrong
// entity long after the deploy. So the check must fail the BUILD, and it must
// name the offending table — otherwise it sends the reader hunting.

let capture = f =>
  switch f() {
  | () => None
  | exception JsExn(e) => e->JsExn.message
  }

describe("StateTopic_AppSync_Helpers.checkPartitionKeyName", () => {
  testSync("accepts the framework convention", () => {
    let thrown = capture(() =>
      StateTopic_AppSync_Helpers.checkPartitionKeyName(
        ~tableName="PlatformUsageLedger-1a2b3c4",
        ~partitionKeyName="id",
      )
    )
    expect(thrown)->toEqual(None)
  })

  testSync("rejects a table keyed on anything else", () => {
    let thrown = capture(() =>
      StateTopic_AppSync_Helpers.checkPartitionKeyName(
        ~tableName="PlatformUsageLedger-1a2b3c4",
        ~partitionKeyName="pluginId",
      )
    )
    expect(thrown->Option.isSome)->toBe(true)
  })

  testSync("names the table and its actual key in the message", () => {
    let message =
      capture(() =>
        StateTopic_AppSync_Helpers.checkPartitionKeyName(
          ~tableName="PlatformUsageLedger-1a2b3c4",
          ~partitionKeyName="pluginId",
        )
      )->Option.getOr("")
    expect(message->String.includes("PlatformUsageLedger-1a2b3c4"))->toBe(true)
    expect(message->String.includes("pluginId"))->toBe(true)
  })
})

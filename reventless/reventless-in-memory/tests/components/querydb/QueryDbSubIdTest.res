// Tests for QueryDb in-memory storage with sub-ID (composite sort key) semantics.
// Verifies that loadStream returns items sorted by sub-key and that
// delete(id, Some((field, value))) removes only the targeted sub-key item.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open QueryDbSubIdFixtures

describe("QueryDb sub-ID (in-memory)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await metricQueryDb->ReventlessCore.Component.operations->TestRunner.resolve
  })

  testPromise("loadStream returns items sorted by sub-key", async () => {
    let ops = await metricQueryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save(
      "user-sort",
      {userId: "user-sort", region: "us-east", date: "2026-03", value: 1.0},
      Init,
      None,
    )
    let _ = await ops.save(
      "user-sort",
      {userId: "user-sort", region: "us-east", date: "2026-01", value: 2.0},
      Init,
      None,
    )
    let _ = await ops.save(
      "user-sort",
      {userId: "user-sort", region: "eu-west", date: "2026-02", value: 3.0},
      Init,
      None,
    )
    let result = await ops.loadStream("user-sort")->Stream.runCollect->Effect.runPromise
    // Sub-keys: "eu-west/2026-02", "us-east/2026-01", "us-east/2026-03" — alphabetical order
    expect(result->Array.length)->toBe(3)
    let s0 = result->Array.getUnsafe(0)
    let s1 = result->Array.getUnsafe(1)
    let s2 = result->Array.getUnsafe(2)
    expect(s0.region ++ "/" ++ s0.date)->toBe("eu-west/2026-02")
    expect(s1.region ++ "/" ++ s1.date)->toBe("us-east/2026-01")
    expect(s2.region ++ "/" ++ s2.date)->toBe("us-east/2026-03")
  })

  testPromise("delete with subId removes only the targeted item", async () => {
    let ops = await metricQueryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save(
      "user-del",
      {userId: "user-del", region: "us-east", date: "2026-01", value: 10.0},
      Init,
      None,
    )
    let _ = await ops.save(
      "user-del",
      {userId: "user-del", region: "us-east", date: "2026-02", value: 20.0},
      Init,
      None,
    )
    // Delete only the 2026-01 entry
    let _ = await ops.delete("user-del", Some(("_subId", "us-east/2026-01")))
    let result = await ops.loadStream("user-del")->Stream.runCollect->Effect.runPromise
    expect(result->Array.length)->toBe(1)
    let remaining = result->Array.getUnsafe(0)
    expect(remaining.date)->toBe("2026-02")
  })

  testPromise("delete without subId removes entire partition", async () => {
    let ops = await metricQueryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save(
      "user-delall",
      {userId: "user-delall", region: "us-east", date: "2026-01", value: 5.0},
      Init,
      None,
    )
    let _ = await ops.save(
      "user-delall",
      {userId: "user-delall", region: "eu-west", date: "2026-01", value: 7.0},
      Init,
      None,
    )
    let _ = await ops.delete("user-delall", None)
    let result = await ops.loadStream("user-delall")->Stream.runCollect->Effect.runPromise
    expect(result->Array.length)->toBe(0)
  })

  testPromise("save overwrites item with same sub-key", async () => {
    let ops = await metricQueryDb->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.save(
      "user-overwrite",
      {userId: "user-overwrite", region: "us-east", date: "2026-01", value: 1.0},
      Init,
      None,
    )
    let _ = await ops.save(
      "user-overwrite",
      {userId: "user-overwrite", region: "us-east", date: "2026-01", value: 99.0},
      Overwrite,
      None,
    )
    let result = await ops.loadStream("user-overwrite")->Stream.runCollect->Effect.runPromise
    expect(result->Array.length)->toBe(1)
    let s = result->Array.getUnsafe(0)
    expect(s.value)->toBe(99.0)
  })
})

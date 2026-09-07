// The @displayName overlay on the StateViewSlice projection path.
// Without it the column stays null and every surface names the row by its id.

open JestGlobals
open StateViewSliceDisplayNameFixtures

describe("StateViewSlice @displayName", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await sv->OrdersViewMaker.operations->TestRunner.resolve
    let _ = await dcbEventTopicResource.name->TestRunner.resolve
  })

  testPromise("a projected state carries the composed label", async () => {
    let _ = await appendEvent(
      OrderEventLog.OrderPlaced({id: "order-1", placedAt: "2026-09-01T10:00:00.000Z"}),
    )
    let states = await loadState("order-1")
    expect(states->Array.length)->toBe(1)
    let s = states->Array.getUnsafe(0)
    expect(s.displayName)->toEqual(Some("2026-09-01T10:00:00.000Z"))
  })

  testPromise("an update recomposes it from the state it wrote", async () => {
    let _ = await appendEvent(
      OrderEventLog.OrderShipped({id: "order-1", shippedAt: "2026-09-02T10:00:00.000Z"}),
    )
    let states = await loadState("order-1")
    let s = states->Array.getUnsafe(0)
    expect(s.shippedAt)->toBe("2026-09-02T10:00:00.000Z")
    expect(s.displayName)->toEqual(Some("2026-09-01T10:00:00.000Z"))
  })
})

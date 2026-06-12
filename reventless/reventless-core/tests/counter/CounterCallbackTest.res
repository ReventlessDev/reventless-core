open JestGlobals
open CounterFixtures

let _ = beforeEach(() => reset())

// ─────────────────────────────────────────────────────────────
// groupByCounterId (sync, wrapped as async for open compatibility)
// ─────────────────────────────────────────────────────────────

describe("Counter_Callback.groupByCounterId:", () => {
  testPromise("groups references by counter ID and sums increments", async () => {
    // Counter.makeId((counterId, ref)) = counterId ++ "#" ++ ref
    let result = Counter_Callback.groupByCounterId([
      (Counter.makeId(("counter-a", "ref-1")), 1),
      (Counter.makeId(("counter-a", "ref-2")), 2),
    ])
    let sorted = result->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    expect(sorted)->toEqual([("counter-a", 3)])
  })

  testPromise("groups different counter IDs independently", async () => {
    let result = Counter_Callback.groupByCounterId([
      (Counter.makeId(("counter-a", "ref-1")), 1),
      (Counter.makeId(("counter-b", "ref-2")), 1),
    ])
    let sorted = result->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    expect(sorted)->toEqual([("counter-a", 1), ("counter-b", 1)])
  })

  testPromise("returns empty array for empty input", async () => {
    let result = Counter_Callback.groupByCounterId([])
    expect(result)->toEqual([])
  })
})

// ─────────────────────────────────────────────────────────────
// counterHandler (async)
// ─────────────────────────────────────────────────────────────

describe("Counter_Callback.counterHandler:", () => {
  describe("count reaches zero", () => {
    testPromise("CountFinished event dispatched via jsonEventsHandler", async () => {
      let ref1 = Counter.makeId(("counter-1", "ref-a"))
      let counts = [makeCountsJson(ref1, 0)]
      await TestCounterHandler.counterHandler(~references=[(ref1, 1)], ~counts)
      // jsonEventsHandler should have been called with 1 event batch containing 1 event
      let batches = capturedEventBatches.contents
      expect((batches->Array.length, batches->Array.getUnsafe(0)->Array.length))->toEqual((1, 1))
    })
  })

  describe("count above zero", () => {
    testPromise("no CountFinished event, countsDbCount still called", async () => {
      let ref1 = Counter.makeId(("counter-1", "ref-a"))
      let counts = [makeCountsJson(ref1, 3)]
      await TestCounterHandler.counterHandler(~references=[(ref1, 1)], ~counts)
      // jsonEventsHandler called with empty array (no finished counters)
      let batches = capturedEventBatches.contents
      let events = batches->Array.getUnsafe(0)
      expect(events->Array.length)->toBe(0)
      // countsDbCount was called once
      expect(capturedCountCalls.contents->Array.length)->toBe(1)
    })
  })

  describe("multiple counters in batch", () => {
    testPromise("each decremented independently", async () => {
      let refA = Counter.makeId(("counter-a", "ref-1"))
      let refB = Counter.makeId(("counter-b", "ref-2"))
      let counts = [makeCountsJson(refA, 2), makeCountsJson(refB, 0)]
      await TestCounterHandler.counterHandler(
        ~references=[(refA, 1), (refB, 1)],
        ~counts,
      )
      // countsDbCount called twice (once per counter ID)
      expect(capturedCountCalls.contents->Array.length)->toBe(2)
      // One CountFinished event (counter-b reached 0)
      let batches = capturedEventBatches.contents
      let events = batches->Array.getUnsafe(0)
      expect(events->Array.length)->toBe(1)
    })
  })
})

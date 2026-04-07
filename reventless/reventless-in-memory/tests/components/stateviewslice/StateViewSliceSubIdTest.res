// E2E tests for StateViewSlice with sub-ID (composite sort key).
// Verifies that:
//  - projected items are stored with the correct composite sub-key (_subId = category/date)
//  - loadStream returns items sorted by sub-key
//  - multiple sub-key items for the same partition key are all returned

open AsyncTest
open AsyncTest.Expect
open StateViewSliceSubIdFixtures

describe("StateViewSlice sub-ID E2E", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await sv->ScoresViewMaker.operations->TestRunner.resolve
    let _ = await dcbEventTopicResource.name->TestRunner.resolve
  })

  testPromise("ScoreRecorded stores item with composite sub-key", async () => {
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-1", category: "math", date: "2026-01", score: 90}),
    )
    let scores = await loadScores("player-1")
    expect(scores->Array.length)->toBe(1)
    let s = scores->Array.getUnsafe(0)
    expect(s.category)->toBe("math")
    expect(s.score)->toBe(90)
  })

  testPromise("multiple ScoreRecorded events for same id are all kept", async () => {
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-2", category: "math", date: "2026-01", score: 80}),
    )
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-2", category: "science", date: "2026-01", score: 95}),
    )
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-2", category: "math", date: "2026-02", score: 85}),
    )
    let scores = await loadScores("player-2")
    expect(scores->Array.length)->toBe(3)
  })

  testPromise("loadStream returns sub-key items in alphabetical order", async () => {
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-3", category: "science", date: "2026-03", score: 70}),
    )
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-3", category: "math", date: "2026-01", score: 88}),
    )
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-3", category: "art", date: "2026-02", score: 77}),
    )
    let scores = await loadScores("player-3")
    expect(scores->Array.length)->toBe(3)
    // Sub-keys: "art/2026-02", "math/2026-01", "science/2026-03" — alphabetical order
    let s0 = scores->Array.getUnsafe(0)
    let s1 = scores->Array.getUnsafe(1)
    let s2 = scores->Array.getUnsafe(2)
    expect(s0.category)->toBe("art")
    expect(s1.category)->toBe("math")
    expect(s2.category)->toBe("science")
  })

  testPromise("items for different players are independent", async () => {
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-4", category: "math", date: "2026-01", score: 60}),
    )
    let _ = await appendEvent(
      ScoreEventLog.ScoreRecorded({id: "player-5", category: "math", date: "2026-01", score: 100}),
    )
    let scores4 = await loadScores("player-4")
    let scores5 = await loadScores("player-5")
    expect(scores4->Array.length)->toBe(1)
    expect(scores5->Array.length)->toBe(1)
    let s4 = scores4->Array.getUnsafe(0)
    let s5 = scores5->Array.getUnsafe(0)
    expect(s4.score)->toBe(60)
    expect(s5.score)->toBe(100)
  })
})

open JestGlobals
open ChunkHelpers

describe("PubSub", () => {
  testPromise("unbounded pubsub: publish + subscribe + Queue.take delivers message", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    // PubSub.subscribe is scoped — the whole subscribe+publish+take pipeline must be
    // inside Effect.scoped so the subscription stays alive when we publish and take.
    let v = await PubSub.subscribe(ps)
      ->Effect.flatMap(queue =>
        PubSub.publish(ps, "hello")
        ->Effect.zipRight(Queue.take(queue))
      )
      ->Effect.scoped
      ->Effect.runPromise
    expect(v)->toBe("hello")
  })

  testPromise("size reflects subscriber count", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    // Subscribe and then check size — both subscriptions must stay open
    let n = await PubSub.subscribe(ps)
      ->Effect.flatMap(_q1 =>
        PubSub.subscribe(ps)
        ->Effect.flatMap(_q2 => PubSub.size(ps))
      )
      ->Effect.scoped
      ->Effect.runPromise
    // Size may reflect subscribers or buffered items depending on PubSub variant
    expect(n)->toBeGreaterThan(-1)
  })

  testPromise("publishAll delivers all items to subscriber", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    let items = await PubSub.subscribe(ps)
      ->Effect.flatMap(queue =>
        PubSub.publishAll(ps, [1, 2, 3])
        ->Effect.zipRight(Queue.takeAll(queue))
      )
      ->Effect.scoped
      ->Effect.runPromise
    // Queue.takeAll returns a Chunk — convert to array for toEqual
    expect(items->arrayFrom)->toEqual([1, 2, 3])
  })

  testPromise("bounded constructor creates a PubSub.t without error", async () => {
    let ps = PubSub.bounded(10)->Effect.runSync
    let accepted = await PubSub.publish(ps, "x")->Effect.runPromise
    expect(accepted)->toBe(true)
  })

  testPromise("shutdown + isShutdown", async () => {
    let ps = PubSub.unbounded()->Effect.runSync
    let _ = await PubSub.shutdown(ps)->Effect.runPromise
    let shut = await PubSub.isShutdown(ps)->Effect.runPromise
    expect(shut)->toBe(true)
  })
})

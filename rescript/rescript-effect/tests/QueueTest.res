open AsyncTest
open AsyncTest.Expect

describe("Queue", () => {
  describe("constructors", () => {
    testPromise("unbounded queue accepts offers without blocking", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let accepted = await Queue.offer(q, 1)->Effect.runPromise
      expect(accepted)->toBe(true)
    })

    testPromise("bounded queue reports isFull when at capacity", async () => {
      let q = Queue.bounded(1)->Effect.runSync
      let _ = await Queue.offer(q, "x")->Effect.runPromise
      let full = await Queue.isFull(q)->Effect.runPromise
      expect(full)->toBe(true)
    })

    testPromise("sliding queue drops oldest item when full", async () => {
      let q = Queue.sliding(2)->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3])->Effect.runPromise
      let items = await Queue.takeAll(q)->Effect.runPromise
      // Oldest (1) was dropped; contains [2, 3]
      expect(items)->toHaveLength(2)
      expect(items)->toContain(3)
    })

    testPromise("dropping queue drops new item when full", async () => {
      let q = Queue.dropping(2)->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3])->Effect.runPromise
      let items = await Queue.takeAll(q)->Effect.runPromise
      // Newest (3) was dropped; contains [1, 2]
      expect(items)->toHaveLength(2)
      expect(items)->toContain(1)
    })
  })

  describe("offer / take round-trip", () => {
    testPromise("offer then take returns the same item", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, "hello")->Effect.runPromise
      let v = await Queue.take(q)->Effect.runPromise
      expect(v)->toBe("hello")
    })

    testPromise("offerAll then takeAll returns all items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offerAll(q, [10, 20, 30])->Effect.runPromise
      // Queue.takeAll returns an Effect Chunk — convert to array for toEqual
      let items = (await Queue.takeAll(q)->Effect.runPromise)->arrayFrom
      expect(items)->toEqual([10, 20, 30])
    })

    testPromise("takeUpTo returns at most N items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offerAll(q, [1, 2, 3, 4, 5])->Effect.runPromise
      let items = await Queue.takeUpTo(q, 3)->Effect.runPromise
      expect(items)->toHaveLength(3)
    })
  })

  describe("inspection", () => {
    testPromise("size reflects number of items", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, "a")->Effect.runPromise
      let _ = await Queue.offer(q, "b")->Effect.runPromise
      let n = await Queue.size(q)->Effect.runPromise
      expect(n)->toBe(2)
    })

    testPromise("isEmpty is true for empty queue", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let empty = await Queue.isEmpty(q)->Effect.runPromise
      expect(empty)->toBe(true)
    })

    testPromise("isEmpty is false after offer", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.offer(q, 1)->Effect.runPromise
      let empty = await Queue.isEmpty(q)->Effect.runPromise
      expect(empty)->toBe(false)
    })
  })

  describe("lifecycle", () => {
    testPromise("shutdown + isShutdown", async () => {
      let q = Queue.unbounded()->Effect.runSync
      let _ = await Queue.shutdown(q)->Effect.runPromise
      let shut = await Queue.isShutdown(q)->Effect.runPromise
      expect(shut)->toBe(true)
    })
  })
})

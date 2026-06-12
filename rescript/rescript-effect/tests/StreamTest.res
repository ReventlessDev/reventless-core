open JestGlobals

describe("Stream bindings", () => {
  describe("construction", () => {
    testPromise(
      "fromIterable emits all items in order",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([1, 2, 3])
      },
    )

    testPromise(
      "empty stream yields no items",
      async () => {
        let result: array<int> = await Stream.empty->Stream.runCollect->Effect.runPromise
        expect(result)->toEqual([])
      },
    )

    testPromise(
      "fromEffect wraps a single value",
      async () => {
        let result = await Stream.fromEffect(Effect.succeed("hello"))
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual(["hello"])
      },
    )

    testPromise(
      "fromQueue emits items already in the queue",
      async () => {
        // Offer items, then use take(2) to terminate — shutting down the queue
        // before Stream.fromQueue runs would interrupt pending takes and yield [].
        let queue = Queue.unbounded()->Effect.runSync
        let _ = Queue.offer(queue, 10)->Effect.runSync
        let _ = Queue.offer(queue, 20)->Effect.runSync
        let result = await Stream.fromQueue(queue)
        ->Stream.take(2)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([10, 20])
      },
    )

    testPromise(
      "paginateEffect pages through chunks until None",
      async () => {
        // Three pages: [1,2], [3,4], [5]
        let result = await Stream.paginateEffect(
          0,
          cursor =>
            Effect.sync(
              () => {
                let all = [1, 2, 3, 4, 5]
                let pageEnd = min(cursor + 2, 5)
                let chunk = all->Array.slice(~start=cursor, ~end=pageEnd)
                let next = cursor + 2 < 5 ? Some(cursor + 2) : None
                (chunk, next)
              },
            ),
        )
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([1, 2, 3, 4, 5])
      },
    )
  })

  describe("transformation", () => {
    testPromise(
      "map transforms each item",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.map(n => n * 2)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([2, 4, 6])
      },
    )

    testPromise(
      "filter removes items not matching predicate",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3, 4, 5])
        ->Stream.filter(n => mod(n, 2) == 0)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([2, 4])
      },
    )

    testPromise(
      "take limits to first N items",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3, 4, 5])
        ->Stream.take(3)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([1, 2, 3])
      },
    )

    testPromise(
      "mapEffect transforms each element with an Effect",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.mapEffect(n => Effect.succeed(n * 10))
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([10, 20, 30])
      },
    )

    testPromise(
      "mapEffect fails the stream when an Effect fails",
      async () => {
        let result = try {
          let _ = await Stream.fromIterable([1, 2, 3])
          ->Stream.mapEffect(n => n == 2 ? Effect.fail("boom") : Effect.succeed(n))
          ->Stream.runCollect
          ->Effect.runPromise
          "no-error"
        } catch {
        | _ => "errored"
        }
        expect(result)->toBe("errored")
      },
    )

    testPromise(
      "grouped splits stream into arrays of n",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3, 4, 5])
        ->Stream.grouped(2)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([[1, 2], [3, 4], [5]])
      },
    )

    testPromise(
      "grouped last chunk is smaller when stream length is not a multiple of n",
      async () => {
        let result = await Stream.fromIterable([1, 2, 3])
        ->Stream.grouped(2)
        ->Stream.runCollect
        ->Effect.runPromise
        expect(result)->toEqual([[1, 2], [3]])
      },
    )

    testPromise(
      "grouped on empty stream yields no groups",
      async () => {
        let result: array<array<int>> =
          await Stream.empty->Stream.grouped(3)->Stream.runCollect->Effect.runPromise
        expect(result)->toEqual([])
      },
    )
  })

  describe("terminal runners", () => {
    testPromise(
      "runFold accumulates state across all items",
      async () => {
        let sum = await Stream.fromIterable([1, 2, 3, 4])
        ->Stream.runFold(0, (acc, n) => acc + n)
        ->Effect.runPromise
        expect(sum)->toBe(10)
      },
    )

    testPromise(
      "runForEach runs side effect for each element",
      async () => {
        let total = ref(0)
        let _ = await Stream.fromIterable([1, 2, 3])
        ->Stream.runForEach(n => Effect.sync(() => {total := total.contents + n}))
        ->Effect.runPromise
        expect(total.contents)->toBe(6)
      },
    )

    testPromise(
      "runFold can accumulate a tuple",
      async () => {
        // Same pattern used in Aggregate_Callback for (state, count)
        let (last, count) = await Stream.fromIterable(["a", "b", "c"])
        ->Stream.runFold(("", 0), ((_, n), s) => (s, n + 1))
        ->Effect.runPromise
        expect(last)->toBe("c")
        expect(count)->toBe(3)
      },
    )

    testPromise(
      "runHead returns Some for non-empty stream",
      async () => {
        let head = await Stream.fromIterable([42, 1, 2])
        ->Stream.runHead
        ->Effect.runPromise
        expect(head)->toEqual(Some(42))
      },
    )

    testPromise(
      "runHead returns None for empty stream",
      async () => {
        let head: option<int> = await Stream.empty->Stream.runHead->Effect.runPromise
        expect(head)->toEqual(None)
      },
    )
  })
})

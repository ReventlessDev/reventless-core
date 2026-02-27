// Integration tests for Task_Builder.Make (in-memory).
// Verifies that tasks are created with correct outputs and that the bucket
// callback chain is wired through the in-memory adapter.
// Low-level handler extraction is covered in adapter/TaskBucketTest.res.

open AsyncTest
open AsyncTest.Expect
open TaskFixtures

describe("Task_Builder.Make:", () => {
  let _ = beforeEach(() => resetCaptures())

  describe("make — no buckets:", () => {
    testPromise("creates component with correct output name", async () => {
      let task = NoBucketsMaker.make(
        ~queryBucketName=mockQueryBucketName,
        ~scheduler=mockScheduler,
        ~publishToAggregates=mockPublishToAggregates,
        ~queryEngine=mockQueryEngine,
        ~resourceNaming=mockResourceNaming,
        ~allAggregates=Dict.make(),
        ~opts=None,
      )
      let outputs = NoBucketsMaker.outputs(task)
      expect(outputs.name)->toBe("NoBucketsTask")
    })

    testPromise("task with no buckets has no bucketNames in outputs", async () => {
      let task = NoBucketsMaker.make(
        ~queryBucketName=mockQueryBucketName,
        ~scheduler=mockScheduler,
        ~publishToAggregates=mockPublishToAggregates,
        ~queryEngine=mockQueryEngine,
        ~resourceNaming=mockResourceNaming,
        ~allAggregates=Dict.make(),
        ~opts=None,
      )
      let outputs = NoBucketsMaker.outputs(task)
      // bucketNames is absent when spec returns no buckets
      expect(outputs.bucketNames->Option.isSome)->toBe(false)
    })
  })

  describe("make — one named bucket with callback:", () => {
    testPromise("creates component with correct output name", async () => {
      let task = OneBucketMaker.make(
        ~queryBucketName=mockQueryBucketName,
        ~scheduler=mockScheduler,
        ~publishToAggregates=mockPublishToAggregates,
        ~queryEngine=mockQueryEngine,
        ~resourceNaming=mockResourceNaming,
        ~allAggregates=Dict.make(),
        ~opts=None,
      )
      let outputs = OneBucketMaker.outputs(task)
      expect(outputs.name)->toBe("OneBucketTask")
    })

    testPromise("bucketNames dict contains the named bucket key", async () => {
      let task = OneBucketMaker.make(
        ~queryBucketName=mockQueryBucketName,
        ~scheduler=mockScheduler,
        ~publishToAggregates=mockPublishToAggregates,
        ~queryEngine=mockQueryEngine,
        ~resourceNaming=mockResourceNaming,
        ~allAggregates=Dict.make(),
        ~opts=None,
      )
      let outputs = OneBucketMaker.outputs(task)
      let bucketNames = outputs.bucketNames->Option.getUnsafe
      expect(bucketNames->Dict.keysToArray)->toEqual(["Reports"])
    })

    testPromise("bucket id resolves to the bucket name (in-memory dummy resource)", async () => {
      let task = OneBucketMaker.make(
        ~queryBucketName=mockQueryBucketName,
        ~scheduler=mockScheduler,
        ~publishToAggregates=mockPublishToAggregates,
        ~queryEngine=mockQueryEngine,
        ~resourceNaming=mockResourceNaming,
        ~allAggregates=Dict.make(),
        ~opts=None,
      )
      let outputs = OneBucketMaker.outputs(task)
      let bucketNames = outputs.bucketNames->Option.getUnsafe
      let idOutput = bucketNames->Dict.get("Reports")->Option.getUnsafe
      let id = await idOutput->TestRunner.resolve
      // In-memory bucket uses bucket name as id: taskName ++ bucketName = "OneBucketTaskReports"
      expect(id)->toBe("OneBucketTaskReports")
    })
  })
})

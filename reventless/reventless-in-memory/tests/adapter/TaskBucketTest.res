// Unit tests for TaskBucket_InMemory.
// Covers makeHandler (event extraction) and make (dummy resource for Task_Builder compatibility).

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

// No Pulumi mock needed (TaskBucket_InMemory has no Pulumi.Output usage)

describe("TaskBucket_InMemory", () => {
  describe("makeHandler", () => {
    testPromise("calls callback with eventName and key extracted from JSON object", async () => {
      let receivedEventName: ref<string> = ref("")
      let receivedKey: ref<string> = ref("")
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName, ~key) => {
        receivedEventName := eventName
        receivedKey := key
        []
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let json = JSON.Encode.object(
        Dict.fromArray([
          ("eventName", JSON.Encode.string("ObjectCreated:Put")),
          ("key", JSON.Encode.string("uploads/file.csv")),
        ]),
      )
      let _ = await handler(json, ())
      expect(receivedEventName.contents)->toBe("ObjectCreated:Put")
      expect(receivedKey.contents)->toBe("uploads/file.csv")
    })

    testPromise("uses 'ObjectCreated' when JSON has no eventName field", async () => {
      let receivedEventName: ref<string> = ref("")
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName, ~key as _) => {
        receivedEventName := eventName
        []
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let json = JSON.Encode.object(
        Dict.fromArray([("key", JSON.Encode.string("some/path"))]),
      )
      let _ = await handler(json, ())
      expect(receivedEventName.contents)->toBe("ObjectCreated")
    })

    testPromise("uses empty string when JSON has no key field", async () => {
      let receivedKey: ref<string> = ref("initial")
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName as _, ~key) => {
        receivedKey := key
        []
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let json = JSON.Encode.object(
        Dict.fromArray([("eventName", JSON.Encode.string("ObjectRemoved"))]),
      )
      let _ = await handler(json, ())
      expect(receivedKey.contents)->toBe("")
    })

    testPromise("non-object JSON uses 'ObjectCreated' and empty string for key", async () => {
      let receivedEventName: ref<string> = ref("")
      let receivedKey: ref<string> = ref("initial")
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName, ~key) => {
        receivedEventName := eventName
        receivedKey := key
        []
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let _ = await handler(JSON.Encode.string("not-an-object"), ())
      expect(receivedEventName.contents)->toBe("ObjectCreated")
      expect(receivedKey.contents)->toBe("")
    })

    testPromise("non-string eventName field falls back to ObjectCreated", async () => {
      let receivedEventName: ref<string> = ref("")
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName, ~key as _) => {
        receivedEventName := eventName
        []
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let json = JSON.Encode.object(
        Dict.fromArray([("eventName", JSON.Encode.int(42))]),
      )
      let _ = await handler(json, ())
      expect(receivedEventName.contents)->toBe("ObjectCreated")
    })

    testPromise("returns task actions from callback", async () => {
      let callback: ReventlessCore.Task.bucketCallback = async (~eventName as _, ~key as _) => {
        [ReventlessCore.Task.DeleteSchedule("my-schedule")]
      }
      let handler = TaskBucket_InMemory.makeHandler(callback)
      let json = JSON.Encode.object(Dict.fromArray([]))
      let actions = await handler(json, ())
      expect(actions->Array.length)->toBe(1)
    })
  })

  describe("make", () => {
    testPromise(
      "returns one dummy resource so Task_Builder can access resources[0]",
      async () => {
        let bucket = TaskBucket_InMemory.make(~name="my-bucket", ~opts={})
        expect(bucket.resources->Array.length)->toBe(1)
      },
    )
  })
})

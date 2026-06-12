// Tests for the Aggregate decide-rejection propagation path.
// Verifies that domain rejections from Behavior.decide:
//   1. Surface to producers via CommandTopic_Helpers.rejectedResultChannel (with errorCode + detail)
//   2. Return Ok(reference) so async (SQS) consumers delete the message — domain rejections don't redeliver
//   3. Don't cancel surviving commands inside the same batch

open JestGlobals
open AggregateFixtures

let _ = beforeEach(() => mock.reset())

// Captures whatever flows through CommandTopic_Helpers.reportRejected during a test.
let capturedRejections: ref<array<(string, CommandTopic_Helpers.rejectedResult)>> = ref([])
let capturedAccepts: ref<array<(string, CommandTopic_Helpers.acceptedResult)>> = ref([])

let installChannels = () => {
  capturedRejections := []
  capturedAccepts := []
  CommandTopic_Helpers.rejectedResultChannel.contents = Some(
    (ref, info) => capturedRejections := capturedRejections.contents->Array.concat([(ref, info)]),
  )
  CommandTopic_Helpers.acceptedResultChannel.contents = Some(
    (ref, info) => capturedAccepts := capturedAccepts.contents->Array.concat([(ref, info)]),
  )
}

let uninstallChannels = () => {
  CommandTopic_Helpers.rejectedResultChannel.contents = None
  CommandTopic_Helpers.acceptedResultChannel.contents = None
}

describe("Aggregate decide-rejection propagation:", () => {
  describe("single rejected command", () => {
    testPromise("Create on existing aggregate reports Rejected with errorCode", async () => {
      // Seed: aggregate already created → second Create rejects with AlreadyExists.
      let _ =
        await Stream.fromIterable([
          makeTopicItem("ref-seed", AggSpec.Create({name: "Widget"})),
        ])->TestHandler.handleCommands->Effect.runPromise

      installChannels()
      let results =
        await Stream.fromIterable([
          makeTopicItem("ref-1", AggSpec.Create({name: "Widget"})),
        ])->TestHandler.handleCommands->Effect.runPromise
      uninstallChannels()

      // Producer sees Rejected on the channel; SQS sees Ok (delete — don't redeliver).
      expect(results)->toEqual([Ok("ref-1")])
      expect(capturedRejections.contents->Array.length)->toBe(1)
      let (ref, info) = capturedRejections.contents->Array.getUnsafe(0)
      expect(ref)->toEqual("ref-1")
      expect(info.errorCode)->toEqual("AlreadyExists")
      // No event was appended.
      expect(mock.getAll()->Array.length)->toBe(1)
    })
  })

  describe("mixed batch", () => {
    testPromise("rejected command does not cancel surviving commands", async () => {
      // Seed.
      let _ =
        await Stream.fromIterable([
          makeTopicItem(~aggId="agg-1", "ref-seed", AggSpec.Create({name: "Widget"})),
        ])->TestHandler.handleCommands->Effect.runPromise

      installChannels()
      // Batch on the same aggregate: Rename (ok) → Create (rejects) → Rename (ok)
      let results =
        await Stream.fromIterable([
          makeTopicItem(~aggId="agg-1", "ref-1", AggSpec.Rename({newName: "First"})),
          makeTopicItem(~aggId="agg-1", "ref-2", AggSpec.Create({name: "Boom"})),
          makeTopicItem(~aggId="agg-1", "ref-3", AggSpec.Rename({newName: "Last"})),
        ])->TestHandler.handleCommands->Effect.runPromise
      uninstallChannels()

      // All three references map to Ok (rejected ones still Ok — SQS deletes).
      expect(results->Array.length)->toBe(3)
      results->Array.forEach(r =>
        switch r {
        | Ok(_) => ()
        | Error(_) => expect("expected all Ok")->toEqual("got Error")
        }
      )
      // Two Renamed events appended (the rejected Create produced none).
      // Seed = 1, plus 2 Renamed = 3 stored.
      expect(mock.getAll()->Array.length)->toBe(3)
      // ref-2 reported as Rejected with AlreadyExists.
      let rejected = capturedRejections.contents
      expect(rejected->Array.length)->toBe(1)
      let (rRef, rInfo) = rejected->Array.getUnsafe(0)
      expect(rRef)->toEqual("ref-2")
      expect(rInfo.errorCode)->toEqual("AlreadyExists")
      // ref-1 and ref-3 reported as Accepted (eventCount > 0 against the appended batch).
      let accepted = capturedAccepts.contents
      expect(accepted->Array.length)->toBe(2)
    })
  })

  describe("all-reject batch", () => {
    testPromise("3 rejecting commands → no append, all reported Rejected, no Accepted", async () => {
      // No seed → empty history. Rename on a NotCreated aggregate rejects with NotFound.
      installChannels()
      let results =
        await Stream.fromIterable([
          makeTopicItem(~aggId="agg-x", "ref-1", AggSpec.Rename({newName: "A"})),
          makeTopicItem(~aggId="agg-x", "ref-2", AggSpec.Rename({newName: "B"})),
          makeTopicItem(~aggId="agg-x", "ref-3", AggSpec.Rename({newName: "C"})),
        ])->TestHandler.handleCommands->Effect.runPromise
      uninstallChannels()

      expect(results)->toEqual([Ok("ref-1"), Ok("ref-2"), Ok("ref-3")])
      // No events appended.
      expect(mock.getAll()->Array.length)->toBe(0)
      // All three reported as Rejected.
      expect(capturedRejections.contents->Array.length)->toBe(3)
      capturedRejections.contents->Array.forEach(((_ref, info)) =>
        expect(info.errorCode)->toEqual("NotFound")
      )
      // No Accepted callbacks fired (when nothing is appended and nothing is OK).
      expect(capturedAccepts.contents->Array.length)->toBe(0)
    })
  })

  describe("payload-less variant errors", () => {
    testPromise("errorDetail is empty string for unit-payload variants", async () => {
      // AggSpec.error variants are all payload-less (NotFound | AlreadyExists).
      installChannels()
      let _ =
        await Stream.fromIterable([
          makeTopicItem("ref-1", AggSpec.Rename({newName: "X"})),
        ])->TestHandler.handleCommands->Effect.runPromise
      uninstallChannels()

      let (_ref, info) = capturedRejections.contents->Array.getUnsafe(0)
      expect(info.errorDetail)->toEqual("")
    })
  })
})

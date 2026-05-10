// Tests for CommandTopic_Helpers.runInlineAndCollect — verifies the precedence rules
// for the rejected/accepted side-channels and the synthesized "Conflict" Error result.

open AsyncTest
open AsyncTest.Expect

let metaWithMsgId = (msgId): Reventless.Message.meta => {
  service: "TestService",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId,
  correlationId: "corr-1",
}

let cmdJson = (msgId): Reventless.Message.commandJson => {
  id: "agg-1",
  meta: metaWithMsgId(msgId),
  commandJson: JSON.Encode.object(Dict.fromArray([("TAG", JSON.Encode.string("Noop"))])),
}

describe("CommandTopic_Helpers.runInlineAndCollect:", () => {
  testPromise("Rejected from rejectedResultChannel beats Accepted from acceptedResultChannel", async () => {
    let handler: CommandTopic_Helpers.jsonCommandsHandler = stream =>
      stream
      ->Stream.runCollect
      ->Effect.map(items => {
        items->Array.forEach(item => {
          // Both channels report for the same reference; rejected wins.
          CommandTopic_Helpers.reportAccepted(item.reference, {entityId: "agg-1", eventCount: 0})
          CommandTopic_Helpers.reportRejected(
            item.reference,
            {errorCode: "AlreadyExists", errorDetail: ""},
          )
        })
        items->Array.map(item => Ok(item.reference))
      })

    let outcomes = await CommandTopic_Helpers.runInlineAndCollect([cmdJson("msg-1")], handler)
    expect(outcomes->Array.length)->toBe(1)
    switch outcomes->Array.getUnsafe(0) {
    | Rejected({msgId, errorCode, errorDetail}) =>
      expect(msgId)->toEqual("msg-1")
      expect(errorCode)->toEqual("AlreadyExists")
      expect(errorDetail)->toEqual(None)
    | Accepted(_) | Pending(_) => expect("expected Rejected")->toEqual("got other")
    }
  })

  testPromise("Rejected from rejectedResultChannel beats Error result (synthesized Conflict)", async () => {
    let handler: CommandTopic_Helpers.jsonCommandsHandler = stream =>
      stream
      ->Stream.runCollect
      ->Effect.map(items => {
        items->Array.forEach(item =>
          CommandTopic_Helpers.reportRejected(
            item.reference,
            {errorCode: "BusinessRuleViolated", errorDetail: "{\"reason\":\"x\"}"},
          )
        )
        // Handler still returns Error — rejectedChannel takes precedence.
        items->Array.map(item => Error(item.reference))
      })

    let outcomes = await CommandTopic_Helpers.runInlineAndCollect([cmdJson("msg-1")], handler)
    switch outcomes->Array.getUnsafe(0) {
    | Rejected({errorCode, errorDetail}) =>
      expect(errorCode)->toEqual("BusinessRuleViolated")
      expect(errorDetail)->toEqual(Some("{\"reason\":\"x\"}"))
    | Accepted(_) | Pending(_) => expect("expected Rejected")->toEqual("got other")
    }
  })

  testPromise("Error result without rejectedChannel still synthesizes Conflict", async () => {
    let handler: CommandTopic_Helpers.jsonCommandsHandler = stream =>
      stream->Stream.runCollect->Effect.map(items => items->Array.map(item => Error(item.reference)))

    let outcomes = await CommandTopic_Helpers.runInlineAndCollect([cmdJson("msg-1")], handler)
    switch outcomes->Array.getUnsafe(0) {
    | Rejected({errorCode}) => expect(errorCode)->toEqual("Conflict")
    | _ => expect("expected Rejected(Conflict)")->toEqual("got other")
    }
  })
})

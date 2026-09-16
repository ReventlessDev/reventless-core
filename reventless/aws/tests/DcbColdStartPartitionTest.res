// The DCB command Lambda refuses to start when its partition keys cannot be
// derived, and says why on every invocation.
//
// Deploy derives the same keys from the same slices, so this only fails when the
// framework in the Lambda layer differs from the one deploy used. Carrying on
// would file events under the wrong keys; refusing sends messages to the DLQ.

open JestGlobals

type afterFailedStartup = {messages: array<string>, unhandled: array<string>}

@module("./dcbColdStartPartition.mjs")
external invokeAfterFailedStartup: unit => promise<afterFailedStartup> = "invokeAfterFailedStartup"

@module("./dcbColdStartPartition.mjs")
external startWithUnresolvedSlice: unit => promise<string> = "startWithUnresolvedSlice"

describe("DcbCommandTopicEntryPoint cold start", () => {
  test("a slice whose partition cannot be inferred stops startup, naming it", async () => {
    let message = await startWithUnresolvedSlice()
    expect(message->String.includes("LinkGadget"))->toBe(true)
    expect(message->String.includes("@partitionTag"))->toBe(true)
  })

  test("after a failed startup every invocation rethrows the same error", async () => {
    let {messages, unhandled} = await invokeAfterFailedStartup()
    expect(messages->Array.length)->toBe(2)
    expect(messages->Array.includes("resolved"))->toBe(false)
    expect(messages->Array.getUnsafe(0))->toBe(messages->Array.getUnsafe(1))
    expect(unhandled)->toEqual([])
  })
})

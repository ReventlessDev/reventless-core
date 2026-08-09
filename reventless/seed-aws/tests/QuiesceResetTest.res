// Holding a stack's runtimes still for the length of a wipe: what gets held, and
// what the reset says when a store comes back anyway.
//
// A truncate is not durable while the runtimes that own the data are running — a
// slice runtime keeps its TODO list in memory for the life of its execution
// environment and re-saves every row it holds at the end of each invocation,
// including the scheduled sweep that carries no events. So the reset now
// discovers the stack's Lambda functions alongside its stores and holds them at
// zero concurrency across the wipe.
//
// The pure half of that is what these pin: which ARNs resolve to a function to
// hold, the bounded fan-out the control-plane calls go through, and the failure
// message — which used to say "re-run to finish" for a condition re-running
// could not clear. The impure half is the Lambda control-plane calls themselves.

open JestGlobals

module Reset = ReventlessSeedAws_Reset
module Quiesce = ReventlessSeedAws_Quiesce

describe("classify", () => {
  testSync("reads the function name out of a Lambda ARN", () =>
    expect(Reset.classify("arn:aws:lambda:eu-west-1:123456789012:function:AllAutomationSlices-28b116c"))
    ->toEqual(Reset.Function("AllAutomationSlices-28b116c"))
  )

  // The tagging API returns unqualified ARNs, but a qualified one must still
  // yield the function name — every Lambda control-plane call the hold makes
  // takes a name, and "Name:1" is not one.
  testSync("drops a version or alias qualifier", () =>
    expect(Reset.classify("arn:aws:lambda:eu-west-1:123456789012:function:AllReadModels-0287438:42"))
    ->toEqual(Reset.Function("AllReadModels-0287438"))
  )

  testSync("still classifies tables and buckets", () => {
    expect(Reset.classify("arn:aws:dynamodb:eu-west-1:123456789012:table/Products-0ba6849"))
    ->toEqual(Reset.Table("Products-0ba6849"))
    expect(Reset.classify("arn:aws:s3:::alpha-product-images"))->toEqual(
      Reset.Bucket("alpha-product-images"),
    )
  })

  testSync("ignores anything else the tag scope returns", () =>
    expect(Reset.classify("arn:aws:sqs:eu-west-1:123456789012:OrderingDcbCmdTopic-4b3658c"))
    ->toEqual(Reset.Other)
  )
})

describe("mapBounded", () => {
  // Results must line up with their inputs regardless of which worker finished
  // first: the hold pairs each result with the function it came from, and a
  // shuffled array would restore the wrong concurrency to the wrong function.
  test("keeps results in input order under out-of-order completion", async () => {
    let delays = [40, 0, 30, 10, 20, 5]
    let out = await delays->Quiesce.mapBounded(~limit=3, async ms => {
      await ReventlessSeed.Seed.Client.sleep(ms)
      ms
    })
    expect(out)->toEqual(delays)
  })

  test("never runs more than the limit at once", async () => {
    let inFlight = ref(0)
    let peak = ref(0)
    let _ = await Array.make(~length=12, 0)->Quiesce.mapBounded(~limit=4, async _ => {
      inFlight := inFlight.contents + 1
      peak := Math.Int.max(peak.contents, inFlight.contents)
      await ReventlessSeed.Seed.Client.sleep(5)
      inFlight := inFlight.contents - 1
    })
    expect(peak.contents)->toBe(4)
  })

  test("an empty list spawns no workers and returns nothing", async () => {
    let out = await []->Quiesce.mapBounded(~limit=4, async x => x)
    expect(out->Array.length)->toBe(0)
  })
})

describe("refillMessage", () => {
  // The whole point of the change: the operator has to be able to see WHICH
  // store came back, not just a total.
  testSync("names every store that came back, with its count", () => {
    let message = Reset.refillMessage(
      ~refilled=[("AutoShipOrderTodo-61f39a2", 12), ("GeocodeCustomerAddressTodo-50d9488", 1)],
      ~heldCount=41,
    )
    expect(message->String.includes("AutoShipOrderTodo-61f39a2"))->toBe(true)
    expect(message->String.includes("GeocodeCustomerAddressTodo-50d9488"))->toBe(true)
    expect(message->String.startsWith("13 item(s)/object(s) came back"))->toBe(true)
  })

  // Under a hold nothing could START during the wipe, so the only writer left is
  // an invocation already running when the hold landed — and that one really
  // does go away. This is the only case where "re-run" is honest advice.
  testSync("advises re-running only when the runtimes were held", () => {
    let message = Reset.refillMessage(~refilled=[("AutoShipOrderTodo-61f39a2", 12)], ~heldCount=41)
    expect(message->String.includes("already in flight"))->toBe(true)
    expect(message->String.includes("Re-running clears it"))->toBe(true)
  })

  // Without a hold, the writer holds the rows in memory and restores them every
  // invocation — the exact condition the old "re-run to finish" sent operators
  // round in circles on. It must not appear here.
  testSync("refuses to advise re-running when the stack was not held", () => {
    let message = Reset.refillMessage(~refilled=[("AutoShipOrderTodo-61f39a2", 12)], ~heldCount=0)
    expect(message->String.includes("re-running will not help"->String.toLowerCase))->toBe(true)
    expect(message->String.includes("SEED_RESET_NO_QUIESCE"))->toBe(true)
  })
})

describe("noQuiesce", () => {
  let set = v => NodeProcess.env->Dict.set("SEED_RESET_NO_QUIESCE", v)

  // Fail-closed: the hold is what makes the wipe durable, so anything other than
  // a deliberate opt-out keeps it on.
  testSync("defaults to holding the platform", () => {
    set("")
    expect(Reset.noQuiesce())->toBe(false)
    set("0")
    expect(Reset.noQuiesce())->toBe(false)
    set("no")
    expect(Reset.noQuiesce())->toBe(false)
  })

  testSync("accepts the spellings an operator would actually type", () => {
    ["1", "true", "TRUE", " yes "]->Array.forEach(v => {
      set(v)
      expect(Reset.noQuiesce())->toBe(true)
    })
    set("")
  })
})

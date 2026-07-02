// Regression tests for the CLI runner's per-test deadline (A2) and the
// Collector's skip-depth reset (A4). Before A2 a hung test body wedged the whole
// run — `runEntry` awaited it with no deadline. Before A4 a throwing `xdescribe`
// left `skipDepth` > 0, silently skipping every subsequently loaded file; the
// reset lives in `Collector.activate`.

open JestGlobals

@val external setTimeout: (unit => unit, int) => unit = "setTimeout"

let hangingEntry = (~timeout): Collector.entry => {
  id: "hangs",
  name: "hangs forever",
  describePath: [],
  slice: None,
  // A body that never resolves — the pathological hung test.
  body: () => Promise.make((_resolve, _reject) => ()),
  status: Collector.Runnable,
  location: None,
  timeout,
}

describe("Cli.runEntry deadline", () => {
  testPromise("a hung body is reported as a timeout, not a wedge", async () => {
    let r = await Cli.runEntry(hangingEntry(~timeout=Some(50)))
    expect(r.status)->toEqual(RunnerTypes.Fail)
    switch r.mismatch {
    | Some(Outcome.Throw({error})) => expect(error->String.includes("timed out"))->toEqual(true)
    | _ => JsError.throwWithMessage("expected a timeout Throw mismatch")
    }
  })

  testPromise("a body that resolves within the deadline passes", async () => {
    let entry: Collector.entry = {
      id: "ok",
      name: "resolves fast",
      describePath: [],
      slice: None,
      body: () => Promise.resolve(Outcome.pass),
      status: Collector.Runnable,
      location: None,
      timeout: Some(1000),
    }
    let r = await Cli.runEntry(entry)
    expect(r.status)->toEqual(RunnerTypes.Pass)
  })
})

describe("Collector.activate", () => {
  testSync("resets a leaked skipDepth to zero", () => {
    // Simulate the leak a throwing xdescribe body would leave behind.
    Collector.skipDepth := 3
    Collector.activate()
    expect(Collector.skipDepth.contents)->toEqual(0)
    Collector.deactivate()
  })
})

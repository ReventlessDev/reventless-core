// Unit tests for BuildClassifier — the state machine that turns a
// `rescript build -w` line-stream into buildStart / buildOk / buildFail. The
// success path is synchronous (the "Finished … compilation" line); the failure
// path is debounced (no terminator in rescript's error output), so those tests
// await past the 400ms settle window.

open AsyncTest
open AsyncTest.Expect

@val external setTimeout: (unit => unit, int) => unit = "setTimeout"
let delay = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => setTimeout(() => resolve(), ms))

describe("BuildClassifier", () => {
  testPromise("emits onStart then onOk for a clean incremental compile", async () => {
    let starts = ref(0)
    let oks = ref(0)
    let fails = ref([])
    let feed = BuildClassifier.make({
      onStart: () => starts := starts.contents + 1,
      onOk: _ms => oks := oks.contents + 1,
      onFail: msg => fails := Array.concat(fails.contents, [msg]),
    })
    feed("Parsed 1 source files")
    feed("Compiled 1 modules")
    feed("Finished incremental compilation")
    expect(starts.contents)->toEqual(1)
    expect(oks.contents)->toEqual(1)
    expect(fails.contents->Array.length)->toEqual(0)
  })

  testPromise("emits onFail with the error text after the output settles", async () => {
    let oks = ref(0)
    let fails = ref([])
    let feed = BuildClassifier.make({
      onStart: () => (),
      onOk: _ms => oks := oks.contents + 1,
      onFail: msg => fails := Array.concat(fails.contents, [msg]),
    })
    feed("Parsed 1 source files")
    feed("Compiled 1 modules")
    feed("We've found a bug for you!")
    feed("This has type: string")
    feed("But it's expected to have type: int")
    await delay(550)
    expect(oks.contents)->toEqual(0)
    expect(fails.contents->Array.length)->toEqual(1)
    let msg = fails.contents->Array.getUnsafe(0)
    expect(msg->String.includes("This has type: string"))->toEqual(true)
  })

  testPromise("watchdog fails a build that starts but never terminates", async () => {
    let oks = ref(0)
    let fails = ref([])
    let feed = BuildClassifier.make(~watchdogMs=50, {
      onStart: () => (),
      onOk: _ms => oks := oks.contents + 1,
      onFail: msg => fails := Array.concat(fails.contents, [msg]),
    })
    feed("Parsed 1 source files")
    // No "Finished …" and no error marker — a crashed/hung watcher.
    await delay(120)
    expect(oks.contents)->toEqual(0)
    expect(fails.contents->Array.length)->toEqual(1)
    let msg = fails.contents->Array.getUnsafe(0)
    expect(msg->String.includes("watchdog"))->toEqual(true)
  })

  testPromise("watchdog does not fire once the build finishes", async () => {
    let oks = ref(0)
    let fails = ref([])
    let feed = BuildClassifier.make(~watchdogMs=50, {
      onStart: () => (),
      onOk: _ms => oks := oks.contents + 1,
      onFail: msg => fails := Array.concat(fails.contents, [msg]),
    })
    feed("Parsed 1 source files")
    feed("Finished incremental compilation")
    await delay(120)
    expect(oks.contents)->toEqual(1)
    expect(fails.contents->Array.length)->toEqual(0)
  })

  testPromise("strips ANSI colour codes before matching the finish line", async () => {
    let oks = ref(0)
    let feed = BuildClassifier.make({
      onStart: () => (),
      onOk: _ms => oks := oks.contents + 1,
      onFail: _msg => (),
    })
    feed("Parsed 2 source files")
    feed("\x1b[1;32mFinished incremental compilation\x1b[0m")
    expect(oks.contents)->toEqual(1)
  })
})

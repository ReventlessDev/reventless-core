// Unit tests for Logger.debugLazy (B6): the message thunk must run only when
// debug output is actually enabled, so hot paths (per-projection-action logging)
// don't pay to build/serialize a string that is dropped at Info level.

open JestGlobals

describe("Logger.debugLazy", () => {
  testSync("does NOT invoke the thunk at the default Info level", () => {
    let called = ref(false)
    let log = Logger.makeLogger(~minLevel=Logger.Info)
    log.debugLazy(~comp="Test", () => {
      called := true
      "should never be built"
    })
    expect(called.contents)->toEqual(false)
  })

  testSync("invokes the thunk when debug output is enabled", () => {
    let called = ref(false)
    let log = Logger.makeLogger(~minLevel=Logger.Debug)
    log.debugLazy(~comp="Test", () => {
      called := true
      "built"
    })
    expect(called.contents)->toEqual(true)
  })

  testSync("the silent logger never invokes the thunk", () => {
    let called = ref(false)
    Logger.silent.debugLazy(~comp="Test", () => {
      called := true
      "x"
    })
    expect(called.contents)->toEqual(false)
  })
})

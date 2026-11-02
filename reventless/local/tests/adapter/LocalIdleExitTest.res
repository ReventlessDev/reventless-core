// A platform left running for an editor stops once nothing has watched it for its grace, and keeps
// running while something does.

open JestGlobals

let wait = ms =>
  Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), ms)
  })

describe("LocalIdleExit", () => {
  let stopped = ref(0)
  beforeEach(() => {
    LocalIdleExit.reset()
    stopped := 0
    LocalIdleExit.onIdle := (() => stopped := stopped.contents + 1)
  })
  afterEach(() => LocalIdleExit.reset())

  testSync("reads its grace in seconds, and nothing else turns it on", () => {
    expect(LocalIdleExit.graceOf(Some("60")))->toEqual(Some(60_000))
    expect(LocalIdleExit.graceOf(Some("0")))->toEqual(None)
    expect(LocalIdleExit.graceOf(Some("soon")))->toEqual(None)
    expect(LocalIdleExit.graceOf(None))->toEqual(None)
  })

  testPromise("stops when nothing connects within its grace", async () => {
    LocalIdleExit.start(~env=dict{"REVENTLESS_IDLE_EXIT": "1"})
    await wait(1200)
    expect(stopped.contents)->toBe(1)
  })

  testPromise(
    "keeps running while watched, and a watcher back in time keeps it running",
    async () => {
      LocalIdleExit.start(~env=dict{"REVENTLESS_IDLE_EXIT": "1"})
      LocalIdleExit.connected()
      await wait(1200)
      expect(stopped.contents)->toBe(0)
      // A reload: the watcher goes and comes back within the grace.
      LocalIdleExit.disconnected()
      await wait(500)
      LocalIdleExit.connected()
      await wait(800)
      expect(stopped.contents)->toBe(0)
      LocalIdleExit.disconnected()
      await wait(1200)
      expect(stopped.contents)->toBe(1)
    },
  )

  testPromise("does nothing without the variable", async () => {
    LocalIdleExit.start(~env=dict{})
    await wait(1200)
    expect(stopped.contents)->toBe(0)
  })
})

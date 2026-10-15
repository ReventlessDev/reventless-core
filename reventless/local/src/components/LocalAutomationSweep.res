// The local platform's automation sweep. As on AWS, one sweep serves every
// automation: each interval it runs every slice's `processPending`, one after
// another, so an item `process` left pending or one whose command failed is tried
// again without waiting for the next event. The interval is five minutes, as on
// AWS; REVENTLESS_LOCAL_SWEEP_SECONDS shortens it for development.

let defaultIntervalSeconds = 300

let intervalSeconds = () =>
  switch NodeProcess.env
  ->Dict.get("REVENTLESS_LOCAL_SWEEP_SECONDS")
  ->Option.flatMap(s => Int.fromString(s)) {
  | Some(seconds) if seconds > 0 => seconds
  | _ => defaultIntervalSeconds
  }

let sweeps: dict<unit => promise<unit>> = Dict.make()
let timer: ref<option<NodeTimers.timeout>> = ref(None)
let running = ref(false)

/** Runs every registered slice's sweep once. A failing slice is logged and the rest still run;
    a sweep still running when the next one is due is not started twice. */
let sweepOnce = async () =>
  if !running.contents {
    running := true
    let _ = await sweeps
    ->Dict.toArray
    ->Array.reduce(Promise.resolve(), async (previous, (name, sweep)) => {
      await previous
      try await sweep() catch {
      | exn =>
        let message =
          exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        ReventlessCore.EffectLogger.logError(
          ~comp="LocalAutomationSweep",
          `sweep of ${name} failed: ${message}`,
        )->Effect.runSync
      }
    })
    running := false
  }

/** Adds a slice's sweep, replacing one of the same name; the first starts the timer. */
let register = (~name, sweep) => {
  sweeps->Dict.set(name, sweep)
  if timer.contents->Option.isNone {
    let handle = NodeTimers.setInterval(() => {
      let _ = sweepOnce()
    }, intervalSeconds() * 1000)
    // A backstop: never the reason a process stays up.
    handle->NodeTimers.unref
    timer := Some(handle)
  }
}

/** Stops the timer and forgets every sweep — call in afterAll/afterEach for test isolation. */
let reset = () => {
  timer.contents->Option.forEach(NodeTimers.clearInterval)
  timer := None
  sweeps->Dict.keysToArray->Array.forEach(name => sweeps->Dict.delete(name))
}

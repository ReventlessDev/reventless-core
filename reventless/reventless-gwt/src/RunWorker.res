// Worker entry for a single gwt watch re-run pass.
//
// Spawned by `Cli.runWatch` with the run `options` passed as `workerData`. Runs
// exactly one `runOnce` in this fresh worker (fresh ESM registry → recompiled
// implementation modules are re-imported, not served stale), emits its NDJSON to
// stdout (piped to the parent), then exits so the imported graph is reclaimed.
// The parent never reuses a worker — one per re-run.

@val @module("node:worker_threads") external workerData: Cli.options = "workerData"
@val external processExit: int => unit = "process.exit"

let () = {
  let _ =
    Cli.runOnce(workerData)
    ->Promise.then(code => {
      processExit(code)
      Promise.resolve()
    })
    ->Promise.catch(e => {
      Console.error2("gwt run worker failed:", e)
      processExit(1)
      Promise.resolve()
    })
}

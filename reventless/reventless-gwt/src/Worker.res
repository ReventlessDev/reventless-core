// Minimal `node:worker_threads` binding for gwt watch re-runs.
//
// Node's ESM module registry is keyed by URL and never evicts, so re-importing a
// recompiled test file in the same process replays tests that close over the
// *old* instances of their statically-imported implementation modules (the
// Loader can only cache-bust the test file's own URL, not its transitive
// imports). Running each watch re-run in a short-lived Worker gives it a fresh
// registry — the recompiled modules are re-imported — and reclaims the whole
// imported graph on worker exit (fixing the monotonic-buster memory leak).

type t
type workerOptions<'a> = {workerData: 'a}
type url

@new @module("node:worker_threads")
external make: (url, workerOptions<'a>) => t = "Worker"

// A worker's stdout is piped to the parent's process.stdout by default, so the
// NDJSON the formatters write inside the worker reaches the client unchanged.
@send external on: (t, string, 'cb) => unit = "on"
@send external terminate: t => promise<int> = "terminate"

// The compiled worker entry lives next to this module in the in-source build.
let runWorkerUrl: url = %raw(`new URL("./RunWorker.res.mjs", import.meta.url)`)

/** Bindings for [`node:worker_threads`](https://nodejs.org/api/worker_threads.html):
    running a module in a thread of its own, with its own module registry, and
    talking to it by message. A worker's `stdout` goes to the parent's by
    default. */
type worker

/** What a worker starts with. `workerData` arrives as `NodeWorkerThreads.workerData`
    in the worker, structurally cloned, not shared. */
type workerOptions<'a> = {workerData?: 'a}

/** Starts the module at `filename`, an absolute path (or one relative to the
    working directory). A `file:` URL as a string is not one: convert it with
    `NodeUrl.fileURLToPath` first. */
@new @module("node:worker_threads")
external make: (string, workerOptions<'a>) => worker = "Worker"

/** Stops the worker as soon as it can; resolves with its exit code. */
@send external terminate: worker => promise<int> = "terminate"

/** A message the worker posted to `parentPort`. Its type is whatever the worker
    sends: the caller names it. */
@send
external onMessage: (worker, @as("message") _, 'a => unit) => worker = "on"

/** The worker threw and did not catch it; it stops after this. */
@send
external onError: (worker, @as("error") _, JsExn.t => unit) => worker = "on"

/** The worker has stopped, with its exit code: the last event. */
@send
external onExit: (worker, @as("exit") _, int => unit) => worker = "on"

/** The worker's end of the channel to its parent. */
type messagePort

/** The channel to the parent: null in the main thread. */
@module("node:worker_threads") @val
external parentPort: Nullable.t<messagePort> = "parentPort"

@send external postMessage: (messagePort, 'a) => unit = "postMessage"

/** What the parent passed as `workerData`, in the worker: undefined in the main
    thread. Its type is whatever the parent sent: the caller names it. */
@module("node:worker_threads") @val
external workerData: 'a = "workerData"

/** Whether this code runs in the main thread rather than in a worker. */
@module("node:worker_threads") @val
external isMainThread: bool = "isMainThread"

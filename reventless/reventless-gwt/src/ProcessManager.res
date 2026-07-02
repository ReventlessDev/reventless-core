// Owns the `rescript build -w` watchers a watch session spawns — one per
// package that owns tests (PackageScan), at most one per directory,
// reference-counted by `dir`. Registered with Cancellation so SIGINT/SIGTERM
// tears down every spawned watcher; never orphans a compiler.

type managed = {
  dir: string,
  proc: ChildProcess.t,
}

let running: Dict.t<managed> = Dict.make()

// Per-dir count of unexpected watcher exits, so a build-watcher that crashes on
// startup (bad config, missing binary) is respawned a bounded number of times
// rather than either freezing the build status forever or spinning in a tight
// respawn loop.
let restarts: Dict.t<int> = Dict.make()
let maxRestarts = 3

let isManaging = (dir: string): bool =>
  switch running->Dict.get(dir) {
  | Some(_) => true
  | None => false
  }

// Spawn `pnpm run start` (the package's `rescript build -w`) in `pkg.dir`,
// unless one is already managed there. `onStdout` receives each output line so
// the caller can classify compiler markers (Phase 5).
let rec spawnWatcher = (pkg: PackageScan.pkg, ~onStdout: (string, string) => unit): unit =>
  switch running->Dict.get(pkg.dir) {
  | Some(_) => ()
  | None => {
      let proc = ChildProcess.spawn("pnpm", ["run", "start"], ~cwd=pkg.dir)
      ChildProcess.onStdoutLine(proc, line => onStdout(pkg.dir, line))
      // stderr carries compiler/pnpm crash output; without this a watcher that
      // dies on stderr was invisible until the caller's 120s watchdog.
      ChildProcess.onStderrLine(proc, line => onStdout(pkg.dir, line))
      // A spawn failure ("error") never reaches "close"; surface it as output.
      ChildProcess.onError(proc, msg => onStdout(pkg.dir, msg))
      // Detect an unexpected exit. We compare the stored proc identity: an
      // intentional `stop` deletes the entry synchronously before "close" fires,
      // so if we still own this exact proc, the watcher crashed — respawn it up
      // to `maxRestarts` times so build status doesn't freeze.
      ChildProcess.onClose(proc, _code =>
        switch running->Dict.get(pkg.dir) {
        | Some(m) if m.proc === proc =>
          running->Dict.delete(pkg.dir)
          let n = restarts->Dict.get(pkg.dir)->Option.getOr(0)
          if n < maxRestarts {
            restarts->Dict.set(pkg.dir, n + 1)
            spawnWatcher(pkg, ~onStdout)
          }
        | _ => ()
        }
      )
      running->Dict.set(pkg.dir, {dir: pkg.dir, proc})
    }
  }

// Stop just the watcher managed for `dir` (if any), tearing down its process
// group. Returns true when one was running — i.e. the caller *owned* this
// package's build (vs. an adopted external watcher, which we can't stop).
let stop = (dir: string): bool =>
  switch running->Dict.get(dir) {
  | Some(m) => {
      ChildProcess.killTree(m.proc, "SIGTERM")
      running->Dict.delete(dir)
      true
    }
  | None => false
  }

// Force a full re-emit of `pkg` after a structural change — a module relocation
// that incremental compilation can't detect, since it keys invalidation on
// source + dependency-interface hashes, never on a dependency's filesystem
// location (see plan Phase 12). Drives a deterministic one-shot `rescript clean`
// → `rescript build` to completion (the `clean` is what forces every dependent
// `.res.mjs` to be re-emitted against the new layout; the `build` is essential
// even on the adopted path — an external watcher won't rebuild after a clean
// without a fresh source change, so a bare clean would strand the package with
// no outputs). If we *owned* the package's watcher we stop it first (no lock
// contention) and respawn it afterward to resume incremental watching; on the
// adopted path the developer's own watcher keeps running untouched. `onStdout`
// streams the clean/build output (compiler markers) to the caller; `onDone`
// fires once the build completes, gating the test re-run.
let cleanRebuild = (
  pkg: PackageScan.pkg,
  ~onStdout: (string, string) => unit,
  ~onDone: bool => unit,
): unit => {
  let wasManaged = stop(pkg.dir)
  // `next` receives the step's exit code so the chain can tell a failed clean or
  // build (non-zero / crash) from success — the previous shape discarded exit
  // codes and always reported the rebuild as OK, masking compile failures.
  let step = (cmd: string, args: array<string>, next: option<int> => unit): unit => {
    let proc = ChildProcess.spawn(cmd, args, ~cwd=pkg.dir)
    // "error" (spawn failure) and "close" can both fire; ensure the chain
    // advances exactly once.
    let settled = ref(false)
    let settle = (code: option<int>) =>
      if !settled.contents {
        settled := true
        next(code)
      }
    ChildProcess.onStdoutLine(proc, line => onStdout(pkg.dir, line))
    ChildProcess.onStderrLine(proc, line => onStdout(pkg.dir, line))
    ChildProcess.onError(proc, msg => {
      onStdout(pkg.dir, msg)
      settle(None)
    })
    ChildProcess.onClose(proc, code => settle(code))
  }
  step("pnpm", ["exec", "rescript", "clean"], _cleanCode =>
    step("pnpm", ["exec", "rescript", "build"], buildCode => {
      if wasManaged {
        spawnWatcher(pkg, ~onStdout)
      }
      onDone(buildCode == Some(0))
    })
  )
}

// SIGTERM, not SIGINT: a POSIX shell sets background children to ignore SIGINT,
// so SIGINT can leak a watcher; SIGTERM tears down the whole group reliably
// (verified across foreground and background process-tree shapes).
let killAll = (): unit => {
  running
  ->Dict.valuesToArray
  ->Array.forEach(m => ChildProcess.killTree(m.proc, "SIGTERM"))
  running
  ->Dict.keysToArray
  ->Array.forEach(k => running->Dict.delete(k))
}

let managedCount = (): int => running->Dict.keysToArray->Array.length

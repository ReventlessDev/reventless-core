// Owns the `rescript build -w` watchers a watch session spawns — one per
// package that owns tests (PackageScan), at most one per directory,
// reference-counted by `dir`. Registered with Cancellation so SIGINT/SIGTERM
// tears down every spawned watcher; never orphans a compiler.

type managed = {
  dir: string,
  proc: ChildProcess.t,
}

let running: Dict.t<managed> = Dict.make()

let isManaging = (dir: string): bool =>
  switch running->Dict.get(dir) {
  | Some(_) => true
  | None => false
  }

// Spawn `pnpm run start` (the package's `rescript build -w`) in `pkg.dir`,
// unless one is already managed there. `onStdout` receives each output line so
// the caller can classify compiler markers (Phase 5).
let spawnWatcher = (pkg: PackageScan.pkg, ~onStdout: (string, string) => unit): unit =>
  switch running->Dict.get(pkg.dir) {
  | Some(_) => ()
  | None => {
      let proc = ChildProcess.spawn("pnpm", ["run", "start"], ~cwd=pkg.dir)
      ChildProcess.onStdoutLine(proc, line => onStdout(pkg.dir, line))
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
  ~onDone: unit => unit,
): unit => {
  let wasManaged = stop(pkg.dir)
  let step = (cmd: string, args: array<string>, next: unit => unit): unit => {
    let proc = ChildProcess.spawn(cmd, args, ~cwd=pkg.dir)
    ChildProcess.onStdoutLine(proc, line => onStdout(pkg.dir, line))
    ChildProcess.onClose(proc, _ => next())
  }
  step("pnpm", ["exec", "rescript", "clean"], () =>
    step("pnpm", ["exec", "rescript", "build"], () => {
      if wasManaged {
        spawnWatcher(pkg, ~onStdout)
      }
      onDone()
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

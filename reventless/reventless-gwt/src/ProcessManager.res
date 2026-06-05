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

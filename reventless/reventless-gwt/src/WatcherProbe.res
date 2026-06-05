// Detects whether a ReScript build watcher is already running for a package, so
// the watch manager can defer to a developer's (or rescript-vscode's) own
// watcher rather than spawn a duplicate. ReScript records the building process's
// PID in a lock file and liveness-checks it (a dead-pid lock is taken over), so
// the reliable signal is: lock present AND its pid is alive. A stale lock is
// harmless — rescript self-heals it on the next build.
//
// Two lock files exist depending on which command form started the build:
//   - `lib/watch.lock`    — canonical `rescript watch` (used by rescript-vscode
//                           ≥ 1.73's "Start Build", and the non-deprecated form)
//   - `lib/rescript.lock` — legacy `rescript build -w` (what `pnpm run start`
//                           still maps to in the example packages)
// Both must be checked: missing `watch.lock` is exactly how the rescript-vscode
// watcher slipped past an earlier rescript.lock-only probe, causing a doomed
// duplicate spawn.

@module("node:fs") external _existsSync: string => bool = "existsSync"
@module("node:fs") external _readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external join: (string, string) => string = "join"
@val external _processKillSig: (int, int) => unit = "process.kill"

// `process.kill(pid, 0)` performs no signal delivery — it only probes existence
// (throws ESRCH when the pid is gone), which is exactly the liveness check.
let isAlive = (pid: int): bool =>
  try {
    _processKillSig(pid, 0)
    true
  } catch {
  | _ => false
  }

let libLock = (dir: string, name: string): string => join(join(dir, "lib"), name)

// True when the named lock file exists and holds a live pid.
let lockHasLivePid = (lock: string): bool =>
  if _existsSync(lock) {
    switch Int.fromString(String.trim(_readFileSync(lock, "utf8"))) {
    | Some(pid) => isAlive(pid)
    | None => false
    }
  } else {
    false
  }

// True when an external watcher (either command form) already owns this
// package's build.
let hasLiveWatcher = (dir: string): bool =>
  lockHasLivePid(libLock(dir, "watch.lock")) || lockHasLivePid(libLock(dir, "rescript.lock"))

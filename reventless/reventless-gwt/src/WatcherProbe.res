// Detects whether a `rescript build -w` is already running for a package, so
// the watch manager can defer to a developer's own watcher rather than spawn a
// duplicate. ReScript v12 records the building process's PID in
// `lib/rescript.lock` and liveness-checks it (a dead-pid lock is taken over),
// so the reliable signal is: lock present AND its pid is alive. A stale lock is
// harmless — rescript self-heals it on the next build.

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

let lockPath = (dir: string): string => join(join(dir, "lib"), "rescript.lock")

// True when an external watcher already holds the package's live rescript lock.
let hasLiveWatcher = (dir: string): bool => {
  let lock = lockPath(dir)
  if _existsSync(lock) {
    switch Int.fromString(String.trim(_readFileSync(lock, "utf8"))) {
    | Some(pid) => isAlive(pid)
    | None => false
    }
  } else {
    false
  }
}

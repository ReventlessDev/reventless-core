/** Bindings for
    [`node:child_process`](https://nodejs.org/api/child_process.html). */

type execOptions = {
  cwd?: string,
  encoding?: string,
  env?: dict<string>,
  stdio?: array<string>,
  maxBuffer?: int,
}

@module("node:child_process")
external execSync: (string, execOptions) => string = "execSync"

/** Takes the arguments as an array rather than interpolating them into a shell
    string, so an argument containing shell metacharacters stays one argument. */
@module("node:child_process")
external execFileSync: (string, array<string>, execOptions) => string = "execFileSync"

/** A running child process. Unlike the `*Sync` calls above, `spawn` returns
    while the child is still alive, so the caller keeps working alongside it —
    which is the whole reason to reach for this over `execFileSync`. */
type childProcess

type spawnOptions = {
  cwd?: string,
  /** Replaces the child's environment entirely rather than extending it. Pass
      a copy of `NodeProcess.env` with the additions applied when the child
      still needs PATH and friends. */
  env?: dict<string>,
  /** Per-descriptor disposition: `"ignore"`, `"inherit"`, or `"pipe"`, in
      stdin/stdout/stderr order. */
  stdio?: array<string>,
}

@module("node:child_process")
external spawn: (string, array<string>, spawnOptions) => childProcess = "spawn"

/** `null` while the child is running, its exit code once it has exited. The
    one honest way to ask "is it still alive?" without holding an event
    listener — a caller polling for readiness checks this to tell a slow start
    from a process that already died. */
@get external exitCode: childProcess => Nullable.t<int> = "exitCode"

/** Signal the child. Returns whether the signal was delivered — `false` once
    the process is already gone, which is not an error. */
@send external kill: (childProcess, string) => bool = "kill"

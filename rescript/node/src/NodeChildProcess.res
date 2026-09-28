/** Bindings for
    [`node:child_process`](https://nodejs.org/api/child_process.html). */
type execOptions = {
  cwd?: string,
  encoding?: string,
  env?: dict<string>,
  stdio?: array<string>,
  maxBuffer?: int,
  /** Written to the child's stdin, which is then closed. */
  input?: string,
  /** Runs the command through a shell. Needed on Windows to start a `.cmd` shim
      such as `pnpm`, and for a shell builtin such as `command -v`; otherwise
      leave it off, since a shell re-splits the arguments. */
  shell?: bool,
}

@module("node:child_process")
external execSync: (string, execOptions) => string = "execSync"

/** Takes the arguments as an array rather than interpolating them into a shell
    string, so an argument containing shell metacharacters stays one argument. */
@module("node:child_process")
external execFileSync: (string, array<string>, execOptions) => string = "execFileSync"

/** Pass `encoding` to get `stdout` / `stderr` as strings. All three stay null
    when the program could not be started at all; `error` then says why. */
type spawnSyncResult = {
  status: Nullable.t<int>,
  stdout: Nullable.t<string>,
  stderr: Nullable.t<string>,
  error: Nullable.t<JsExn.t>,
}

/** Unlike `execFileSync`, never throws: a non-zero exit comes back as `status`
    with the child's `stderr`, so a caller can tell one failure from another. */
@module("node:child_process")
external spawnSync: (string, array<string>, execOptions) => spawnSyncResult = "spawnSync"

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
  /** Makes the child the leader of its own process group, so signalling the
      negated pid (`NodeProcess.killWithSignal(-pid, …)`) reaches everything it
      started. */
  detached?: bool,
  /** See `execOptions.shell`. */
  shell?: bool,
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

/** The child's pid; none when it could not be started. */
@get external pid: childProcess => option<int> = "pid"

/** The child's end of each pipe: null for a descriptor that is not `"pipe"`
    (all three are pipes by default). */
@get external stdin: childProcess => Nullable.t<NodeStreams.writableStream> = "stdin"
@get external stdout: childProcess => Nullable.t<NodeStreams.readableStream> = "stdout"
@get external stderr: childProcess => Nullable.t<NodeStreams.readableStream> = "stderr"

/** The child has exited: its exit code, or null with the signal that ended it.
    Its pipes may still hold output; `onClose` waits for them too. */
@send
external onExit: (
  childProcess,
  @as("exit") _,
  (Nullable.t<int>, Nullable.t<string>) => unit,
) => childProcess = "on"

/** The child has exited and its pipes are drained: the last event, after the
    last `data`. Same arguments as `onExit`. */
@send
external onClose: (
  childProcess,
  @as("close") _,
  (Nullable.t<int>, Nullable.t<string>) => unit,
) => childProcess = "on"

/** The child could not be started (see `codeOf`: `ENOENT` when the program is
    not found), could not be killed, or a message could not be sent. */
@send
external onError: (childProcess, @as("error") _, JsExn.t => unit) => childProcess = "on"

// ── Asynchronous exec ──────────────────────────────────────────────────────

/** An error's `code`: the exit status of a child that ran and failed, or a
    system code such as `"ENOENT"` (the program was not found) or
    `"ERR_CHILD_PROCESS_STDIO_MAXBUFFER"` (its output passed `maxBuffer`). */
@unboxed
type errorCode = ExitStatus(int) | SystemCode(string)

/** The `code` of an error from this module: null when the child was ended by a
    signal (a `timeout` included; see `signalOf`), absent on an error that has
    none. */
@get external codeOf: JsExn.t => Nullable.t<errorCode> = "code"

/** The signal that ended the child, on an `execFile` / `exec` error: `"SIGTERM"`
    after a `timeout`, null otherwise. */
@get external signalOf: JsExn.t => Nullable.t<string> = "signal"

type execAsyncOptions = {
  cwd?: string,
  env?: dict<string>,
  /** Defaults to `"utf8"`, so `stdout` and `stderr` arrive as strings. */
  encoding?: string,
  /** Bytes of stdout or stderr beyond which the child is killed and the
      callback gets an error. Defaults to 1 MiB. */
  maxBuffer?: int,
  /** Milliseconds after which the child is killed and the callback gets an
      error. */
  timeout?: int,
  /** See `execOptions.shell`. */
  shell?: bool,
}

/** Runs a program without blocking and calls back once it has exited, with
    everything it wrote: the error is null on a zero exit. The arguments stay
    an array, as with `execFileSync`. Returns the running child, whose `stdin`
    takes the program's input (close it, or the program may wait for more). */
@module("node:child_process")
external execFile: (
  string,
  array<string>,
  execAsyncOptions,
  (Nullable.t<JsExn.t>, string, string) => unit,
) => childProcess = "execFile"

/** `execFile` for a command line run through a shell, which splits it into
    arguments: only for a line the caller wrote, never one built from input. */
@module("node:child_process")
external exec: (
  string,
  execAsyncOptions,
  (Nullable.t<JsExn.t>, string, string) => unit,
) => childProcess = "exec"

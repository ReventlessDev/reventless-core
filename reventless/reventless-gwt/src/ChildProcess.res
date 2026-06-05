// Minimal `node:child_process` binding for the watch-mode build manager. The
// only consumer is ProcessManager, which spawns one `pnpm run start`
// (`rescript build -w`) per package. Children are spawned **detached** so each
// gets its own process group; killing the negative pid then tears down the whole
// tree (pnpm + the rescript watcher it spawns) — no orphaned compilers.

type t
type stream

type spawnOptions = {
  cwd: string,
  detached: bool,
}

@module("node:child_process")
external _spawn: (string, array<string>, spawnOptions) => t = "spawn"

@get external _pid: t => Nullable.t<int> = "pid"
@get external _stdout: t => stream = "stdout"
@get external _stderr: t => stream = "stderr"
@send external _streamSetEncoding: (stream, string) => unit = "setEncoding"
@send external _streamOn: (stream, string, string => unit) => unit = "on"
@send external _procOnClose: (t, string, Nullable.t<int> => unit) => unit = "on"
@send external _kill: (t, string) => bool = "kill"
@val external _processKill: (int, string) => unit = "process.kill"

let spawn = (cmd: string, args: array<string>, ~cwd: string): t =>
  _spawn(cmd, args, {cwd, detached: true})

let pid = (proc: t): option<int> => proc->_pid->Nullable.toOption

// Subscribe to a stream line-by-line (stdout or stderr), buffering partial
// chunks. Used to classify ReScript compiler markers in Phase 5.
let onLines = (s: stream, cb: string => unit): unit => {
  _streamSetEncoding(s, "utf8")
  let buf = ref("")
  _streamOn(s, "data", chunk => {
    buf := buf.contents ++ chunk
    let rec drain = () =>
      switch String.indexOf(buf.contents, "\n") {
      | -1 => ()
      | idx => {
          let line = String.slice(buf.contents, ~start=0, ~end=idx)
          buf := String.slice(buf.contents, ~start=idx + 1, ~end=String.length(buf.contents))
          cb(line)
          drain()
        }
      }
    drain()
  })
}

let onStdoutLine = (proc: t, cb: string => unit): unit => onLines(proc->_stdout, cb)
let onStderrLine = (proc: t, cb: string => unit): unit => onLines(proc->_stderr, cb)
let onClose = (proc: t, cb: option<int> => unit): unit =>
  _procOnClose(proc, "close", code => cb(code->Nullable.toOption))

// Kill the child's whole process group (negative pid) so the rescript watcher
// pnpm spawned dies too. Falls back to a direct kill if the pid is gone.
let killTree = (proc: t, signal: string): unit =>
  switch proc->pid {
  | Some(p) =>
    try {
      _processKill(-p, signal)
    } catch {
    | _ => ignore(proc->_kill(signal))
    }
  | None => ignore(proc->_kill(signal))
  }

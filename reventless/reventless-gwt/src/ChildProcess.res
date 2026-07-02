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
  env: Dict.t<string>,
}

@module("node:child_process")
external _spawn: (string, array<string>, spawnOptions) => t = "spawn"

@val external _processEnv: Dict.t<string> = "process.env"

// Merge the current process env with optional overrides into a fresh dict — node's
// `spawn` replaces the whole env, so callers that pass `~env` still inherit PATH etc.
let mergeEnv = (overrides: option<Dict.t<string>>): Dict.t<string> => {
  let m = Dict.make()
  _processEnv->Dict.toArray->Array.forEach(((k, v)) => m->Dict.set(k, v))
  switch overrides {
  | Some(o) => o->Dict.toArray->Array.forEach(((k, v)) => m->Dict.set(k, v))
  | None => ()
  }
  m
}

@get external _pid: t => Nullable.t<int> = "pid"
@get external _stdout: t => stream = "stdout"
@get external _stderr: t => stream = "stderr"
@send external _streamSetEncoding: (stream, string) => unit = "setEncoding"
@send external _streamOn: (stream, string, string => unit) => unit = "on"
@send external _streamOnEnd: (stream, string, unit => unit) => unit = "on"
@send external _procOnClose: (t, string, Nullable.t<int> => unit) => unit = "on"
@send external _procOnError: (t, string, JsExn.t => unit) => unit = "on"
@send external _kill: (t, string) => bool = "kill"
@val external _processKill: (int, string) => unit = "process.kill"

let spawn = (cmd: string, args: array<string>, ~cwd: string, ~env: option<Dict.t<string>>=?): t =>
  _spawn(cmd, args, {cwd, detached: true, env: mergeEnv(env)})

let pid = (proc: t): option<int> => proc->_pid->Nullable.toOption

// Subscribe to a stream line-by-line (stdout or stderr), buffering partial
// chunks. Used to classify ReScript compiler markers in Phase 5. On stream
// `end` the final unterminated line is flushed — crash/panic messages
// typically lack a trailing newline, so without this the last (often most
// diagnostic) line was silently dropped.
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
  _streamOnEnd(s, "end", () =>
    if buf.contents != "" {
      let last = buf.contents
      buf := ""
      cb(last)
    }
  )
}

let onStdoutLine = (proc: t, cb: string => unit): unit => onLines(proc->_stdout, cb)
let onStderrLine = (proc: t, cb: string => unit): unit => onLines(proc->_stderr, cb)
let onClose = (proc: t, cb: option<int> => unit): unit =>
  _procOnClose(proc, "close", code => cb(code->Nullable.toOption))

// A spawn failure (ENOENT for a missing binary, EACCES, …) emits `"error"` on
// the child, not `"close"`. Without a listener Node re-throws it as an uncaught
// exception and crashes the whole CLI. Route the message to the caller instead.
let onError = (proc: t, cb: string => unit): unit =>
  _procOnError(proc, "error", e => cb(e->JsExn.message->Option.getOr("spawn failed")))

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

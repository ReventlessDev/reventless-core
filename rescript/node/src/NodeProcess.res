/** Bindings for the [`process`](https://nodejs.org/api/process.html) global.

    `process` is a global rather than a module specifier, so these are `@val`
    bindings under `@scope("process")` — `@val external env: dict<string> =
    "process.env"` and `@val @scope("process") external env: dict<string> =
    "env"` compile to the same access, and the tree had both spellings. This is
    the one. */

@val @scope("process")
external argv: array<string> = "argv"

@val @scope("process")
external env: dict<string> = "env"

@val @scope("process")
external cwd: unit => string = "cwd"

@val @scope("process")
external chdir: string => unit = "chdir"

@val @scope("process")
external exit: int => unit = "exit"

@val @scope("process")
external pid: int = "pid"

/** Signalling another process — or, with signal `0`, asking whether it is still
    there without disturbing it. Throws when the pid is gone (`ESRCH`) or not
    ours to signal (`EPERM`), so a liveness check is a `try`. */
@val @scope("process")
external kill: (int, int) => unit = "kill"

/** `process.on` for the two shutdown paths a CLI has to clean up on.

    Split into an `exit` binding and a signal binding because the handlers are
    not interchangeable: `exit` fires with the exit code and may only do
    synchronous work, while a signal handler receives the signal name and fires
    *before* the process is committed to leaving — code that registers one and
    expects the other's timing gets a cleanup that never runs. Signals are a
    polyvariant so a typo is a compile error rather than a handler that is never
    called. */
@val @scope("process")
external onExit: (@as("exit") _, int => unit) => unit = "on"

@val @scope("process")
external onSignal: ([#SIGINT | #SIGTERM | #SIGHUP], unit => unit) => unit = "on"

/** The standard streams. `write`, `isTTY`, `pause` and `unref` are what the
    interactive prompts in this repository reach for; the type is abstract so it
    can also be handed to `readline.createInterface`. */
type stream

@val @scope("process")
external stdin: stream = "stdin"

@val @scope("process")
external stdout: stream = "stdout"

@send external write: (stream, string) => unit = "write"
@send external pause: stream => unit = "pause"
@send external unref: stream => unit = "unref"

/** `option<bool>`, not `bool`: Node sets `isTTY` to `true` on an interactive
    stream and leaves it **undefined** otherwise — it is never `false`. A
    `bool`-typed binding reads that undefined as a valid `false`, which happens
    to work and is still lying about the value. */
@get external isTTY: stream => option<bool> = "isTTY"

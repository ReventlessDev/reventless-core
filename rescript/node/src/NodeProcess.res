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

/** The standard streams. `write`, `isTTY`, `pause` and `unref` are what the
    interactive prompts in this repository reach for; the type is abstract so it
    can also be handed to `readline.createInterface`. */
type stream

@val @scope("process")
external stdin: stream = "stdin"

@val @scope("process")
external stdout: stream = "stdout"

@send external write: (stream, string) => unit = "write"
@get external isTTY: stream => bool = "isTTY"
@send external pause: stream => unit = "pause"
@send external unref: stream => unit = "unref"

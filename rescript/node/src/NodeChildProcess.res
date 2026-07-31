/** Bindings for
    [`node:child_process`](https://nodejs.org/api/child_process.html). */

type execOptions = {encoding?: string, stdio?: array<string>, maxBuffer?: int}

@module("node:child_process")
external execSync: (string, execOptions) => string = "execSync"

/** Takes the arguments as an array rather than interpolating them into a shell
    string, so an argument containing shell metacharacters stays one argument. */
@module("node:child_process")
external execFileSync: (string, array<string>, execOptions) => string = "execFileSync"

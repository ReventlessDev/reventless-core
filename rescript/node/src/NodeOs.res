/** Bindings for [`node:os`](https://nodejs.org/api/os.html). */
@module("node:os")
external tmpdir: unit => string = "tmpdir"

/** The current user's home directory. */
@module("node:os")
external homedir: unit => string = "homedir"

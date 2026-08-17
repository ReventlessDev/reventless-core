/** Bindings for [`node:fs`](https://nodejs.org/api/fs.html).

    Every specifier here is `node:`-prefixed. Bare `"fs"` is what bundlers alias
    to a browser polyfill shim, and this repository bundles Lambda code archives;
    `node:fs` is unambiguous to Node and to every bundler.

    `readFileSync` bakes the encoding in rather than taking it, so it cannot be
    passed wrongly — the `(string, string)` form is the one that permits
    `readFileSync(path, "utf-8")`, a different string, silently. Use
    {!readFileSyncBuffer} when the bytes are wanted rather than text. */

// ── Existence and metadata ───────────────────────────────────────────────────

@module("node:fs")
external existsSync: string => bool = "existsSync"

@module("node:fs")
external realpathSync: string => string = "realpathSync"

/** Set a file's access and modification times, in seconds since the epoch.

    The reason this exists here rather than as a shell-out to `touch`: a build
    whose compiler caches on source mtime cannot be made to re-run a side effect
    of compilation — emitting a sidecar, say — by any argument passed to it. The
    input has to look newer. */
@module("node:fs")
external utimesSync: (string, float, float) => unit = "utimesSync"

// ── Reading ──────────────────────────────────────────────────────────────────

@module("node:fs")
external readFileSync: (string, @as("utf8") _) => string = "readFileSync"

/** The same call without an encoding, which is what makes Node return the raw
    bytes rather than a decoded string. */
@module("node:fs")
external readFileSyncBuffer: string => Uint8Array.t = "readFileSync"

// ── Writing ──────────────────────────────────────────────────────────────────

@module("node:fs")
external writeFileSync: (string, string, @as("utf8") _) => unit = "writeFileSync"

/** The byte-oriented companion to {!writeFileSync}, mirroring
    {!readFileSyncBuffer}: no encoding to bake in, because the payload is
    already bytes. */
@module("node:fs")
external writeFileSyncBuffer: (string, Uint8Array.t) => unit = "writeFileSync"

// ── Watching ─────────────────────────────────────────────────────────────────

/** A handle from {!watch}. Held so it can be closed, and so it can be `unref`ed
    — an active watcher keeps the event loop alive, which turns a stray watch in
    a test into a run that never exits. */
type watcher

/** Stop watching. */
@send external watcherClose: watcher => unit = "close"

/** Take the watcher off the event loop's reference count, so it never by itself
    keeps the process running. Returns the same watcher, as Node does. */
@send external watcherUnref: watcher => watcher = "unref"

/** [`fs.watch`](https://nodejs.org/api/fs.html#fswatchfilename-options-listener).

    The listener takes the event type (`"rename"` or `"change"`) and the
    basename, which Node may report as null on some platforms — hence
    `Nullable.t`.

    **Watch the directory, not the file**, when the file is one an editor
    writes: a save that replaces rather than rewrites (write-temp-then-rename,
    which is how most editors save atomically) gives the path a new inode, and a
    watcher registered on the old one goes silent with no error. Watching the
    containing directory and filtering on the basename survives that. */
@module("node:fs")
external watch: (string, (string, Nullable.t<string>) => unit) => watcher = "watch"

// ── Directories ──────────────────────────────────────────────────────────────

type dirent
@send external isDirectory: dirent => bool = "isDirectory"
@send external isFile: dirent => bool = "isFile"
@get external direntName: dirent => string = "name"

type readdirOptions = {withFileTypes: bool}

@module("node:fs")
external readdirSync: (string, readdirOptions) => array<dirent> = "readdirSync"

type mkdirOptions = {recursive?: bool}

@module("node:fs")
external mkdirSync: (string, mkdirOptions) => unit = "mkdirSync"

@module("node:fs")
external mkdtempSync: string => string = "mkdtempSync"

// ── Removing and copying ─────────────────────────────────────────────────────

@module("node:fs")
external unlinkSync: string => unit = "unlinkSync"

type rmOptions = {recursive?: bool, force?: bool}

@module("node:fs")
external rmSync: (string, rmOptions) => unit = "rmSync"

type cpOptions = {recursive?: bool}

@module("node:fs")
external cpSync: (string, string, cpOptions) => unit = "cpSync"

/** Bindings for [`node:fs/promises`](https://nodejs.org/api/fs.html#promises-api).

    A separate module specifier, so a separate module here — the promise API is
    not a wrapper this package adds over the sync one. */
module Promises = {
  @module("node:fs/promises")
  external writeFile: (string, string) => promise<unit> = "writeFile"

  @module("node:fs/promises")
  external mkdir: (string, mkdirOptions) => promise<Nullable.t<string>> = "mkdir"

  @module("node:fs/promises")
  external rm: (string, rmOptions) => promise<unit> = "rm"
}

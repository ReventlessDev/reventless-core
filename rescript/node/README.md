[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-node.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-node)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-node

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for the [Node.js](https://nodejs.org) standard library.

This package has **no dependencies** and performs **no work at module scope** — it is safe to import
from a Lambda entry point without pulling anything into the runtime module graph.

It replaces `@reventlessdev/rescript-node-streams` and `@reventlessdev/rescript-node-zlib`, which
were one binding surface published as two artifacts. The package is `namespace: false`, so the module
names are unchanged: code that used `NodeStreams` or `NodeZlib` needs only a dependency swap.

## Install

```bash
pnpm add @reventlessdev/rescript-node
```

Add it to your `rescript.json` dependencies:

```json
{
  "dependencies": ["@reventlessdev/rescript-node"]
}
```

## Modules

| Module | Binds |
|---|---|
| `NodeBuffer` | the global `Buffer` |
| `NodeChildProcess` | `node:child_process` |
| `NodeCrypto` | `node:crypto` |
| `NodeFs` | `node:fs`, plus `node:fs/promises` as `NodeFs.Promises` |
| `NodeImportMeta` | `import.meta` |
| `NodeModule` | `node:module` |
| `NodeOs` | `node:os` |
| `NodePath` | `node:path` |
| `NodeProcess` | the `process` global |
| `NodeStreams` | `node:stream`, plus the stream-shaped parts of `node:fs` and `node:readline` |
| `NodeUrl` | `node:url` |
| `NodeZlib` | `node:zlib` |

Every module specifier is `node:`-prefixed. Bare `"fs"` is what bundlers alias to a browser polyfill
shim, and this repository bundles Lambda code archives; `node:fs` is unambiguous to Node and to every
bundler.

Coverage is demand-driven: these bind what the Reventless packages actually call, not the whole of
each Node module. Where a Node API has an encoding or option argument that is only ever passed one
way here, the binding bakes it in rather than accepting it — `NodeFs.readFileSync` is UTF-8 by
construction, so no call site can pass `"utf-8"` and get a different, silently wrong, encoding.

---

## `NodeBuffer`

`t` aliases `Uint8Array.t` rather than being abstract: a Node `Buffer` *is* a `Uint8Array` subclass,
so stream chunks, `NodeFs.readFileSyncBuffer` results and `NodeFs.writeFileSyncBuffer` arguments are
all the same values and flow between those calls without a cast.

```rescript
type t = Uint8Array.t

let concat: array<t> => t              // assemble a body from its `data` chunks
let fromStringUtf8: string => t
let toStringUtf8: t => string
```

---

## `NodeChildProcess`

```rescript
type execOptions = {cwd?: string, encoding?: string, env?: dict<string>, stdio?: array<string>, maxBuffer?: int}

let execSync: (string, execOptions) => string
let execFileSync: (string, array<string>, execOptions) => string

type childProcess
type spawnOptions = {cwd?: string, env?: dict<string>, stdio?: array<string>}

let spawn: (string, array<string>, spawnOptions) => childProcess
let exitCode: childProcess => Nullable.t<int>
let kill: (childProcess, string) => bool
```

Prefer `execFileSync` over `execSync`: it takes the arguments as an array rather than interpolating
them into a shell string, so an argument containing shell metacharacters stays one argument.

`spawn` returns while the child is still alive, which is the reason to reach for it over
`execFileSync`. `exitCode` is `null` until the child exits — the one honest way to ask "is it still
alive?" without holding an event listener, so a caller polling for readiness can tell a slow start
from a process that already died. `kill` returns whether the signal was delivered; `false` means the
process was already gone, which is not an error.

`spawnOptions.env` **replaces** the child's environment rather than extending it. Pass a copy of
`NodeProcess.env` with the additions applied when the child still needs `PATH` and friends.

---

## `NodeCrypto`

```rescript
type buffer                            // abstract: only ever re-keyed or stringified
let bufferToString: (buffer, string) => string

type hash
let createHash: string => hash
let hashUpdate: (hash, string) => hash
let hashUpdateBuffer: (hash, Uint8Array.t) => hash
let hashDigest: (hash, string) => string
let sha256Hex: string => string        // SHA-256 of a UTF-8 string, hex-encoded

type hmac
let createHmac: (string, string) => hmac
let createHmacFromBuffer: (string, buffer) => hmac
let hmacUpdate: (hmac, string) => hmac
let hmacDigest: (hmac, string) => string
let hmacDigestBuffer: hmac => buffer

let randomBytes: int => buffer
let randomUUID: unit => string
```

`sha256Hex` is the content hash content-addressed stores key their objects on (`sha256/<hash>`): the
same bytes always yield the same digest, so an upload is idempotent and deduplicating.
`createHmacFromBuffer` is the chained form — each round of an AWS SigV4 signing key takes the
previous round's raw digest as its key.

---

## `NodeFs`

```rescript
let existsSync: string => bool
let realpathSync: string => string

let readFileSync: string => string           // UTF-8 baked in
let readFileSyncBuffer: string => Uint8Array.t
let writeFileSync: (string, string) => unit  // UTF-8 baked in
let writeFileSyncBuffer: (string, Uint8Array.t) => unit

type dirent
let isDirectory: dirent => bool
let isFile: dirent => bool
let direntName: dirent => string

type readdirOptions = {withFileTypes: bool}
type mkdirOptions = {recursive?: bool}
type rmOptions = {recursive?: bool, force?: bool}
type cpOptions = {recursive?: bool}

let readdirSync: (string, readdirOptions) => array<dirent>
let mkdirSync: (string, mkdirOptions) => unit
let mkdtempSync: string => string
let unlinkSync: string => unit
let rmSync: (string, rmOptions) => unit
let cpSync: (string, string, cpOptions) => unit

module Promises = {
  let writeFile: (string, string) => promise<unit>
  let mkdir: (string, mkdirOptions) => promise<Nullable.t<string>>
  let rm: (string, rmOptions) => promise<unit>
}
```

The `*Buffer` variants are the same Node calls without an encoding, which is what makes Node return
raw bytes rather than a decoded string. `Promises` is a separate module because `node:fs/promises` is
a separate specifier — not a wrapper this package adds over the sync calls.

---

## `NodeImportMeta`

```rescript
let url: string       // import.meta.url
let dirname: string   // import.meta.dirname
let filename: string  // import.meta.filename
```

These resolve to the location of the module that *reads* them, which is what makes binding a
per-module value in a shared package sound at all: `@val` externals are inlined at the use site
rather than re-exported by this one. The corollary is that there are no helpers here — a function
defined in this module would report *this* file's location, so compute from the values at the call
site instead.

```rescript
// The file sitting next to the module that asks for it.
let hintsFile = NodePath.resolve([NodeImportMeta.dirname, "../ui-hints.json"])
```

`dirname` and `filename` are Node's own additions to `import.meta` and are defined only for `file:`
URLs; a bundler that rewrites modules to CommonJS drops them. `url` is the portable form and the one
to reach for when either could apply.

---

## `NodeModule`

```rescript
type require
let createRequire: string => require
let requireResolve: (require, string) => string
let builtinModules: array<string>
```

`createRequire` is how an ESM module gets at CommonJS resolution, which is what `require.resolve` is
wanted for: locating a dependency's on-disk path without importing it. `builtinModules` lists Node's
built-ins, both bare and `node:`-only entries such as `node:test`, plus subpath forms like
`fs/promises`.

---

## `NodeOs`

```rescript
let tmpdir: unit => string
```

---

## `NodePath`

```rescript
let join: array<string> => string      // variadic
let resolve: array<string> => string   // variadic
let dirname: string => string
let basename: string => string
let relative: (string, string) => string
let sep: string
```

`join` and `resolve` are variadic, a strict superset of the two-argument forms they replace, so no
call site loses expressiveness. A two-argument `join` and a variadic one are not duplicates — they
are different functions with the same name, and which one a call site got used to depend on which
inline binding block it happened to sit near.

---

## `NodeProcess`

```rescript
let argv: array<string>
let env: dict<string>
let cwd: unit => string
let chdir: string => unit
let exit: int => unit

type stream
let stdin: stream
let stdout: stream
let write: (stream, string) => unit
let pause: stream => unit
let unref: stream => unit
let isTTY: stream => option<bool>
```

`process` is a global rather than a module specifier, so these are `@val` bindings under
`@scope("process")`.

`isTTY` is `option<bool>`, not `bool`: Node sets it to `true` on an interactive stream and leaves it
**undefined** otherwise — it is never `false`. A `bool`-typed binding reads that undefined as a valid
`false`, which happens to work and is still lying about the value.

---

## `NodeUrl`

```rescript
let fileURLToPath: string => string
let pathToFileURL: string => {"href": string}
```

Only the two path/URL converters. The `URL` class itself is a WHATWG global rather than a `node:`
import, so it belongs to `rescript-web`, not here.

---

## `NodeStreams`

### Stream types

- **`Readable.t`** — readable streams (file read streams, HTTP requests)
- **`Writable.t`** — writable streams (file write streams, HTTP responses)
- **`Transform.t`** — transform streams (streams that modify data as it passes through)
- **`Duplex.t`** — duplex streams (both readable and writable)

### Readable streams

```rescript
module Readable = {
  type t = readableStream

  // Piping
  let pipe: (t, writableStream) => writableStream

  // Encoding
  let setEncoding: (t, string) => t

  // Event handlers
  let onDataFromBuffer: (t, @as("data") _, buffer => unit) => t
  let onDataFromString: (t, @as("data") _, string => unit) => t
  let onDataFromArbitary: (t, @as("data") _, 'd => unit) => t
  let onEnd: (t, @as("end") _, unit => unit) => t
  let onReadable: (t, @as("readable") _, unit => unit) => t
  let onError: (t, @as("error") _, JsExn.t => unit) => t
  let onClose: (t, @as("close") _, unit => unit) => t
}
```

**Key events:**
- `data` — emitted when data is available to read
- `end` — emitted when no more data is available
- `readable` — emitted when data is ready to be read
- `error` — emitted on errors
- `close` — emitted when the stream is closed

### Writable streams

```rescript
module Writable = {
  type t = writableStream

  // Operations
  let close: t => unit
  let pipe: (t, t) => t

  // Event handlers
  let onData: (t, @as("data") _, 'd => unit) => t
  let onDrain: (t, @as("drain") _, unit => unit) => t
  let onFinish: (t, @as("finish") _, unit => unit) => t
  let onPipe: (t, @as("pipe") _, readableStream => unit) => t
  let onUnpipe: (t, @as("unpipe") _, readableStream => unit) => t
  let onError: (t, @as("error") _, JsExn.t => unit) => t
  let onClose: (t, @as("close") _, unit => unit) => t
}
```

**Key events:**
- `drain` — emitted when it is safe to resume writing after `write()` returns false
- `finish` — emitted after `end()` is called and all data is flushed
- `pipe` — emitted when a readable stream pipes into this writable
- `unpipe` — emitted when `unpipe()` is called on a readable stream

### Transform streams

```rescript
module Transform = {
  type t
  let pipe: (t, readableStream) => writableStream
}
```

### File-system streams

```rescript
let createReadStream: string => Readable.t
let createWriteStream: string => Writable.t
let unlink: string => promise<unit>
```

### Pipeline

The `pipeline` functions pipe streams together with automatic error handling and cleanup:

```rescript
// Direct pipe (no transforms)
let pipeline0: (Readable.t, Writable.t) => promise<unit>

// With 1 transform
let pipeline: (Readable.t, Transform.t, Writable.t) => promise<unit>

// With 2 transforms
let pipeline2: (Readable.t, Transform.t, Transform.t, Writable.t) => promise<unit>

// With 3 transforms
let pipeline3: (Readable.t, Transform.t, Transform.t, Transform.t, Writable.t) => promise<unit>
```

### Readline

```rescript
module Readline = {
  type t
  type options = {input: Readable.t}

  let createInterface: options => t
  let onLine: (t, @as("line") _, string => unit) => t
}
```

### Examples

#### File copy with piping

```rescript
open NodeStreams

let copyFile = (source, dest) => {
  let readStream = createReadStream(source)
  let writeStream = createWriteStream(dest)

  readStream
  ->Readable.pipe(writeStream)
  ->Writable.onFinish(() => Console.log("Copy completed"))
  ->Writable.onError(err => Console.log2("Error:", err))
  ->ignore
}
```

#### Reading a file line by line

```rescript
open NodeStreams

let processFileLines = filename => {
  let readStream = createReadStream(filename)
  let rl = Readline.createInterface({input: readStream})

  rl->Readline.onLine(line => Console.log(line))->ignore

  readStream
  ->Readable.onEnd(() => Console.log("Finished reading file"))
  ->Readable.onError(err => Console.log2("Error:", err))
  ->ignore
}
```

#### Reading data with an encoding

```rescript
open NodeStreams

let readTextFile = filename =>
  createReadStream(filename)
  ->Readable.setEncoding("utf8")
  ->Readable.onDataFromString(chunk => Console.log2("Received chunk:", chunk))
  ->Readable.onEnd(() => Console.log("File read complete"))
  ->Readable.onError(err => Console.log2("Error reading file:", err))
  ->ignore
```

#### Safe composition with `pipeline`

```rescript
open NodeStreams

let copyFileWithPipeline = async (source, dest) => {
  let readStream = createReadStream(source)
  let writeStream = createWriteStream(dest)

  try {
    await pipeline0(readStream, writeStream)
    Console.log("Copy completed successfully")
  } catch {
  | JsExn.Error(err) => Console.log2("Pipeline error:", err)
  }
}
```

### Event handling

All stream types support event-based programming. Events are registered with `on*` functions that
return the stream, so they chain:

```rescript
stream
->onEvent1(handler1)
->onEvent2(handler2)
->ignore
```

Notes:

- Always handle `error` events, or an error becomes an uncaught exception.
- Prefer the `pipeline` functions over manual `pipe` chains — they clean up on failure.
- Readable streams switch to flowing mode as soon as a `data` handler is attached.

---

## `NodeZlib`

Bindings for [`node:zlib`](https://nodejs.org/api/zlib.html). Decompression is what this covers
today; the compression-only options are deliberately absent from `opts` rather than bound and
ignored.

```rescript
type opts = {
  flush?: flush,
  finishFlush?: flush,
  chunkSize?: int, // default 16 * 1024
  windowBits?: int,
  info?: bool,
}

let createUnzip: (~options: opts=?) => NodeStreams.Transform.t
```

`Constants.Flush`, `Constants.ReturnCodes`, `Constants.CompressionLevels` and
`Constants.CompressionStrategy` bind `zlib.constants`.

### Example

```rescript
open NodeZlib

let gunzip = async (source, dest) =>
  await NodeStreams.pipeline(
    NodeStreams.createReadStream(source),
    createUnzip(),
    NodeStreams.createWriteStream(dest),
  )
```

A runnable version is in [./src/example/ZlibExample.res](./src/example/ZlibExample.res).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)

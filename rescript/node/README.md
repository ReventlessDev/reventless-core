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
| `NodeStreams` | `node:stream`, plus the stream-shaped parts of `node:fs` and `node:readline` |
| `NodeZlib` | `node:zlib` |

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

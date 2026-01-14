# `rescript-node-streams`

ReScript bindings for [Node.js streams](https://nodejs.org/docs/latest-v12.x/api/stream.html).

## Installation

1. Add `rescript-node-streams` to your dependencies in `package.json`:
   ```bash
   npm install rescript-node-streams
   ```

2. Add `rescript-node-streams` to your dependencies in `rescript.json` (or `bsconfig.json`):
   ```json
   {
     "bs-dependencies": ["rescript-node-streams"]
   }
   ```

For general information see this monorepo's [readme](../../README.md).

## Stream Types

This module provides bindings for Node.js stream types:

- **`Readable.t`** - Readable streams (e.g., file read streams, HTTP requests)
- **`Writable.t`** - Writable streams (e.g., file write streams, HTTP responses)
- **`Transform.t`** - Transform streams (streams that modify data as it passes through)
- **`Duplex.t`** - Duplex streams (both readable and writable)

## API Documentation

### Readable Streams

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
  let onError: (t, @as("error") _, Js.Exn.t => unit) => t
  let onClose: (t, @as("close") _, unit => unit) => t
}
```

**Key Events:**
- `data` - Emitted when data is available to read
- `end` - Emitted when no more data is available
- `readable` - Emitted when data is ready to be read
- `error` - Emitted on errors
- `close` - Emitted when stream is closed

### Writable Streams

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
  let onError: (t, @as("error") _, Js.Exn.t => unit) => t
  let onClose: (t, @as("close") _, unit => unit) => t
}
```

**Key Events:**
- `drain` - Emitted when it's safe to resume writing after `write()` returns false
- `finish` - Emitted after `end()` is called and all data is flushed
- `pipe` - Emitted when a readable stream pipes into this writable
- `unpipe` - Emitted when `unpipe()` is called on a readable stream

### Transform Streams

```rescript
module Transform = {
  type t
  let pipe: (t, readableStream) => writableStream
}
```

### File System Streams

```rescript
// Create file streams
let createReadStream: string => Readable.t
let createWriteStream: string => Writable.t
let unlink: string => Js.Promise.t<unit>
```

### Pipeline

The `pipeline` functions provide a safe way to pipe streams together with automatic error handling and cleanup:

```rescript
// Direct pipe (no transforms)
let pipeline0: (Readable.t, Writable.t) => Js.Promise.t<unit>

// With 1 transform
let pipeline: (Readable.t, Transform.t, Writable.t) => Js.Promise.t<unit>

// With 2 transforms
let pipeline2: (Readable.t, Transform.t, Transform.t, Writable.t) => Js.Promise.t<unit>

// With 3 transforms
let pipeline3: (Readable.t, Transform.t, Transform.t, Transform.t, Writable.t) => Js.Promise.t<unit>
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

## Examples

### Basic File Copy with Piping

```rescript
open NodeStreams

// Simple file copy using pipe
let copyFile = (source, dest) => {
  let readStream = createReadStream(source)
  let writeStream = createWriteStream(dest)

  readStream
  ->Readable.pipe(writeStream)
  ->Writable.onFinish(() => Js.log("Copy completed"))
  ->Writable.onError(err => Js.log2("Error:", err))
  ->ignore
}

// Usage
copyFile("input.txt", "output.txt")
```

### Reading File Line by Line

```rescript
open NodeStreams

let processFileLines = (filename) => {
  let readStream = createReadStream(filename)

  let rl = Readline.createInterface({input: readStream})

  rl
  ->Readline.onLine(line => {
    Js.log(line)
  })
  ->ignore

  readStream
  ->Readable.onEnd(() => Js.log("Finished reading file"))
  ->Readable.onError(err => Js.log2("Error:", err))
  ->ignore
}
```

### Reading Data with Encoding

```rescript
open NodeStreams

let readTextFile = (filename) => {
  let readStream = createReadStream(filename)

  readStream
  ->Readable.setEncoding("utf8")
  ->Readable.onDataFromString(chunk => {
    Js.log2("Received chunk:", chunk)
  })
  ->Readable.onEnd(() => {
    Js.log("File read complete")
  })
  ->Readable.onError(err => {
    Js.log2("Error reading file:", err)
  })
  ->ignore
}
```

### Using Pipeline for Safe Stream Composition

```rescript
open NodeStreams

let copyFileWithPipeline = async (source, dest) => {
  let readStream = createReadStream(source)
  let writeStream = createWriteStream(dest)

  try {
    // pipeline automatically handles cleanup and errors
    await pipeline0(readStream, writeStream)
    Js.log("Copy completed successfully")
  } catch {
  | Js.Exn.Error(err) => Js.log2("Pipeline error:", err)
  }
}
```

### Error Handling Pattern

```rescript
open NodeStreams

let robustFileCopy = (source, dest) => {
  let readStream = createReadStream(source)
  let writeStream = createWriteStream(dest)

  // Handle errors on both streams
  readStream
  ->Readable.onError(err => {
    Js.log2("Read error:", err)
    writeStream->Writable.close
  })
  ->ignore

  writeStream
  ->Writable.onError(err => {
    Js.log2("Write error:", err)
  })
  ->Writable.onFinish(() => {
    Js.log("Copy completed successfully")
  })
  ->ignore

  // Pipe the streams
  readStream->Readable.pipe(writeStream)->ignore
}
```

## Event Handling

All stream types support event-based programming. Events are registered using `on*` functions that return the stream for chaining:

```rescript
stream
->onEvent1(handler1)
->onEvent2(handler2)
->onEvent3(handler3)
->ignore
```

Common events across stream types:
- `error` - Handle errors
- `close` - Handle stream closure
- Custom events via `onEvent(stream, eventName, handler)`

## Notes

- Always handle `error` events to prevent uncaught exceptions
- Use `pipeline` functions for automatic cleanup and error handling
- The `->ignore` at the end of event handler chains discards the returned stream value
- Readable streams switch to "flowing mode" when `data` event handlers are attached

## Contribution

### Changelog
Please remember to update the changelog for any modifications accordingly!

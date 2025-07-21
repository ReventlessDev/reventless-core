type readableStream
type writableStream
type buffer

module EventHandler = {
  @send
  external onError: ('a, @as("error") _, Js.Exn.t => unit) => 'a = "on"
  @send
  external onClose: ('a, @as("close") _, unit => unit) => 'a = "on"
  @send external onEvent: ('a, string, 'b => unit) => 'a = "on"
}

module Writable = {
  type t = writableStream
  @send external close: t => unit = "end"
  @send external pipe: (t, t) => t = "pipe"

  include EventHandler // onError & onClose & onEvent

  @send
  external onData: (t, @as("data") _, 'd => unit) => t = "on"

  /** If a call to stream.write(chunk) returns false, the 'drain' event will be emitted when it is appropriate to resume writing data to the stream.
    see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_drain */
  @send
  external onDrain: (t, @as("drain") _, unit => unit) => t = "on"

  /** The 'finish' event is emitted after the stream.end() method has been called, and all data has been flushed to the underlying system.
    see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_finish */
  @send
  external onFinish: (t, @as("finish") _, unit => unit) => t = "on"

  /** The 'pipe' event is emitted when the stream.pipe() method is called on a readable stream, adding this writable to its set of destinations.
    see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_pipe */
  @send
  external onPipe: (t, @as("pipe") _, readableStream => unit) => t = "on"

  /** The 'unpipe' event is emitted when the stream.unpipe() method is called on a Readable stream, removing this Writable from its set of destinations.
		This is also emitted in case this Writable stream emits an error when a Readable stream pipes into it.
		see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_unpipe */
  @send
  external onUnpipe: (t, @as("unpipe") _, readableStream => unit) => t = "on"
}

module Readable = {
  type t = readableStream
  @send external pipe: (t, writableStream) => writableStream = "pipe"

  @send
  external setEncoding: (t, string) => t = "setEncoding"

  include EventHandler // onError & onClose & onEvent

  /** The 'data' event is emitted whenever the stream is relinquishing ownership of a chunk of data to a consumer. This may occur whenever the stream is switched in flowing mode by calling readable.pipe(), readable.resume(), or by attaching a listener callback to the 'data' event. The 'data' event will also be emitted whenever the readable.read() method is called and a chunk of data is available to be returned.
		Attaching a 'data' event listener to a stream that has not been explicitly paused will switch the stream into flowing mode. Data will then be passed as soon as it is available.
		The listener callback will be passed the chunk of data as a string if a default encoding has been specified for the stream using the readable.setEncoding() method; otherwise the data will be passed as a Buffer.
	 see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_data */
  @send
  external onDataFromBuffer: (t, @as("data") _, buffer => unit) => t = "on"

  /** The 'data' event is emitted whenever the stream is relinquishing ownership of a chunk of data to a consumer. This may occur whenever the stream is switched in flowing mode by calling readable.pipe(), readable.resume(), or by attaching a listener callback to the 'data' event. The 'data' event will also be emitted whenever the readable.read() method is called and a chunk of data is available to be returned.
		Attaching a 'data' event listener to a stream that has not been explicitly paused will switch the stream into flowing mode. Data will then be passed as soon as it is available.
		The listener callback will be passed the chunk of data as a string if a default encoding has been specified for the stream using the readable.setEncoding() method; otherwise the data will be passed as a Buffer.
	 see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_data */
  @send
  external onDataFromString: (t, @as("data") _, string => unit) => t = "on"

  /** The 'data' event is emitted whenever the stream is relinquishing ownership of a chunk of data to a consumer. This may occur whenever the stream is switched in flowing mode by calling readable.pipe(), readable.resume(), or by attaching a listener callback to the 'data' event. The 'data' event will also be emitted whenever the readable.read() method is called and a chunk of data is available to be returned.
		Attaching a 'data' event listener to a stream that has not been explicitly paused will switch the stream into flowing mode. Data will then be passed as soon as it is available.
		The listener callback will be passed the chunk of data as a string if a default encoding has been specified for the stream using the readable.setEncoding() method; otherwise the data will be passed as a Buffer.
		Note: The 'end' event will not be emitted unless the data is completely consumed. This can be accomplished by switching the stream into flowing mode, or by calling stream.read() repeatedly until all data has been consumed.
	 see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_data */
  @send
  external onDataFromArbitary: (t, @as("data") _, 'd => unit) => t = "on"

  /** The 'end' event is emitted when there is no more data to be consumed from the stream.
		see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_end */
  @send
  external onEnd: (t, @as("end") _, unit => unit) => t = "on"

  /** The 'readable' event is emitted when there is data available to be read from the stream. In some cases, attaching a listener for the 'readable' event will cause some amount of data to be read into an internal buffer.
		see: https://nodejs.org/docs/latest-v8.x/api/stream.html#stream_event_readable */
  @send
  external onReadable: (t, @as("readable") _, unit => unit) => t = "on"
}

module Duplex = {
  type t
}

module Transform = {
  type t
  @send external pipe: (t, readableStream) => writableStream = "pipe"
}

@val @module("fs")
external createWriteStream: string => Writable.t = "createWriteStream"
@val @module("fs")
external createReadStream: string => Readable.t = "createReadStream"
@val @module("fs")
external unlink: string => Js.Promise.t<unit> = "unlink"

module Readline = {
  type t
  type options = {input: Readable.t}

  @val @module("readline")
  external createInterface: options => t = "createInterface"

  @send
  external onLine: (t, @as("line") _, string => unit) => t = "on"
}

// NOTE: This node function is variadic (=takes n transform streams)
// NOTE: documentation says, this returns <Stream>, we just bind to unit
@val @module("stream") @scope("promises")
external pipeline0: (Readable.t, Writable.t) => Js.Promise.t<unit> = "pipeline"
@val @module("stream") @scope("promises")
external pipeline: (Readable.t, Transform.t, Writable.t) => Js.Promise.t<unit> = "pipeline"
@val @module("stream") @scope("promises")
external pipeline2: (Readable.t, Transform.t, Transform.t, Writable.t) => Js.Promise.t<unit> =
  "pipeline"
@val @module("stream") @scope("promises")
external pipeline3: (
  Readable.t,
  Transform.t,
  Transform.t,
  Transform.t,
  Writable.t,
) => Js.Promise.t<unit> = "pipeline"

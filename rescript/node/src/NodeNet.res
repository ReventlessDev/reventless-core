/** Bindings for [`node:net`](https://nodejs.org/api/net.html) — TCP servers and
    the sockets they accept. */

type socket
type server

/** A connected client. `write` returns the backpressure flag, which a caller
    that only ever sends short lines can ignore. */
@send external write: (socket, string) => bool = "write"
@send external destroySocket: socket => unit = "destroy"

/** `setEncoding` makes the `data` frames arrive as strings rather than Buffers,
    which is what a line-oriented consumer wants. */
@send external setEncoding: (socket, string) => unit = "setEncoding"

@send external onSocketData: (socket, @as("data") _, string => unit) => unit = "on"
@send external onSocketClose: (socket, @as("close") _, unit => unit) => unit = "on"

/** A socket that errors is gone; without a listener the error is thrown and
    takes the process with it, so every accepted socket needs one. */
@send external onSocketError: (socket, @as("error") _, JsExn.t => unit) => unit = "on"

/** `keepAlive` is deliberately absent: a caller that wants it sets it per
    socket, and defaulting it changes the behaviour of every consumer. */
@module("node:net")
external createServer: (socket => unit) => server = "createServer"

/** Binding to an explicit host is what keeps a server off every interface —
    pass `"127.0.0.1"` for loopback-only. */
@send external listen: (server, int, string, unit => unit) => unit = "listen"

@send external onServerError: (server, @as("error") _, JsExn.t => unit) => unit = "on"
@send external closeServer: (server, unit => unit) => unit = "close"

/** The port actually bound — the only way to learn it after listening on `0`.
    `Nullable`, because a server that is not listening reports `null`. */
@send external address: server => Nullable.t<{"port": int}> = "address"

/** Lets the process exit while the server is still listening — a diagnostic
    listener must not be the reason a CLI hangs at the end of its work. */
@send external unref: server => unit = "unref"

/** Connect to a listening server. The callback fires once the connection is up. */
@module("node:net")
external connect: (int, string, unit => unit) => socket = "createConnection"

// Bindings for the WHATWG `WebSocket` global.
//
// Available in browsers and in Node 21+ (unflagged in 22), which is what lets
// one binding serve both a browser client and a Node verification script — the
// two consumers that motivated this package.
//
// Text frames only. `data` is typed as `string` because every consumer here
// speaks a JSON-over-text protocol; a binary frame would arrive as a Blob or
// Buffer and mistype. If a binary consumer appears, add a separate accessor
// rather than widening `data` and breaking the text callers.

type t

/** Open a socket. `protocols` may be empty — `new WebSocket(url, [])` is valid
    and means "no subprotocol". The AppSync Events client passes two: the
    protocol name and a `header-<base64url>` auth blob. */
@new external make: (string, array<string>) => t = "WebSocket"

@send external send: (t, string) => unit = "send"

@send external close: t => unit = "close"

/** Close with an explicit code and reason (e.g. 4401 for an auth failure). */
@send external closeWith: (t, int, string) => unit = "close"

type messageEvent = {data: string}

type closeEvent = {
  code: int,
  reason: string,
  wasClean: bool,
}

/** Error events carry no useful cross-platform detail — the spec deliberately
    withholds it. Treat this as a signal, and read the close code for the
    reason. */
type errorEvent

@set external setOnOpen: (t, unit => unit) => unit = "onopen"
@set external setOnMessage: (t, messageEvent => unit) => unit = "onmessage"
@set external setOnClose: (t, closeEvent => unit) => unit = "onclose"
@set external setOnError: (t, errorEvent => unit) => unit = "onerror"

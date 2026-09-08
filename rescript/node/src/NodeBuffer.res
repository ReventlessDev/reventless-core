/** Bindings for Node's global [`Buffer`](https://nodejs.org/api/buffer.html).

    `t` aliases `Uint8Array.t` rather than being abstract: a Node `Buffer` *is* a
    `Uint8Array` subclass, so the bytes a stream hands over, the bytes
    {!NodeFs.readFileSyncBuffer} returns, and the bytes {!NodeFs.writeFileSyncBuffer}
    takes are all the same values. Aliasing lets them flow between those calls
    without a cast that would exist only to satisfy the type checker. */
type t = Uint8Array.t

/** Joins byte chunks into one buffer — how a request body is assembled from the
    chunks its `data` events deliver. */
@val @scope("Buffer")
external concat: array<t> => t = "concat"

/** Bakes the encoding in for the same reason {!NodeFs.readFileSync} does: the
    `(string, string)` form permits a different, silently wrong, encoding name. */
@val @scope("Buffer")
external fromStringUtf8: (string, @as("utf8") _) => t = "from"

/** Base64url, the alphabet a bearer token's segments are encoded in. Decoding
    never throws — a segment that is not base64url yields whatever bytes it can,
    so callers judge the result by whether it parses. */
@val @scope("Buffer")
external fromStringBase64Url: (string, @as("base64url") _) => t = "from"

@send
external toStringUtf8: (t, @as("utf8") _) => string = "toString"

@send
external toStringBase64Url: (t, @as("base64url") _) => string = "toString"

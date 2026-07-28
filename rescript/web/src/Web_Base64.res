// Bindings for the base64 globals.

/** Encode a binary string to base64. Note the WHATWG contract: `btoa` throws on
    any code point above U+00FF, so callers encoding UTF-8 text must widen it
    first. */
@val external btoa: string => string = "btoa"

/** Decode base64 to a binary string. */
@val external atob: string => string = "atob"

/** base64url — base64 with the URL-unsafe characters swapped and the padding
    dropped (RFC 4648 §5). Used wherever base64 travels in a URL, a header, or
    a WebSocket subprotocol, which is the only reason `btoa` is ever reached for
    in this codebase. */
let btoaUrl = (s: string): string =>
  btoa(s)->String.replaceAll("+", "-")->String.replaceAll("/", "_")->String.replaceAll("=", "")

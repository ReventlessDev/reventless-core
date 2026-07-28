// Bindings for the WHATWG `fetch` global.
//
// Designed against the call sites that already exist rather than the whole
// spec, because the failure mode here is well documented in this codebase:
// reventless-ui's `bindings/Fetch.res` modelled `method` as `[#get | #post]`
// and carried no `body` field at all, so nine files bypassed it and hand-rolled
// their own externals. A binding that cannot express what callers do does not
// reduce duplication — it adds one more variant.
//
// The surface therefore covers what the known consumers need: an arbitrary
// method string (GET/POST/PUT are all in use), `dict<string>` headers, an
// optional body that is sometimes binary (Seed_Upload PUTs raw bytes), an
// optional abort signal (CloneContext), and `ok`/`status`/`text`/`json` on the
// response.

module AbortController = {
  type signal
  type t = {signal: signal}

  @new external make: unit => t = "AbortController"

  @send external abort: (t, ~reason: string=?, unit) => unit = "abort"
}

module Body = {
  /** An opaque `BodyInit`. Build one with `string` or `raw`. */
  type t

  /** A UTF-8 string body — JSON, form-encoded, or plain text. */
  external string: string => t = "%identity"

  /** Any other `BodyInit` the runtime accepts: Buffer, Uint8Array, Blob,
      ArrayBuffer, FormData, URLSearchParams, ReadableStream.

      Deliberately unchecked. The accepted set differs between Node and
      browsers and changes with runtime versions, so enumerating it in a type
      here would be wrong somewhere and stale eventually. Callers passing
      binary (an upload PUT, say) know their runtime; callers passing text
      should use `string` and get the checking. */
  external raw: 'a => t = "%identity"
}

/** Request options. Every field is optional — `fetch(url, {})` is a GET. */
type init = {
  /** `"GET"` when absent. Any method the runtime accepts. */
  method?: string,
  headers?: dict<string>,
  body?: Body.t,
  signal?: AbortController.signal,
}

type response

/** Response headers. Not a plain object — `Headers` is an iterable interface,
    so it is read through `headerGet` rather than typed as `dict<string>`
    (which reventless-ui's binding did, and which silently returns undefined
    for every lookup). */
type headers
@send external headerGet: (headers, string) => Null.t<string> = "get"
@send external headerHas: (headers, string) => bool = "has"

@get external ok: response => bool = "ok"
@get external status: response => int = "status"
@get external statusText: response => string = "statusText"
@get external url: response => string = "url"
@get external redirected: response => bool = "redirected"
@get external headers: response => headers = "headers"

/** Read the body as text. A body may only be read once. */
@send external text: response => promise<string> = "text"

/** Read and parse the body as JSON. Rejects if the body is not valid JSON —
    which for an error response is common, so prefer `text` when the status is
    already known to be a failure. */
@send external json: response => promise<JSON.t> = "json"

@val external fetch: (string, init) => promise<response> = "fetch"

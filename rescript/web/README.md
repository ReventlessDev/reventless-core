# @reventlessdev/rescript-web

ReScript bindings for the WHATWG web globals: `fetch`, `WebSocket`, timers and
base64.

## Why this exists, and where the line is

These are **ambient globals, not `node:*` imports**. Everything here works
unchanged in a browser and in Node 18+ (WebSocket from 21). That is the whole
distinction from `rescript-node-streams` and its siblings, which bind
`import`ed Node modules and are server-only by construction.

The split matters in practice because the same two APIs are needed on both
sides of Reventless: the browser client subscribes to AppSync Events over
`WebSocket` and talks to the API over `fetch`, and server-side scripts do the
same things against the same endpoints.

## Design note

The surface is driven by call sites, not by the specification.

reventless-ui already had a `bindings/Fetch.res`. It modelled `method` as
`[#get | #post]` and carried **no `body` field at all**, so nine other files
bypassed it and hand-rolled their own `@val external fetch`. A binding that
cannot express what callers do does not reduce duplication — it becomes one
more variant to maintain.

So this package binds what the real consumers need (arbitrary method strings,
`dict<string>` headers, an optional body that is sometimes binary, an abort
signal, and `ok`/`status`/`text`/`json`) and deliberately omits what nothing
uses. Add to it when a consumer appears, not in anticipation of one.

## Usage

```rescript
open Web

let res = await Fetch.fetch(
  url,
  {
    method: "POST",
    headers: Dict.fromArray([("content-type", "application/json")]),
    body: Fetch.Body.string(payload),
  },
)
if res->Fetch.ok {
  let json = await res->Fetch.json
  // …
}
```

```rescript
let ws = Socket.make(url, ["my-protocol"])
ws->Socket.setOnOpen(() => ws->Socket.send(`{"type":"hello"}`))
ws->Socket.setOnMessage(evt => Console.log(evt.data))
ws->Socket.setOnClose(evt => Console.log2("closed", evt.code))
```

## Build

```bash
pnpm run build     # rescript build
```

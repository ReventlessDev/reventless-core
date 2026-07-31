/** ReScript bindings for the WHATWG web globals — `fetch`, `WebSocket`,
    timers, base64.

    These are ambient globals, not `node:*` imports, and that is the line this
    package draws: everything here works unchanged in a browser and in Node 18+
    (WebSocket from 21). That is what lets one binding serve a browser client
    and a server-side script, which `rescript-node` — server-only by
    construction — cannot.

    Entry module: use `Web.Fetch.fetch`, `Web.Socket.make`, and so on. The
    submodules are also importable directly (`Web_Fetch`) when only one is
    needed. */

module Fetch = Web_Fetch
module Socket = Web_Socket
module Timers = Web_Timers
module Base64 = Web_Base64

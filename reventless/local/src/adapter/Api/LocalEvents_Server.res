// LocalEvents_Server — local AppSync Events transport.
//
// Speaks the AppSync Events realtime wire protocol on the domain dev server
// so clients use one code path for dev and AWS:
//   ws  {server}/events/realtime  — connection_init/ack, subscribe/unsubscribe,
//                                   stringified-JSON `data` frames
//   POST {server}/events          — the publish endpoint, `/client/**` only
//                                   (AWS analogue: POST {endpoint} with a JWT)
//
// Two producers feed `broadcast`:
//   - LocalBus state changes (wired via `subscribeToAllStateChanges` in
//     Platform.res) → `/default/{readModel}/{entityKey}` — the local parity
//     of the AWS StateTopic Lambda publishes.
//   - client HTTP publishes → `/client/**` (ephemeral fan-out: presence,
//     typing, transient chat). `/default/**` publishes are rejected 403,
//     mirroring the AWS namespaces' publish-auth asymmetry.
//
// Frame/connection handling is socket-free (a `connection` is just a `send`
// callback + subscription dict) so tests drive the protocol without ws.
// See docs/plans/events-client-publish-channels.md.

module YG = GraphqlYoga

let log = ReventlessCore.Logger.fromEnv()

// -- Channel naming ----------------------------------------------------------

// Mirrors AppSyncEventsSigner_Ops.pathSegment (aws) and the client's channel
// normalizer: any char outside [A-Za-z0-9-] becomes `-`.
let pathSegment = (s: string): string =>
  s->String.replaceRegExp(/[^A-Za-z0-9-]/g, "-")

let clientChannelPrefix = "/client/"

/** Subscription channels may end in a `*` wildcard segment — AppSync
    semantics: prefix match over the remaining path (any depth). */
let channelMatches = (~subscription: string, ~channel: string): bool =>
  if subscription->String.endsWith("/*") {
    let prefix = subscription->String.slice(~start=0, ~end=String.length(subscription) - 1)
    channel->String.startsWith(prefix)
  } else {
    subscription == channel
  }

// -- Connection registry -----------------------------------------------------

type connection = {
  id: int,
  send: string => unit,
  /** subscription id → channel (exact, or ending in a `*` wildcard). */
  subscriptions: dict<string>,
}

let connections: ref<array<connection>> = ref([])
let nextConnectionId = ref(0)

let addConnection = (~send: string => unit): connection => {
  nextConnectionId.contents = nextConnectionId.contents + 1
  let conn = {id: nextConnectionId.contents, send, subscriptions: Dict.make()}
  connections.contents->Array.push(conn)
  conn
}

let removeConnection = (conn: connection): unit =>
  connections.contents = connections.contents->Array.filter(c => c.id != conn.id)

/** Test/reset hook — drops all registered connections. */
let resetConnections = (): unit => connections.contents = []

// -- Outbound frames ---------------------------------------------------------

let frame = (fields: array<(string, JSON.t)>): string =>
  fields->Dict.fromArray->JSON.Encode.object->JSON.stringify

let connectionAckFrame = frame([
  ("type", JSON.Encode.string("connection_ack")),
  ("connectionTimeoutMs", JSON.Encode.int(300_000)),
])

let dataFrame = (~subscriptionId: string, ~event: string): string =>
  frame([
    ("type", JSON.Encode.string("data")),
    ("id", JSON.Encode.string(subscriptionId)),
    // `event` is a *stringified* JSON payload, exactly as AWS delivers it —
    // the client JSON-parses the string.
    ("event", JSON.Encode.string(event)),
  ])

// -- Broadcast ---------------------------------------------------------------

/** Deliver one already-stringified event to every matching subscription. */
let broadcast = (~channel: string, ~event: string): unit =>
  connections.contents->Array.forEach(conn =>
    conn.subscriptions
    ->Dict.toArray
    ->Array.forEach(((subscriptionId, subChannel)) =>
      if channelMatches(~subscription=subChannel, ~channel) {
        conn.send(dataFrame(~subscriptionId, ~event))
      }
    )
  )

/** LocalBus bridge: a Source B change descriptor becomes a publish on the
    same channel the AWS StateTopic Lambda would use. No-op without matching
    subscribers, so wiring order against server start doesn't matter. */
let broadcastStateChange = (~name: string, ~descriptor: JSON.t): unit => {
  let entityKey =
    descriptor
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get("id"))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("")
  if entityKey != "" {
    // Channel root MUST equal what the host-shell subscribes to. AutoLive uses
    // `queryField = listFieldName` (plural, plugin-qualified, e.g.
    // "Catalog_Products"), not the read-model store name ("Products"). Translate
    // through the same registry the AWS StateTopic wiring uses (aws/Platform.res)
    // — publishing on the raw store name lands descriptors on a channel no client
    // listens to, so the socket stays Open but no view ever refreshes.
    let topicName =
      ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
      ->Dict.get(name)
      ->Option.map(qn => qn.listFieldName)
      ->Option.getOr(name)
    let channel = `/default/${pathSegment(topicName)}/${pathSegment(entityKey)}`
    broadcast(~channel, ~event=descriptor->JSON.stringify)
  }
}

// -- Inbound frames (subscribe side) -----------------------------------------

let decodeStringField = (json: JSON.t, field: string): option<string> =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get(field))->Option.flatMap(JSON.Decode.string)

/** Handle one client→server text frame on an established connection. */
let handleFrame = (conn: connection, text: string): unit => {
  let parsed = try Some(text->JSON.parseOrThrow) catch {
  | _ => None
  }
  switch parsed {
  | None => ()
  | Some(json) =>
    switch decodeStringField(json, "type") {
    | Some("connection_init") => conn.send(connectionAckFrame)
    | Some("subscribe") =>
      switch (decodeStringField(json, "id"), decodeStringField(json, "channel")) {
      | (Some(id), Some(channel)) =>
        conn.subscriptions->Dict.set(id, channel)
        conn.send(
          frame([
            ("type", JSON.Encode.string("subscribe_success")),
            ("id", JSON.Encode.string(id)),
          ]),
        )
      | _ => ()
      }
    | Some("unsubscribe") =>
      switch decodeStringField(json, "id") {
      | Some(id) =>
        conn.subscriptions->Dict.delete(id)
        conn.send(
          frame([
            ("type", JSON.Encode.string("unsubscribe_success")),
            ("id", JSON.Encode.string(id)),
          ]),
        )
      | None => ()
      }
    | _ => ()
    }
  }
}

// -- Auth --------------------------------------------------------------------

type nodeBuffer
@val @scope("Buffer") external bufferFrom: (string, string) => nodeBuffer = "from"
@send external bufferToString: (nodeBuffer, string) => string = "toString"

let stripBearer = (token: string): string =>
  if token->String.startsWith("Bearer ") {
    token->String.slice(~start=7, ~end=String.length(token))->String.trim
  } else {
    token->String.trim
  }

/** Local auth rule (mirrors the HTTP dispatch): absent token = anonymous,
    allowed; present token must HMAC-verify. */
let tokenIsInvalid = (token: option<string>): bool =>
  switch token {
  | None => false
  | Some(t) => LocalAuth.Login.verifyAndDecode(stripBearer(t))->Option.isNone
  }

/** Extract the Authorization value from the `header-<base64url(JSON)>`
    subprotocol entry the client offers on connect. */
let authFromSubprotocolHeader = (headerValue: string): option<string> =>
  headerValue
  ->String.split(",")
  ->Array.map(String.trim)
  ->Array.find(p => p->String.startsWith("header-"))
  ->Option.flatMap(p => {
    let blob = p->String.slice(~start=7, ~end=String.length(p))
    try {
      bufferFrom(blob, "base64url")
      ->bufferToString("utf8")
      ->JSON.parseOrThrow
      ->decodeStringField("Authorization")
    } catch {
    | _ => None
    }
  })

// -- Publish route (transport-free; HTTP wiring lives in the dispatch) -------

let jsonError = (message: string): JSON.t =>
  JSON.Encode.object(Dict.fromArray([("error", JSON.Encode.string(message))]))

/** Handle `POST /events`. Returns `(status, responseBody)`.
    Contract (AWS parity): body `{"channel": "/client/…", "events": ["<json>", …]}`,
    `Authorization` header carries the token (raw or `Bearer `-prefixed). Only
    channels under the client prefix are publishable; each event must be a
    string that parses as JSON.
    Reply: `{"successful": [{"index": n}], "failed": [{"index": n}]}`. */
let handlePublish = (~authorization: option<string>, ~body: string): (int, JSON.t) =>
  if tokenIsInvalid(authorization) {
    (401, jsonError("Invalid token"))
  } else {
    let parsed = try Some(body->JSON.parseOrThrow) catch {
    | _ => None
    }
    switch parsed {
    | None => (400, jsonError("Invalid JSON body"))
    | Some(json) =>
      let channel = decodeStringField(json, "channel")
      let events =
        json
        ->JSON.Decode.object
        ->Option.flatMap(o => o->Dict.get("events"))
        ->Option.flatMap(JSON.Decode.array)
      switch (channel, events) {
      | (Some(channel), Some(events)) if events->Array.length > 0 =>
        if !(channel->String.startsWith(clientChannelPrefix)) {
          // Publish-auth asymmetry: `/default/**` (and anything else) is
          // reserved for the server-side publishers.
          (403, jsonError(`Clients may only publish under ${clientChannelPrefix}`))
        } else {
          let successful = []
          let failed = []
          events->Array.forEachWithIndex((event, index) => {
            let entry = Dict.fromArray([("index", JSON.Encode.int(index))])->JSON.Encode.object
            switch event->JSON.Decode.string {
            | Some(s) =>
              let valid = try {
                let _ = s->JSON.parseOrThrow
                true
              } catch {
              | _ => false
              }
              if valid {
                broadcast(~channel, ~event=s)
                successful->Array.push(entry)
              } else {
                failed->Array.push(entry)
              }
            | None => failed->Array.push(entry)
            }
          })
          (
            200,
            JSON.Encode.object(
              Dict.fromArray([
                ("successful", JSON.Encode.array(successful)),
                ("failed", JSON.Encode.array(failed)),
              ]),
            ),
          )
        }
      | _ => (400, jsonError("Body must carry `channel` and a non-empty `events` array"))
      }
    }
  }

// -- WebSocket attach --------------------------------------------------------

let realtimePath = "/events/realtime"
let subprotocol = "aws-appsync-event-ws"

type wsSocket
type incomingMessage = {headers: dict<string>}
type wssOptions = {
  "server": YG.httpServer,
  "path": string,
  // ws calls this to pick the response subprotocol; the client offers
  // ["aws-appsync-event-ws", "header-<blob>"] and expects the first back.
  "handleProtocols": (unknown, unknown) => string,
}
type wss
@new @module("ws") external newWebSocketServer: wssOptions => wss = "WebSocketServer"
@send
external onConnection: (wss, @as("connection") _, (wsSocket, incomingMessage) => unit) => unit =
  "on"
type wsMessageData
@send external wsMessageToString: (wsMessageData, string) => string = "toString"
@send external onMessage: (wsSocket, @as("message") _, wsMessageData => unit) => unit = "on"
@send external onSocketClose: (wsSocket, @as("close") _, unit => unit) => unit = "on"
@send external wsSend: (wsSocket, string) => unit = "send"
@send external wsClose: (wsSocket, int, string) => unit = "close"

/** Attach the realtime WebSocket endpoint to the domain dev server. Called
    from DomainGraphQL_Server.start(), so every start mode carries it. */
let attach = (~server: YG.httpServer, ~port: int): unit => {
  let wss = newWebSocketServer({
    "server": server,
    "path": realtimePath,
    "handleProtocols": (_protocols, _req) => subprotocol,
  })
  wss->onConnection((ws, req) => {
    let auth =
      req.headers
      ->Dict.get("sec-websocket-protocol")
      ->Option.flatMap(authFromSubprotocolHeader)
    if tokenIsInvalid(auth) {
      ws->wsClose(4401, "Invalid token")
    } else {
      let conn = addConnection(~send=f => ws->wsSend(f))
      ws->onMessage(data => handleFrame(conn, data->wsMessageToString("utf8")))
      ws->onSocketClose(() => removeConnection(conn))
    }
  })
  log.info(
    ~comp="Events:Local",
    `events transport on ws://localhost:${port->Int.toString}${realtimePath} (publish: POST /events)`,
  )
}

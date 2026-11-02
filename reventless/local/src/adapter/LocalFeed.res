// A line feed on a loopback socket, for a tool that watches a running platform
// from outside it. The event tap and the log feed are two of these.
//
// Watching must never change what is watched, so each listener gets its own
// bounded queue (by count and by bytes). When a listener cannot keep up, its
// oldest lines are dropped and one `{"kind":"skipped","count":N}` line is sent in
// their place. Writes honour the socket's backpressure: once `write` returns
// false, nothing more is written to that socket until it drains. The publishing
// side never waits.
//
// On connect a listener may send one filter line (JSON): plugins, a minimum
// level, components, event types, a correlation id. Only matching lines are sent
// to it. The feed starts when that line arrives, or after a short wait without
// one, in which case the listener gets every line, as readers that never send a
// filter always have.

let log = ReventlessCore.Logger.fromEnv()

type setting =
  | Off
  | Ephemeral
  | Fixed(int)

/** A port only when the value IS one in the unprivileged range; `off`, `false`
    and `none` switch the socket off; anything else, unset included, takes an
    ephemeral port. */
let settingOf = (value: option<string>): setting =>
  switch value->Option.map(String.trim)->Option.filter(v => v != "") {
  | Some("off") | Some("false") | Some("none") => Off
  | Some(v) =>
    switch Int.fromString(v) {
    | Some(p) if p >= 1024 && p <= 65535 => Fixed(p)
    | _ => Ephemeral
    }
  | None => Ephemeral
  }

// ─── Filter ──────────────────────────────────────────────────────────────────

/** What a listener asked for. A field that is absent does not narrow. */
type filter = {
  plugins?: array<string>,
  level?: ReventlessCore.Logger.level,
  components?: array<string>,
  eventTypes?: array<string>,
  correlationId?: string,
}

/** The fields of a filter a feed applies. A field the feed does not honour is
    ignored, so one filter line can be sent to every feed. */
type filterField =
  | Plugins
  | Level
  | Components
  | EventTypes
  | CorrelationId

/** What a line is about, as far as a filter can ask. */
type facets = {
  plugin?: string,
  level?: ReventlessCore.Logger.level,
  comp?: string,
  eventType?: string,
  correlationId?: string,
}

type item = {line: string, facets: facets}

let levelOfString = (s: string): option<ReventlessCore.Logger.level> =>
  switch s->String.toLowerCase {
  | "debug" => Some(Debug)
  | "info" => Some(Info)
  | "warn" | "warning" => Some(Warn)
  | "error" => Some(Error)
  | _ => None
  }

/** Reads a filter line. `None` for a line that is not a JSON object; unknown
    keys are ignored. */
let parseFilter = (line: string): option<filter> =>
  switch line->JSON.parseOrThrow->JSON.Decode.object {
  | Some(d) =>
    let strings = k =>
      d
      ->Dict.get(k)
      ->Option.flatMap(JSON.Decode.array)
      ->Option.map(a => a->Array.filterMap(JSON.Decode.string))
    let string = k => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
    Some({
      plugins: ?strings("plugins"),
      level: ?(string("level")->Option.flatMap(levelOfString)),
      components: ?strings("components"),
      eventTypes: ?strings("eventTypes"),
      correlationId: ?string("correlationId"),
    })
  | None => None
  | exception _ => None
  }

/** Whether a line passes a filter. A filter field the feed honours narrows to
    lines that carry that facet and match it; a line without the facet (a log
    line with no plugin, say) does not pass a filter that names one. */
let matches = (~honours: array<filterField>, filter: filter, facets: facets): bool => {
  let applies = field => honours->Array.includes(field)
  let oneOf = (wanted: option<array<string>>, field, value: option<string>) =>
    switch wanted {
    | Some(list) if applies(field) => value->Option.mapOr(false, v => list->Array.includes(v))
    | _ => true
    }
  oneOf(filter.plugins, Plugins, facets.plugin) &&
  oneOf(filter.components, Components, facets.comp) &&
  oneOf(filter.eventTypes, EventTypes, facets.eventType) &&
  switch filter.correlationId {
  | Some(id) if applies(CorrelationId) => facets.correlationId == Some(id)
  | _ => true
  } &&
  switch filter.level {
  | Some(min) if applies(Level) =>
    facets.level->Option.mapOr(false, l =>
      ReventlessCore.Logger.levelToInt(l) >= ReventlessCore.Logger.levelToInt(min)
    )
  | _ => true
  }
}

let skippedLine = (count: int): string =>
  Dict.fromArray([("kind", JSON.Encode.string("skipped")), ("count", JSON.Encode.int(count))])
  ->JSON.Encode.object
  ->JSON.stringify

// ─── Listeners ───────────────────────────────────────────────────────────────

type phase =
  // Connected; waiting for a filter line, or for the wait to end.
  | Waiting
  | Live

/** Where a listener's lines go: a socket, or a subscription on the platform API.
    `write` returns false when the reader asks to wait; `onceDrain` calls back
    when it can take more. */
type sink = {
  write: string => bool,
  onceDrain: (unit => unit) => unit,
  // Bytes the sink itself holds, not yet taken by the reader.
  buffered: unit => int,
  close: unit => unit,
}

@get external writableLengthOf: NodeNet.socket => Nullable.t<int> = "writableLength"

let socketSink = (socket: NodeNet.socket): sink => {
  write: line => socket->NodeNet.write(line ++ "\n"),
  onceDrain: f => socket->NodeNet.onceSocketDrain(f),
  buffered: () => socket->writableLengthOf->Nullable.toOption->Option.getOr(0),
  close: () => NodeNet.destroySocket(socket),
}

type listener = {
  sink: sink,
  mutable phase: phase,
  mutable filter: filter,
  // Lines not yet written, oldest first; `head` is the index of the oldest.
  mutable queue: array<string>,
  mutable head: int,
  mutable queuedBytes: int,
  // Lines dropped since the last `skipped` line was sent.
  mutable skipped: int,
  // `write` returned false; nothing more is written until `drain`.
  mutable blocked: bool,
  mutable inbound: string,
  mutable timer: option<timeoutId>,
}

type t = {
  name: string,
  honours: array<filterField>,
  maxLines: int,
  maxBytes: int,
  filterWaitMs: int,
  // Sent first to a listener that starts, filtered: what happened before it
  // connected (the log feed's recent records).
  backlog: option<unit => array<item>>,
  mutable listeners: array<listener>,
  mutable server: option<NodeNet.server>,
  mutable port: option<int>,
}

let make = (
  ~name: string,
  ~honours: array<filterField>,
  ~backlog: option<unit => array<item>>=?,
  ~maxLines: int=10_000,
  ~maxBytes: int=8 * 1024 * 1024,
  ~filterWaitMs: int=100,
  (),
): t => {
  name,
  honours,
  maxLines,
  maxBytes,
  filterWaitMs,
  backlog,
  listeners: [],
  server: None,
  port: None,
}

let port = (feed: t) => feed.port

let isLive = (l: listener) =>
  switch l.phase {
  | Live => true
  | Waiting => false
  }

/** Whether any listener is being sent lines, so a publisher can skip building a
    line nobody gets. */
let hasReaders = (feed: t) => feed.listeners->Array.some(isLive)

let queuedLines = (l: listener) => l.queue->Array.length - l.head

/** Bytes held for listeners, all of them: what watching costs this process. */
let queuedBytes = (feed: t) => feed.listeners->Array.reduce(0, (sum, l) => sum + l.queuedBytes)

/** Bytes held for listeners, queued here and buffered by their sinks: what
    watching costs this process at most. */
let heldBytes = (feed: t) =>
  feed.listeners->Array.reduce(0, (sum, l) => sum + l.queuedBytes + l.sink.buffered())

let drop = (feed: t, l: listener) => {
  l.timer->Option.forEach(clearTimeout)
  feed.listeners = feed.listeners->Array.filter(other => other !== l)
}

let dequeue = (l: listener): option<string> =>
  if queuedLines(l) == 0 {
    None
  } else {
    let line = l.queue->Array.getUnsafe(l.head)
    l.head = l.head + 1
    l.queuedBytes = l.queuedBytes - line->String.length

    // Compact once the consumed prefix is most of the array.
    if l.head > 1024 && l.head * 2 > l.queue->Array.length {
      l.queue = l.queue->Array.slice(~start=l.head, ~end=l.queue->Array.length)
      l.head = 0
    }
    Some(line)
  }

/** Writes until the queue is empty or the socket asks to wait. A write that
    throws (a closed peer) drops the listener and keeps the others. */
let rec pump = (feed: t, l: listener) => {
  let continue = ref(true)
  while continue.contents && !l.blocked {
    let next = if l.skipped > 0 {
      let line = skippedLine(l.skipped)
      l.skipped = 0
      Some(line)
    } else {
      dequeue(l)
    }
    switch next {
    | None => continue := false
    | Some(line) =>
      switch l.sink.write(line) {
      | true => ()
      | false =>
        l.blocked = true
        l.sink.onceDrain(() => {
          l.blocked = false
          pump(feed, l)
        })
      | exception _ =>
        drop(feed, l)
        continue := false
      }
    }
  }
}

let enqueue = (feed: t, l: listener, line: string) => {
  l.queue->Array.push(line)
  l.queuedBytes = l.queuedBytes + line->String.length
  // Oldest first, so what is kept is the most recent.
  while queuedLines(l) > 0 && (queuedLines(l) > feed.maxLines || l.queuedBytes > feed.maxBytes) {
    let _ = dequeue(l)
    l.skipped = l.skipped + 1
  }
}

let offer = (feed: t, l: listener, item: item) =>
  if isLive(l) && matches(~honours=feed.honours, l.filter, item.facets) {
    enqueue(feed, l, item.line)
    pump(feed, l)
  }

/** Sends a line to every listener whose filter it passes. Never waits. */
let publish = (feed: t, item: item): unit =>
  feed.listeners->Array.forEach(l => offer(feed, l, item))

/** A line with nothing a filter can ask about: every unfiltered listener gets
    it, and no filtered one does. */
let broadcast = (feed: t, line: string): unit => publish(feed, {line, facets: {}})

let start_ = (feed: t, l: listener, filter: option<filter>) =>
  if !isLive(l) {
    l.timer->Option.forEach(clearTimeout)
    l.timer = None
    filter->Option.forEach(f => l.filter = f)
    l.phase = Live
    feed.backlog->Option.forEach(backlog =>
      backlog()->Array.forEach(item =>
        if matches(~honours=feed.honours, l.filter, item.facets) {
          enqueue(feed, l, item.line)
        }
      )
    )
    pump(feed, l)
  }

let newListener = (sink: sink, phase: phase): listener => {
  sink,
  phase,
  filter: {},
  queue: [],
  head: 0,
  queuedBytes: 0,
  skipped: 0,
  blocked: false,
  inbound: "",
  timer: None,
}

let accept = (feed: t, socket: NodeNet.socket) => {
  let l = newListener(socketSink(socket), Waiting)
  socket->NodeNet.setEncoding("utf8")
  // A connection is someone watching the platform, until its socket closes.
  LocalIdleExit.connected()
  let gone = ref(false)
  let leave = () =>
    if !gone.contents {
      gone := true
      LocalIdleExit.disconnected()
    }
  socket->NodeNet.onSocketError(_ => {
    drop(feed, l)
    leave()
  })
  socket->NodeNet.onSocketClose(() => {
    drop(feed, l)
    leave()
  })
  socket->NodeNet.onSocketData(chunk =>
    if !isLive(l) {
      l.inbound = l.inbound ++ chunk
      switch l.inbound->String.indexOf("\n") {
      | -1 =>
        // A listener that writes without ever ending a line is not given a
        // buffer to grow without bound.
        if l.inbound->String.length > 64 * 1024 {
          l.inbound = ""
          start_(feed, l, None)
        }
      | i =>
        let line = l.inbound->String.slice(~start=0, ~end=i)
        l.inbound = ""
        switch parseFilter(line) {
        | Some(_) as f => start_(feed, l, f)
        | None =>
          log.warn(~comp=feed.name, `ignored a filter line that is not a JSON object`)
          start_(feed, l, None)
        }
      }
    }
  )
  l.timer = Some(setTimeout(() => start_(feed, l, None), feed.filterWaitMs))
  feed.listeners = feed.listeners->Array.concat([l])
}

/** Binds the socket and reports the port it got, through `~onBound`, once it is
    listening. Best-effort: a platform whose feed cannot bind still serves. */
let start = (feed: t, ~setting: setting, ~onBound: int => unit=_ => (), ()): unit =>
  switch (setting, feed.server) {
  | (Off, _) | (_, Some(_)) => ()
  | (setting, None) =>
    let requested = switch setting {
    | Fixed(p) => p
    // 0 lets the OS pick, so parallel platforms in one directory never collide.
    | Off | Ephemeral => 0
    }
    let s = NodeNet.createServer(socket => accept(feed, socket))
    s->NodeNet.onServerError(err => {
      log.warn(
        ~comp=feed.name,
        `could not listen: ${err->JsExn.message->Option.getOr("unknown error")}`,
      )
      feed.server = None
      feed.port = None
    })
    // A diagnostic listener must never be why the process stays alive.
    s->NodeNet.unref
    s->NodeNet.listen(requested, "127.0.0.1", () =>
      switch s->NodeNet.address->Nullable.toOption {
      | Some(addr) =>
        let bound = addr["port"]
        feed.port = Some(bound)
        log.info(~comp=feed.name, `listening on 127.0.0.1:${bound->Int.toString}`)
        onBound(bound)
      | None => ()
      }
    )
    feed.server = Some(s)
  }

/** Test seam: forgets listeners and server without closing anything. */
let resetForTests = (feed: t) => {
  feed.listeners->Array.forEach(l => l.timer->Option.forEach(clearTimeout))
  feed.listeners = []
  feed.server = None
  feed.port = None
}

/** Test seam: a listener that is sent every line from now on. */
let addConnectionForTests = (feed: t, socket: NodeNet.socket) =>
  feed.listeners = feed.listeners->Array.concat([newListener(socketSink(socket), Live)])

/** A listener that is not a socket (a subscription on the platform API), started
    at once with its filter. Returns the function that removes it. */
let subscribe = (feed: t, ~filter: filter, sink: sink): (unit => unit) => {
  let l = newListener(sink, Waiting)
  feed.listeners = feed.listeners->Array.concat([l])
  start_(feed, l, Some(filter))
  () => drop(feed, l)
}

/** Test seam: releases the port, so a suite can bind it again. */
let stopForTests = (feed: t): promise<unit> =>
  switch feed.server {
  | None =>
    resetForTests(feed)
    Promise.resolve()
  | Some(s) =>
    feed.listeners->Array.forEach(l => l.sink.close())
    resetForTests(feed)
    Promise.make((resolve, _reject) => s->NodeNet.closeServer(() => resolve()))
  }

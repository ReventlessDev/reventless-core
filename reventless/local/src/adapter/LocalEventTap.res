// The event tap's second sink: LocalBus's NDJSON lines, unchanged, over a loopback
// socket — so a tool that did not spawn this platform can read its timeline.
//
// On by default, on an ephemeral port published in the registry entry. A socket
// nobody connects to costs nothing visible, and the registry is already how a
// reader finds this platform — so the port never needed to be well-known, which is
// what let it stop being configured. The noisy half (a line per event on stdout)
// stays opt-in. `REVENTLESS_EVENT_TAP=off` disables the socket too.
// See docs/plans/done/one-local-platform-one-store.md.

let log = ReventlessCore.Logger.fromEnv()

let envVar = "REVENTLESS_EVENT_TAP"

type setting =
  | Off
  | Ephemeral
  | Fixed(int)

let envValue = (~env: dict<string>): option<string> =>
  env->Dict.get(envVar)->Option.map(String.trim)->Option.filter(v => v != "")

/** What the env var asks the socket to do.

    A port only when the value IS one in the unprivileged range: the runner has
    passed `ndjson` since the tap existed, and someone writing `=1` means "on", not
    port 1. Everything else — unset included — takes the ephemeral default. */
let settingFromEnv = (~env=NodeProcess.env): setting =>
  switch envValue(~env) {
  | Some("off") | Some("false") | Some("none") => Off
  | Some(v) =>
    switch Int.fromString(v) {
    | Some(p) if p >= 1024 && p <= 65535 => Fixed(p)
    | _ => Ephemeral
    }
  | None => Ephemeral
  }

/** Whether to ALSO write each line to stdout. Opt-in and unchanged: this is the
    half with a visible cost, and it exists for the child whose stdout the runner
    reads. `off` silences both. */
let stdoutEnabled = (~env=NodeProcess.env): bool =>
  switch envValue(~env) {
  | Some("off") | Some("false") | Some("none") | None => false
  | Some(_) => true
  }

let connections: ref<array<NodeNet.socket>> = ref([])
let server: ref<option<NodeNet.server>> = ref(None)
let listeningPort: ref<option<int>> = ref(None)

/** The port the socket is actually bound to, known only once `listen` calls back —
    which is why {!start} takes `~onBound` rather than the caller reading this
    straight after. `None` until then, and if the bind fails. */
let port = () => listeningPort.contents

/** Whether anyone is reading, so the hot path can skip building a line nobody
    wants. */
let hasReaders = () => connections.contents->Array.length > 0

let drop = (socket: NodeNet.socket) =>
  connections := connections.contents->Array.filter(s => s !== socket)

/** Guarded per socket: a write to a closed peer throws, and one dead reader must
    not cost the others their events or the platform its run. */
let broadcast = (line: string): unit =>
  if hasReaders() {
    connections.contents->Array.forEach(socket =>
      switch socket->NodeNet.write(line ++ "\n") {
      | _ => ()
      | exception _ => drop(socket)
      }
    )
  }

/** Binds the tap socket and reports the port it got.

    `~onBound` fires only after a successful bind, so a caller publishes a port
    that is genuinely listening rather than one it hoped for. Best-effort in every
    failure mode: a platform whose diagnostic socket cannot bind must still serve,
    and simply carries no tap port. */
let start = (~env=NodeProcess.env, ~onBound: int => unit=_ => (), ()): unit =>
  switch (settingFromEnv(~env), server.contents) {
  | (Off, _) | (_, Some(_)) => ()
  | (setting, None) =>
    let requested = switch setting {
    | Fixed(p) => p
    // 0 lets the OS pick, so parallel platforms in one directory never collide and
    // no unrelated service can be advertised as ours.
    | Off | Ephemeral => 0
    }
    let s = NodeNet.createServer(socket => {
      socket->NodeNet.setEncoding("utf8")
      socket->NodeNet.onSocketError(_ => drop(socket))
      socket->NodeNet.onSocketClose(() => drop(socket))
      connections := connections.contents->Array.concat([socket])
    })
    s->NodeNet.onServerError(err => {
      log.warn(
        ~comp="EventTap",
        `could not listen: ${err->JsExn.message->Option.getOr("unknown error")}`,
      )
      server := None
      listeningPort := None
    })
    // A diagnostic listener must never be why the process stays alive.
    s->NodeNet.unref
    s->NodeNet.listen(requested, "127.0.0.1", () =>
      switch s->NodeNet.address->Nullable.toOption {
      | Some(addr) =>
        let bound = addr["port"]
        listeningPort := Some(bound)
        log.info(~comp="EventTap", `listening on 127.0.0.1:${bound->Int.toString}`)
        onBound(bound)
      | None => ()
      }
    )
    server := Some(s)
  }

/** Test seam: forgets connections and server without closing anything. */
let resetForTests = () => {
  connections := []
  server := None
  listeningPort := None
}

let addConnectionForTests = (socket: NodeNet.socket) =>
  connections := connections.contents->Array.concat([socket])

/** Test seam: actually releases the port, so a suite can bind it again. */
let stopForTests = (): promise<unit> =>
  switch server.contents {
  | None => Promise.resolve()
  | Some(s) =>
    connections.contents->Array.forEach(NodeNet.destroySocket)
    resetForTests()
    Promise.make((resolve, _reject) => s->NodeNet.closeServer(() => resolve()))
  }

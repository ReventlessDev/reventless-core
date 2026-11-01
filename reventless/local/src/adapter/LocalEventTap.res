// The event tap's second sink: LocalBus's NDJSON lines, unchanged, over a loopback
// socket — so a tool that did not spawn this platform can read its timeline.
//
// On by default, on an ephemeral port published in the registry entry. A socket
// nobody connects to costs nothing visible, and the registry is already how a
// reader finds this platform — so the port never needed to be well-known, which is
// what let it stop being configured. The noisy half (a line per event on stdout)
// stays opt-in. `REVENTLESS_EVENT_TAP=off` disables the socket too.
// See docs/plans/done/one-local-platform-one-store.md.
//
// The socket is a `LocalFeed`: each reader has a bounded queue and may send a
// filter line on connect. See docs/plans/the-local-platform-serves-what-is-watched.md.

let envVar = "REVENTLESS_EVENT_TAP"

type setting = LocalFeed.setting =
  | Off
  | Ephemeral
  | Fixed(int)

let envValue = (~env: dict<string>): option<string> =>
  env->Dict.get(envVar)->Option.map(String.trim)->Option.filter(v => v != "")

/** What the env var asks the socket to do.

    A port only when the value IS one in the unprivileged range: the runner has
    passed `ndjson` since the tap existed, and someone writing `=1` means "on", not
    port 1. Everything else — unset included — takes the ephemeral default. */
let settingFromEnv = (~env=NodeProcess.env): setting => LocalFeed.settingOf(envValue(~env))

/** Whether to ALSO write each line to stdout. Opt-in and unchanged: this is the
    half with a visible cost, and it exists for the child whose stdout the runner
    reads. `off` silences both. */
let stdoutEnabled = (~env=NodeProcess.env): bool =>
  switch envValue(~env) {
  | Some("off") | Some("false") | Some("none") | None => false
  | Some(_) => true
  }

/** The feed the socket serves. A filter line narrows it by plugin, event type and
    correlation id; the other filter fields are about log lines and are ignored
    here. */
let feed = LocalFeed.make(~name="EventTap", ~honours=[Plugins, EventTypes, CorrelationId], ())

/** The port the socket is actually bound to, known only once `listen` calls back —
    which is why {!start} takes `~onBound` rather than the caller reading this
    straight after. `None` until then, and if the bind fails. */
let port = () => feed->LocalFeed.port

/** Whether anyone is reading, so the hot path can skip building a line nobody
    wants. */
let hasReaders = () => feed->LocalFeed.hasReaders

/** Sends a line with what a filter can ask about it. */
let publish = (item: LocalFeed.item): unit => feed->LocalFeed.publish(item)

/** Guarded per socket: a write to a closed peer throws, and one dead reader must
    not cost the others their events or the platform its run. */
let broadcast = (line: string): unit => feed->LocalFeed.broadcast(line)

/** Binds the tap socket and reports the port it got.

    `~onBound` fires only after a successful bind, so a caller publishes a port
    that is genuinely listening rather than one it hoped for. Best-effort in every
    failure mode: a platform whose diagnostic socket cannot bind must still serve,
    and simply carries no tap port. */
let start = (~env=NodeProcess.env, ~onBound: int => unit=_ => (), ()): unit =>
  feed->LocalFeed.start(~setting=settingFromEnv(~env), ~onBound, ())

/** Test seam: forgets connections and server without closing anything. */
let resetForTests = () => feed->LocalFeed.resetForTests

let addConnectionForTests = (socket: NodeNet.socket) =>
  feed->LocalFeed.addConnectionForTests(socket)

/** Test seam: actually releases the port, so a suite can bind it again. */
let stopForTests = (): promise<unit> => feed->LocalFeed.stopForTests

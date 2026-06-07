// Local platform runner (features plan Phase 9). Spawns an app's reventless-local
// platform as a managed child with the LocalBus NDJSON event tap enabled, on
// per-session free ports, classifies its stdout into structured lifecycle/event
// callbacks, and tears the child down on cancellation. The CLI (`reventless-gwt
// platform`) wires the callbacks to FormatterVsCode; tests drive `classifyLine`
// directly.
//
// Channels (Spike A/B): commands in / state out go to the platform's GraphQL
// server (the runner just reports its endpoint); the live event stream comes from
// the tap on stdout — one sentinel-prefixed JSON line per published event.

let tapSentinel = "@@RVLESS_EVT@@ "

type lineClass =
  | Domain(JSON.t) // a tap line; the parsed `{event:"domainEvent",…}` payload
  | Ready // the Domain GraphQL server's "listening on …" line
  | Log(string) // any other stdout/stderr line (the platform's human logs)

// Pure line classifier — the unit-tested core. ANSI escapes around bracketed
// component tags survive substring checks, so readiness is detected structurally.
let classifyLine = (line: string): lineClass =>
  if line->String.startsWith(tapSentinel) {
    let jsonStr = line->String.slice(~start=tapSentinel->String.length, ~end=line->String.length)
    switch JSON.parseOrThrow(jsonStr) {
    | exception _ => Log(line)
    | json => Domain(json)
    }
  } else if line->String.includes("GraphQL:Domain") && line->String.includes("listening on") {
    Ready
  } else {
    Log(line)
  }

type callbacks = {
  onStart: (~package: string, ~dir: string, ~domainPort: int, ~platformPort: int) => unit,
  onReady: (~domainEndpoint: string) => unit,
  onDomainEvent: JSON.t => unit,
  onLog: string => unit,
  onStop: option<int> => unit,
}

// ── Free-port allocation ────────────────────────────────────────────────────
// One platform child per app folder; default ports (4000/4001/3001/3002) collide
// with a developer's own `dev:full`, so the runner binds ephemeral ports and
// passes them to the child via the env overrides added in Phase 1.
type netServer
@module("node:net") external _createServer: unit => netServer = "createServer"
@send external _listen: (netServer, int, string, unit => unit) => unit = "listen"
@send external _address: netServer => {"port": int} = "address"
@send external _close: (netServer, unit => unit) => unit = "close"

let openEphemeral = (): promise<(netServer, int)> =>
  Promise.make((resolve, _reject) => {
    let s = _createServer()
    s->_listen(0, "127.0.0.1", () => resolve((s, (s->_address)["port"])))
  })

// Hold all n open while collecting ports so they're guaranteed distinct, then
// release them just before the child binds.
let allocFreePorts = async (n: int): array<int> => {
  let servers = []
  let ports = []
  for _i in 1 to n {
    let (s, p) = await openEphemeral()
    servers->Array.push(s)
    ports->Array.push(p)
  }
  servers->Array.forEach(s => s->_close(() => ()))
  ports
}

// Discover the platform package under `roots`, spawn it with the tap + per-session
// ports + in-memory backend, stream its events through `callbacks`, and stay alive
// until cancelled (the child is killed via its process group on SIGTERM/SIGINT).
let run = async (~roots: array<string>, ~backend: string, ~callbacks: callbacks): int => {
  let pkgs = await PlatformScan.scan(roots)
  switch pkgs->Array.get(0) {
  | None =>
    callbacks.onLog(
      "no reventless-local platform package (src/Main.res.mjs + @reventlessdev/reventless-local) found under: " ++
      roots->Array.join(", "),
    )
    1
  | Some(pkg) =>
    let ports = await allocFreePorts(4)
    let dPort = ports->Array.getUnsafe(0)
    let pPort = ports->Array.getUnsafe(1)
    let dMcp = ports->Array.getUnsafe(2)
    let pMcp = ports->Array.getUnsafe(3)
    let env = Dict.fromArray([
      ("REVENTLESS_EVENT_TAP", "ndjson"),
      ("REVENTLESS_LOCAL_BACKEND", backend),
      ("REVENTLESS_DOMAIN_PORT", Int.toString(dPort)),
      ("REVENTLESS_PLATFORM_PORT", Int.toString(pPort)),
      ("REVENTLESS_DOMAIN_MCP_PORT", Int.toString(dMcp)),
      ("REVENTLESS_PLATFORM_MCP_PORT", Int.toString(pMcp)),
      ("NODE_OPTIONS", "--disable-warning=ExperimentalWarning"),
      // The gwt bin defaults LOG_LEVEL=silent so its OWN stdout stays pure NDJSON;
      // the platform child is a separate process whose stdout we parse, so it needs
      // real logs — the "listening on" line drives readiness and the rest becomes
      // platformLog. Override the inherited silent.
      ("LOG_LEVEL", "info"),
    ])

    callbacks.onStart(~package=pkg.name, ~dir=pkg.dir, ~domainPort=dPort, ~platformPort=pPort)

    // Run the compiled entrypoint directly with `node`. `src/Main.res.mjs` is plain
    // ESM, so it needs no tsx/loader, and spawning a single process (vs `pnpm run
    // serve` → `pnpm run serve` → `npx tsx`) keeps the child's stdout piped straight
    // to us — nested pnpm buffers a long-running grandchild's output, so the event
    // tap never streams through it. cwd = the package dir so `PackageVersion.fromCwd`
    // and relative paths resolve. We set the backend + tap + ports via env directly,
    // so the package's own serve script (which would otherwise pick them) is bypassed.
    let proc = ChildProcess.spawn("node", ["src/Main.res.mjs"], ~cwd=pkg.dir, ~env)
    Cancellation.onCancel(() => ChildProcess.killTree(proc, "SIGTERM"))

    let readyEmitted = ref(false)
    let handle = line =>
      switch classifyLine(line) {
      | Domain(json) => callbacks.onDomainEvent(json)
      | Ready =>
        if !readyEmitted.contents {
          readyEmitted := true
          callbacks.onReady(~domainEndpoint="http://localhost:" ++ Int.toString(dPort) ++ "/graphql")
        }
      | Log(l) => callbacks.onLog(l)
      }
    ChildProcess.onStdoutLine(proc, handle)
    ChildProcess.onStderrLine(proc, handle)
    ChildProcess.onClose(proc, code => callbacks.onStop(code))

    // Keep the process alive until cancelled — like runWatch, returning here would
    // let the bin wrapper process.exit and tear down the child immediately.
    await Promise.make((resolve, _reject) => Cancellation.onCancel(() => resolve()))
    0
  }
}

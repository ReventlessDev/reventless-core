// The tap's second sink. A tool that did not spawn the platform has no stdout to
// read, so an attached runner's timeline is dark without this.

@@warning("-44")

open JestGlobals

type recorder = {socket: NodeNet.socket, written: array<string>}

@module("./EventTapSocketFixtures.mjs")
external recordingSocket: unit => recorder = "recordingSocket"

@module("./EventTapSocketFixtures.mjs")
external throwingSocket: unit => NodeNet.socket = "throwingSocket"

let envWith = (value: option<string>): dict<string> =>
  switch value {
  | Some(v) => Dict.fromArray([(LocalEventTap.envVar, v)])
  | None => Dict.make()
  }

describe("LocalEventTap.settingFromEnv", () => {
  // The default is the point: the runner attaches to whatever `pnpm run serve`
  // started, and a tap nobody remembered to switch on is a dark timeline.
  testSync("defaults to an ephemeral socket when the var is unset", () => {
    expect(LocalEventTap.settingFromEnv(~env=envWith(None)))->toEqual(LocalEventTap.Ephemeral)
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some(""))))->toEqual(LocalEventTap.Ephemeral)
  })

  testSync("takes a port when the value is one", () =>
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some("4100"))))->toEqual(
      LocalEventTap.Fixed(4100),
    )
  )

  // `ndjson` is what the runner has passed since the tap existed, and `=1` means
  // "on" to anyone who writes it — never port 1. Both take the default socket.
  testSync("treats a non-port value as the default, not as a port", () => {
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some("ndjson"))))->toEqual(
      LocalEventTap.Ephemeral,
    )
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some("1"))))->toEqual(LocalEventTap.Ephemeral)
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some("80"))))->toEqual(LocalEventTap.Ephemeral)
    expect(LocalEventTap.settingFromEnv(~env=envWith(Some("70000"))))->toEqual(
      LocalEventTap.Ephemeral,
    )
  })

  testSync("switches the socket off on request", () =>
    ["off", "false", "none"]->Array.forEach(v =>
      expect(LocalEventTap.settingFromEnv(~env=envWith(Some(v))))->toEqual(LocalEventTap.Off)
    )
  )
})

describe("LocalEventTap.stdoutEnabled", () => {
  // The half with a visible cost keeps its opt-in: a line per event would drown
  // `pnpm run serve`, which is the command the socket default exists to serve.
  testSync("stays off unless the var is set", () => {
    expect(LocalEventTap.stdoutEnabled(~env=envWith(None)))->toEqual(false)
    expect(LocalEventTap.stdoutEnabled(~env=envWith(Some("ndjson"))))->toEqual(true)
    expect(LocalEventTap.stdoutEnabled(~env=envWith(Some("4100"))))->toEqual(true)
  })

  testSync("is silenced by off, along with the socket", () =>
    expect(LocalEventTap.stdoutEnabled(~env=envWith(Some("off"))))->toEqual(false)
  )
})

describe("LocalEventTap.broadcast", () => {
  testSync("hands every reader the line, newline-terminated", () => {
    LocalEventTap.resetForTests()
    let a = recordingSocket()
    let b = recordingSocket()
    LocalEventTap.addConnectionForTests(a.socket)
    LocalEventTap.addConnectionForTests(b.socket)

    LocalEventTap.broadcast(`@@RVLESS_EVT@@ {"seq":1}`)

    expect(a.written)->toEqual([`@@RVLESS_EVT@@ {"seq":1}\n`])
    expect(b.written)->toEqual([`@@RVLESS_EVT@@ {"seq":1}\n`])
  })

  // A write to a closed peer throws. One dead reader must not cost the others
  // their events, or the platform its run.
  testSync("drops a reader whose write throws, and keeps serving the rest", () => {
    LocalEventTap.resetForTests()
    let live = recordingSocket()
    LocalEventTap.addConnectionForTests(throwingSocket())
    LocalEventTap.addConnectionForTests(live.socket)

    LocalEventTap.broadcast("first")
    LocalEventTap.broadcast("second")

    expect(live.written)->toEqual(["first\n", "second\n"])
  })

  testSync("is inert with no readers", () => {
    LocalEventTap.resetForTests()
    LocalEventTap.broadcast("nobody is listening")
    expect(LocalEventTap.port())->toEqual(None)
  })
})

describe("LocalEventTap.start", () => {
  testSync("does not listen when the socket is switched off", () => {
    LocalEventTap.resetForTests()
    LocalEventTap.start(~env=envWith(Some("off")), ())
    expect(LocalEventTap.port())->toEqual(None)
  })

  // The default path, and the one that matters: no env var at all, a port the OS
  // picks, reported only once it is actually bound.
  test("binds an ephemeral port by default and reports the one it got", async () => {
    LocalEventTap.resetForTests()
    let bound = await Promise.make((resolve, _reject) =>
      LocalEventTap.start(~env=envWith(None), ~onBound=p => resolve(p), ())
    )
    expect(bound > 0)->toEqual(true)
    // What the registry entry will carry — the real port, not a hoped-for one.
    expect(LocalEventTap.port())->toEqual(Some(bound))
    await LocalEventTap.stopForTests()
  })

  // The round trip the runner will make: connect to the advertised port, read
  // the same sentinel-prefixed lines it reads off stdout today.
  test("serves the lines it is sent on the port it was named", async () => {
    LocalEventTap.resetForTests()
    let port = 47311
    let bound = await Promise.make((resolve, _reject) =>
      LocalEventTap.start(~env=envWith(Some(port->Int.toString)), ~onBound=p => resolve(p), ())
    )
    expect(bound)->toEqual(port)

    let received = await Promise.make((resolve, _reject) => {
      let socket = NodeNet.connect(port, "127.0.0.1", () => ())
      socket->NodeNet.setEncoding("utf8")
      socket->NodeNet.onSocketError(e =>
        resolve("connect failed: " ++ e->JsExn.message->Option.getOr("unknown"))
      )
      // Re-sent until it lands: the server's accept and the client's connect are
      // separate events, so a single broadcast could beat the connection.
      let ticker = ref(None)
      socket->NodeNet.onSocketData(chunk => {
        ticker.contents->Option.forEach(clearInterval)
        resolve(chunk)
      })
      ticker := Some(setInterval(() => LocalEventTap.broadcast(`@@RVLESS_EVT@@ {"seq":7}`), 5))
    })

    expect(received)->toEqual(`@@RVLESS_EVT@@ {"seq":7}\n`)
    await LocalEventTap.stopForTests()
  })
})

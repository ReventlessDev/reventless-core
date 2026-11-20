open JestGlobals
open ReventlessSeed

// The runtime against the fixture app, started as a child process: chargers
// meter through the signed door at a speed, a charger added to the view starts
// metering without a restart, and a reading can be sent by hand. Everything the
// stand-ins need is read from the platform's registry entry.

let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let fixtureDir = NodePath.join([here, "..", "fixture"])
let scratch = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "standin-"]))
let accountsFile = NodePath.join([scratch, "accounts.yaml"])
let port = 48000 + Math.Int.random(0, 300) * 10

let env = () => {
  let env = NodeProcess.env->Dict.copy
  [
    ("REVENTLESS_DOMAIN_PORT", port->Int.toString),
    ("REVENTLESS_PLATFORM_PORT", (port + 1)->Int.toString),
    ("REVENTLESS_DOMAIN_MCP_PORT", (port + 2)->Int.toString),
    ("REVENTLESS_PLATFORM_MCP_PORT", (port + 3)->Int.toString),
    ("REVENTLESS_LOCAL_BACKEND", "memory"),
    ("REVENTLESS_ACCOUNTS_FILE", accountsFile),
  ]->Array.forEach(((k, v)) => env->Dict.set(k, v))
  env
}

let server = ref(None)
let output = ref("")
let client = ref(None)
let doors = ref([])

let rec waitFor = async (check: unit => promise<bool>, ~until: float, ~what: string) =>
  if await check() {
    ()
  } else if Date.now() > until {
    failwith(`timed out waiting for ${what}\n${output.contents}`)
  } else {
    await Seed.Client.sleep(200)
    await waitFor(check, ~until, ~what)
  }

let theClient = () => client.contents->Option.getOrThrow

let register = async (id, ~maxPowerKw) => {
  let _ = await theClient()->Seed.Client.send(
    Seed.mutation(
      "Charging_RegisterCharger",
      [("chargerId", Id(id)), ("name", String(id)), ("maxPowerKw", Float(maxPowerKw))],
    ),
  )
}

let sessions = async () =>
  (
    await theClient()->Seed.Client.queryAllNodes(
      ~field="Charging_Sessions",
      ~selection="sessionId chargerId energyWh readings powerW",
    )
  )->Array.map(row => {
    let num = key =>
      switch row->Seed.Commands.get(key) {
      | Some(Number(n)) => n
      | _ => 0.
      }
    (
      row->Seed.Commands.str("chargerId")->Option.getOr(""),
      num("readings"),
      num("energyWh"),
      num("powerW"),
    )
  })

beforeAllAsyncWithTimeout(async () => {
  NodeFs.writeFileSync(
    accountsFile,
    NodeFs.readFileSync(
      NodePath.join([
        here,
        "..",
        "..",
        "..",
        "examples",
        "online-shop-hybrid",
        "platform-local",
        "accounts.example.yaml",
      ]),
    ),
  )
  // The platform keeps the doors' secrets file only where `.reventless/` exists.
  NodeFs.mkdirSync(NodePath.join([fixtureDir, ".reventless"]), {recursive: true})
  let child = NodeChildProcess.spawn(
    "node",
    [NodePath.join([fixtureDir, "src", "Main.res.mjs"])],
    {cwd: fixtureDir, env: env(), stdio: ["ignore", "pipe", "pipe"]},
  )
  [child->NodeChildProcess.stdout, child->NodeChildProcess.stderr]->Array.forEach(s =>
    switch s->Nullable.toOption {
    | Some(s) =>
      s
      ->NodeStreams.Readable.setEncoding("utf8")
      ->NodeStreams.Readable.onDataFromString(chunk => output := output.contents ++ chunk)
      ->ignore
    | None => ()
    }
  )
  server := Some(child)
  let entry = NodePath.join([fixtureDir, ".reventless", "running", `${port->Int.toString}.json`])
  await waitFor(
    async () => NodeFs.existsSync(entry),
    ~until=Date.now() +. 90_000.,
    ~what="the fixture platform's registry entry",
  )
  let platform = switch Standin.Doors.fromRegistryEntry(~path=entry) {
  | Ok(p) => p
  | Error(why) => failwith(why)
  }
  doors := platform.doors
  let c = Seed.Client.make(
    ~config={
      endpoint: platform.endpoint,
      loginEndpoint: platform.loginEndpoint,
      username: "admin",
      password: "admin",
    },
  )
  await waitFor(async () =>
    switch await c->Seed.Client.login {
    | () => true
    | exception _ => false
    }
  , ~until=Date.now() +. 30_000., ~what="a login")
  client := Some(c)
}, 120_000)

afterAllAsyncWithTimeout(async () => {
  switch server.contents {
  | Some(child) =>
    let closed = Promise.make((resolve, _) =>
      child->NodeChildProcess.onClose((_, _) => resolve())->ignore
    )
    child->NodeChildProcess.kill("SIGTERM")->ignore
    await closed
  | None => ()
  }
  NodeFs.rmSync(scratch, {recursive: true, force: true})
}, 30_000)

describe("Standin.Runtime, against the fixture app:", () => {
  testPromiseWithTimeout(
    "chargers meter through the signed door, and one added to the view starts without a restart",
    async () => {
      await register("bay-1", ~maxPowerKw=22.)
      await register("bay-2", ~maxPowerKw=11.)
      let commands = await Seed.Commands.fetch(theClient())
      let sent = []
      // A simulated minute every 100 ms.
      let runtime = Standin.Runtime.make(
        ~client=theClient(),
        ~doors=doors.contents,
        ~commands,
        ~kinds=[ChargerStandin.kind],
        ~speed=600.,
        ~seed=42,
        ~refreshMs=200,
        ~onSent=s => sent->Array.push(s),
        (),
      )
      expect(runtime->Standin.Runtime.check(~slices=["MeterCharger"]))->toEqual(Ok())
      await waitFor(
        async () => (await theClient()->Seed.Client.countNodes(~field="Charging_Chargers")) == 2,
        ~until=Date.now() +. 10_000.,
        ~what="two chargers in the view",
      )
      await runtime->Standin.Runtime.start
      await Seed.Client.sleep(600)
      await register("bay-3", ~maxPowerKw=7.4)
      await waitFor(
        async () => (await sessions())->Array.some(((id, _, _, _)) => id == "bay-3"),
        ~until=Date.now() +. 10_000.,
        ~what="bay-3 to meter",
      )
      expect(
        await runtime->Standin.Runtime.byHand(
          ~kind="Charger",
          ~id="bay-1",
          ~message="reading",
          ~fields=Dict.fromArray([("energyWh", JSON.Encode.float(1.))]),
        ),
      )->toEqual(Ok())
      await runtime->Standin.Runtime.stop

      expect(sent->Array.length > 3)->toBe(true)
      expect(sent->Array.every(s => s.status >= 200 && s.status < 300))->toBe(true)
      let total = sent->Array.length->Int.toFloat
      await waitFor(
        async () =>
          (await sessions())->Array.reduce(0., (acc, (_, readings, _, _)) => acc +. readings) ==
            total,
        ~until=Date.now() +. 10_000.,
        ~what="every reading in the view",
      )
      let rows = await sessions()
      expect(rows->Array.map(((id, _, _, _)) => id)->Array.toSorted(String.compare))->toEqual([
        "bay-1",
        "bay-2",
        "bay-3",
      ])
      // A minute's energy at the twin's power, for every timed reading.
      rows->Array.forEach(((id, readings, energyWh, powerW)) => {
        let timed = id == "bay-1" ? readings -. 1. : readings
        let expected = timed *. powerW /. 60. +. (id == "bay-1" ? 1. : 0.)
        expect(Math.abs(energyWh -. expected) < 0.01)->toBe(true)
      })
    },
    60_000,
  )
})

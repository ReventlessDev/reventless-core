open JestGlobals
open ReventlessSeed

// The player against the example platform, started here as a child process: a
// paced run takes the time its pace implies and ends where the same run without
// one ends, and a stopped run stops after a whole repetition.
//
// Two in-memory platforms on spare ports, both seeded with the sample set; the
// accounts are a copy of the package's template, so no setup step is needed.

let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let platformDir = NodePath.join([here, "..", "..", "platform-local"])
let main = NodePath.join([platformDir, "src", "Main.res.mjs"])
let seedScript = NodePath.join([platformDir, "src", "SeedLocal.res.mjs"])

let scratch = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "seed-player-"]))
let accountsFile = NodePath.join([scratch, "accounts.yaml"])

let envWith = (vars: array<(string, string)>): dict<string> => {
  let env = NodeProcess.env->Dict.copy
  env
  ->Dict.keysToArray
  ->Array.forEach(k => k->String.startsWith("SEED_") ? env->Dict.delete(k) : ())
  vars->Array.forEach(((k, v)) => env->Dict.set(k, v))
  env
}

type running = {
  child: NodeChildProcess.childProcess,
  output: ref<string>,
  closed: promise<Nullable.t<int>>,
}

let start = (script: string, ~vars): running => {
  let child = NodeChildProcess.spawn(
    "node",
    [script],
    {cwd: platformDir, env: envWith(vars), stdio: ["ignore", "pipe", "pipe"]},
  )
  let output = ref("")
  let collect = stream =>
    switch stream->Nullable.toOption {
    | Some(s) =>
      s
      ->NodeStreams.Readable.setEncoding("utf8")
      ->NodeStreams.Readable.onDataFromString(chunk => output := output.contents ++ chunk)
      ->ignore
    | None => ()
    }
  collect(child->NodeChildProcess.stdout)
  collect(child->NodeChildProcess.stderr)
  let closed = Promise.make((resolve, _) =>
    child->NodeChildProcess.onClose((code, _signal) => resolve(code))->ignore
  )
  {child, output, closed}
}

let rec waitFor = async (check: unit => promise<bool>, ~until: float, ~what: string) =>
  if await check() {
    ()
  } else if Date.now() > until {
    failwith(`timed out waiting for ${what}`)
  } else {
    await Seed.Client.sleep(250)
    await waitFor(check, ~until, ~what)
  }

type platform = {port: int, server: running, client: Seed.Client.t}

let endpoint = port => `http://localhost:${port->Int.toString}/graphql`

let boot = async (~port): platform => {
  let server = start(
    main,
    ~vars=[
      ("REVENTLESS_DOMAIN_PORT", port->Int.toString),
      ("REVENTLESS_PLATFORM_PORT", (port + 1)->Int.toString),
      ("REVENTLESS_DOMAIN_MCP_PORT", (port + 2)->Int.toString),
      ("REVENTLESS_PLATFORM_MCP_PORT", (port + 3)->Int.toString),
      ("REVENTLESS_LOCAL_BACKEND", "memory"),
      ("REVENTLESS_ACCOUNTS_FILE", accountsFile),
    ],
  )
  let client = Seed.Client.make(
    ~config={
      endpoint: endpoint(port),
      loginEndpoint: `http://localhost:${port->Int.toString}/__inmemory/login`,
      username: "admin",
      password: "admin",
    },
  )
  await waitFor(async () =>
    server.child->NodeChildProcess.exitCode->Nullable.isNullable &&
      switch await client->Seed.Client.login {
      | () => true
      | exception _ => false
      }
  , ~until=Date.now() +. 90_000., ~what=`the platform on ${port->Int.toString}\n${server.output.contents}`)
  {port, server, client}
}

/** Runs the seed against `p` to the end; its output, exit code and duration. */
let seed = async (p: platform, ~vars) => {
  let began = Date.now()
  let run = start(
    seedScript,
    ~vars=Array.concat(
      [
        ("REVENTLESS_GRAPHQL_ENDPOINT", endpoint(p.port)),
        ("REVENTLESS_ACCOUNTS_FILE", accountsFile),
        ("REVENTLESS_DEMO_USER", "admin"),
        ("REVENTLESS_DEMO_PASSWORD", "admin"),
        ("SEED_ROLE", "full"),
        ("SEED_SKIP_UPLOADS", "1"),
      ],
      vars,
    ),
  )
  let code = await run.closed
  (run.output.contents, code->Nullable.toOption, Date.now() -. began)
}

let commandsPlayed = (output: string): int =>
  switch output->String.match(/Played \d+ repetition\(s\), (\d+) commands/) {
  | Some([_, Some(n)]) => Int.fromString(n)->Option.getOr(0)
  | _ => failwith(`no "Played" line in:\n${output}`)
  }

/** What the views hold, without the times and message ids each run records. */
let state = async (client: Seed.Client.t) => {
  let read = async (field, selection, ~args="") =>
    (await client->Seed.Client.queryAllNodes(~field, ~selection, ~args))
    ->Array.map(row => JSON.stringify(row))
    ->Array.toSorted(String.compare)
  let retired = "includeRetired: true"
  [
    await read(
      "Catalog_Products",
      "id name description categoryId shelfStatus price { amount currency }",
      ~args=retired,
    ),
    await read("Catalog_Categories", "id name shelfStatus"),
    await read("Ordering_Customers", "id email address accountStatus orderCount", ~args=retired),
    await read(
      "Ordering_Orders",
      "id customerId lifecycle shippingMethod itemCount productIds total { amount currency }",
    ),
  ]
}

let port = 47000 + Math.Int.random(0, 400) * 10
let paced = ref(None)
let unpaced = ref(None)
let platform = r =>
  switch r.contents {
  | Some(p) => p
  | None => failwith("the platform did not start")
  }

beforeAllAsyncWithTimeout(async () => {
  NodeFs.writeFileSync(
    accountsFile,
    NodeFs.readFileSync(NodePath.join([platformDir, "accounts.example.yaml"])),
  )
  let (a, b) = (boot(~port), boot(~port=port + 5))
  let (a, b) = (await a, await b)
  paced := Some(a)
  unpaced := Some(b)
  let seeded = await Promise.all([a, b]->Array.map(p => seed(p, ~vars=[("SEED_SET", "sample")])))
  seeded->Array.forEach(((output, code, _)) =>
    if code != Some(0) {
      failwith(`the sample seed failed:\n${output}`)
    }
  )
}, 180_000)

afterAllAsyncWithTimeout(async () => {
  let stopping = [paced, unpaced]->Array.filterMap(r =>
    r.contents->Option.map(
      p => {
        p.server.child->NodeChildProcess.kill("SIGTERM")->ignore
        p.server.closed
      },
    )
  )
  let _ = await Promise.all(stopping)
  NodeFs.rmSync(scratch, {recursive: true, force: true})
}, 30_000)

describe("the seed player, against the example platform:", () => {
  let followUp = [("SEED_SET", "next"), ("SEED_RUN_DATE", "2026-01-05"), ("SEED_REPEAT", "2")]

  testPromiseWithTimeout(
    "a paced run takes the time its pace implies, and ends where the same run without one ends",
    async () => {
      let gapMs = 100
      let (pacedOut, pacedCode, pacedMs) = await seed(
        platform(paced),
        ~vars=followUp->Array.concat([("SEED_PACE", `${gapMs->Int.toString}ms`)]),
      )
      let (plainOut, plainCode, plainMs) = await seed(platform(unpaced), ~vars=followUp)
      expect((pacedCode, plainCode))->toEqual((Some(0), Some(0)))
      let sent = commandsPlayed(pacedOut)
      expect(sent)->toBe(commandsPlayed(plainOut))
      let gaps = Int.toFloat((sent - 1) * gapMs)
      expect(pacedMs >= gaps)->toBe(true)
      expect(pacedMs -. plainMs < gaps +. 5000.)->toBe(true)
      let pacedState = await state(platform(paced).client)
      expect(pacedState->Array.every(rows => rows->Array.length > 0))->toBe(true)
      expect(pacedState)->toEqual(await state(platform(unpaced).client))
    },
    120_000,
  )

  testPromiseWithTimeout(
    "one signal lets the repetition in progress finish; a second stops at once",
    async () => {
      let p = platform(paced)
      let vars = [
        ("REVENTLESS_GRAPHQL_ENDPOINT", endpoint(p.port)),
        ("REVENTLESS_ACCOUNTS_FILE", accountsFile),
        ("REVENTLESS_DEMO_USER", "admin"),
        ("REVENTLESS_DEMO_PASSWORD", "admin"),
        ("SEED_ROLE", "full"),
        ("SEED_SKIP_UPLOADS", "1"),
        ("SEED_SET", "next"),
        ("SEED_REPEAT", "forever"),
        ("SEED_PACE", "150ms"),
      ]
      let runUntil = async (~runDate, ~signals) => {
        let run = start(seedScript, ~vars=vars->Array.concat([("SEED_RUN_DATE", runDate)]))
        await waitFor(
          async () => run.output.contents->String.includes("Repetition 2"),
          ~until=Date.now() +. 60_000.,
          ~what=`the second repetition\n${run.output.contents}`,
        )
        for _ in 1 to signals {
          run.child->NodeChildProcess.kill("SIGINT")->ignore
          await Seed.Client.sleep(200)
        }
        let code = await run.closed
        (run.output.contents, code->Nullable.toOption)
      }

      let (output, code) = await runUntil(~runDate="2026-01-06", ~signals=1)
      expect(code)->toEqual(Some(0))
      expect(output->String.includes("Played 2 repetition(s)"))->toBe(true)
      expect(output->String.includes("stopped on request"))->toBe(true)
      // The second repetition's own growth check ran, so its orders are all there. Counted by
      // its own shape: each owner's read of the view is reported on the same line start.
      expect(
        output->String.match(/Ordering_Orders: \d+ → \d+ ✓/g)->Option.mapOr(0, Array.length),
      )->toBe(2)

      let (output, code) = await runUntil(~runDate="2026-01-07", ~signals=2)
      expect(code)->toEqual(Some(130))
      expect(output->String.includes("repetition 2 was cut short"))->toBe(true)
    },
    120_000,
  )
})

// A play file that says what each step expects, played into the running shop: it plays to
// the end and says what came of each step, and the same file with one wrong expectation
// stops at that step and says what came instead.
describe("a play file that expects, against the example platform:", () => {
  let file = NodePath.join([here, "..", "play", "order-placed-once.yaml"])
  let field = (j: JSON.t, k) =>
    switch j {
    | Object(d) => d->Dict.get(k)
    | _ => None
    }
  let stepNames = r =>
    switch field(r, "steps") {
    | Some(Array(steps)) => steps->Array.filterMap(s => field(s, "step"))
    | _ => []
    }

  testPromiseWithTimeout(
    "plays every step as it expects, and says so in its result",
    async () => {
      let result = NodePath.join([scratch, "once.json"])
      let (output, code, _) = await seed(
        platform(unpaced),
        ~vars=[("SEED_FILE", file), ("SEED_RESULT", result), ("SEED_RUN_TAG", "once-a")],
      )
      expect((
        code,
        output->String.includes("note:"),
        output->String.includes("every step went as it expects (5 steps)"),
      ))->toEqual((Some(0), false, true))
      let r = JSON.parseOrThrow(NodeFs.readFileSync(result))
      expect((field(r, "finished"), field(r, "purpose"), stepNames(r)))->toEqual((
        Some(JSON.Boolean(true)),
        Some(JSON.String("local")),
        ["step 1", "step 3", "register", "order", "order-again"]->Array.map(s => JSON.String(s)),
      ))
    },
    120_000,
  )

  testPromiseWithTimeout(
    "stops at the step that went otherwise, and says what came",
    async () => {
      let wrong = NodePath.join([scratch, "once-wrong.yaml"])
      let result = NodePath.join([scratch, "once-wrong.json"])
      NodeFs.writeFileSync(
        wrong,
        NodeFs.readFileSync(file)->String.replace(
          "expect: {refused: OrderAlreadyPlaced}",
          "expect: accepted",
        ),
      )
      let (output, code, _) = await seed(
        platform(unpaced),
        ~vars=[("SEED_FILE", wrong), ("SEED_RESULT", result), ("SEED_RUN_TAG", "once-b")],
      )
      let r = JSON.parseOrThrow(NodeFs.readFileSync(result))
      expect((
        code,
        output->String.includes(
          "order-again: Ordering_PlaceOrder was expected to be accepted, and was refused with OrderAlreadyPlaced",
        ),
        field(r, "finished"),
        stepNames(r)->Array.length,
      ))->toEqual((Some(1), true, Some(JSON.Boolean(false)), 5))
    },
    120_000,
  )
})

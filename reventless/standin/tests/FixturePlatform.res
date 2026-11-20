// Starts the fixture app's local platform as a child process, on spare ports,
// with a copy of the accounts template and a pinned door secret, so platforms
// started at once in this directory never write different secrets.

open ReventlessSeed

let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let dir = NodePath.join([here, "..", "fixture"])
let template = NodePath.join([
  here,
  "..",
  "..",
  "..",
  "examples",
  "online-shop-hybrid",
  "platform-local",
  "accounts.example.yaml",
])

type t = {
  port: int,
  child: NodeChildProcess.childProcess,
  output: ref<string>,
  entry: string,
  scratch: string,
}

let rec waitFor = async (check: unit => promise<bool>, ~until: float, ~what: string) =>
  if await check() {
    ()
  } else if Date.now() > until {
    failwith(`timed out waiting for ${what}`)
  } else {
    await Seed.Client.sleep(200)
    await waitFor(check, ~until, ~what)
  }

let start = async (~port: int, ~vars: array<(string, string)>=[]): t => {
  let scratch = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "standin-"]))
  let accounts = NodePath.join([scratch, "accounts.yaml"])
  NodeFs.writeFileSync(accounts, NodeFs.readFileSync(template))
  // The platform keeps the doors' secrets file only where `.reventless/` exists.
  NodeFs.mkdirSync(NodePath.join([dir, ".reventless"]), {recursive: true})
  let env = NodeProcess.env->Dict.copy
  [
    ("REVENTLESS_DOMAIN_PORT", port->Int.toString),
    ("REVENTLESS_PLATFORM_PORT", (port + 1)->Int.toString),
    ("REVENTLESS_DOMAIN_MCP_PORT", (port + 2)->Int.toString),
    ("REVENTLESS_PLATFORM_MCP_PORT", (port + 3)->Int.toString),
    ("REVENTLESS_LOCAL_BACKEND", "memory"),
    ("REVENTLESS_ACCOUNTS_FILE", accounts),
    ("REVENTLESS_WEBHOOK_SECRET_CHARGERS", "fixture-chargers-secret"),
  ]
  ->Array.concat(vars)
  ->Array.forEach(((k, v)) => env->Dict.set(k, v))
  let child = NodeChildProcess.spawn(
    "node",
    [NodePath.join([dir, "src", "Main.res.mjs"])],
    {cwd: dir, env, stdio: ["ignore", "pipe", "pipe"]},
  )
  let output = ref("")
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
  let entry = NodePath.join([dir, ".reventless", "running", `${port->Int.toString}.json`])
  await waitFor(
    async () => NodeFs.existsSync(entry),
    ~until=Date.now() +. 90_000.,
    ~what=`the fixture platform on ${port->Int.toString}`,
  )
  {port, child, output, entry, scratch}
}

let base = (p: t) => `http://localhost:${p.port->Int.toString}`

/** A client logged in as the template's administrator. */
let admin = async (p: t): Seed.Client.t => {
  let client = Seed.Client.make(
    ~config={
      endpoint: `${base(p)}/graphql`,
      loginEndpoint: `${base(p)}/__inmemory/login`,
      username: "admin",
      password: "admin",
    },
  )
  await waitFor(async () =>
    switch await client->Seed.Client.login {
    | () => true
    | exception _ => false
    }
  , ~until=Date.now() +. 30_000., ~what="a login")
  client
}

let stop = async (p: t) => {
  let closed = Promise.make((resolve, _) =>
    p.child->NodeChildProcess.onClose((_, _) => resolve())->ignore
  )
  p.child->NodeChildProcess.kill("SIGTERM")->ignore
  await closed
  NodeFs.rmSync(p.scratch, {recursive: true, force: true})
}

let registerCharger = async (client, id, ~maxPowerKw) => {
  let _ = await client->Seed.Client.send(
    Seed.mutation(
      "Charging_RegisterCharger",
      [("chargerId", Id(id)), ("name", String(id)), ("maxPowerKw", Float(maxPowerKw))],
    ),
  )
}

/** Answers a request to the platform with its status and JSON. */
let request = async (p: t, ~method="GET", ~path, ~body="") => {
  let url = `${base(p)}${path}`
  let res =
    method == "GET"
      ? await Seed.Client.fetchGet(url)
      : await Seed.Client.fetch(
          url,
          {method, headers: Dict.fromArray([("content-type", "application/json")]), body},
        )
  let text = await res->Seed.Client.responseText
  (
    res->Seed.Client.responseStatus,
    try JSON.parseOrThrow(text) catch {
    | _ => JSON.Encode.string(text)
    },
  )
}

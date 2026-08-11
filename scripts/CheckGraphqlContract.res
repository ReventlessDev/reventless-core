/**
Golden SDL snapshots of the two GraphQL contracts a UI shell talks to.

The shell compiles its queries against a committed SDL snapshot on its own side,
so a change to either contract here is invisible to it until someone refreshes
that snapshot by hand. Nothing forces the refresh, which makes a wire-shape
change look green in both repos and fail only at runtime, against a real backend.

This boots the hybrid example's local platform and introspects both servers, so
a change that alters either contract shows up as a diff in a tracked file in the
PR that causes it. Two separate goldens, because they drift for different
reasons and call for different follow-ups:

- `platform-api.graphql` — the admin API (`Platform_*` only, plugin-independent).
  The shell's Relay queries compile against this one, so a diff here means the
  shell's snapshot needs regenerating or its queries no longer compile.

- `domain-api.graphql` — the per-plugin API generated from the hybrid example's
  specs. No client compiles against it (the shell builds these queries at runtime
  from the component-definitions manifest), so a diff here is a report on GraphQL
  codegen: a changed queryable field, command mutation, filter input, or
  connection shape.

Usage:

```
pnpm run check:graphql           # fail on drift
pnpm run check:graphql:update    # rewrite the goldens
```
*/

// ── Where things live ───────────────────────────────────────────────────────

// Both entry points run from the repo root, which is where pnpm starts a root
// script.
let repoRoot = NodeProcess.cwd()
let platformDir = NodePath.join([repoRoot, "examples", "online-shop-hybrid", "platform-local"])
let goldenDir = NodePath.join([repoRoot, "examples", "online-shop-hybrid", "schema"])

// Off the platform's defaults (4000/4001/3001/3002) so a run never fights a dev
// server the developer already has going.
let domainPort = "4700"
let platformPort = "4701"
let domainMcpPort = "3700"
let platformMcpPort = "3701"

type contract = {file: string, url: string}

let contracts = [
  {file: "platform-api.graphql", url: `http://localhost:${platformPort}/graphql`},
  {file: "domain-api.graphql", url: `http://localhost:${domainPort}/graphql`},
]

let bootTimeoutMs = 120_000.0
let update = NodeProcess.argv->Array.includes("--update")

// ── Introspection ───────────────────────────────────────────────────────────

let introspect = async (url: string): result<string, string> => {
  let payload =
    Dict.fromArray([("query", JSON.Encode.string(GraphqlYoga.getIntrospectionQuery()))])
    ->JSON.Encode.object
    ->JSON.stringify

  try {
    let res = await Web.Fetch.fetch(
      url,
      {
        method: "POST",
        headers: Dict.fromArray([("Content-Type", "application/json")]),
        body: Web.Fetch.Body.string(payload),
      },
    )
    if !(res->Web.Fetch.ok) {
      Error(`${url} returned HTTP ${res->Web.Fetch.status->Int.toString}`)
    } else {
      let body = await res->Web.Fetch.json
      let field = key => body->JSON.Decode.object->Option.flatMap(o => o->Dict.get(key))
      switch (field("errors"), field("data")) {
      | (Some(errors), _) => Error(`${url} returned errors: ${errors->JSON.stringify}`)
      | (None, None) => Error(`${url} returned no data`)
      | (None, Some(data)) =>
        // Sorted so a golden is a function of the schema alone — the platform
        // builds its type map from dicts, and unsorted output would diff on
        // iteration order rather than on a real contract change.
        Ok(
          data
          ->GraphqlYoga.buildClientSchema
          ->GraphqlYoga.lexicographicSortSchema
          ->GraphqlYoga.printSchema,
        )
      }
    }
  } catch {
  | exn =>
    Error(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("request failed"))
  }
}

/** Both contracts or the first failure — a partial result is never useful here,
    since a golden can only be compared against a complete schema. */
let introspectAll = async (): result<array<string>, string> => {
  let collected = []
  let failure = ref(None)
  for i in 0 to Array.length(contracts) - 1 {
    switch (failure.contents, contracts->Array.get(i)) {
    | (Some(_), _) | (_, None) => ()
    | (None, Some(contract)) =>
      switch await introspect(contract.url) {
      | Ok(sdl) => collected->Array.push(sdl)
      | Error(msg) => failure := Some(msg)
      }
    }
  }
  switch failure.contents {
  | Some(msg) => Error(msg)
  | None => Ok(collected)
  }
}

/** Poll until both servers answer. Checks `exitCode` first so a platform that
    died during boot reports that, rather than timing out a minute later with a
    connection-refused message that says nothing about why. */
let rec waitForContracts = async (child, ~deadline: float): result<array<string>, string> =>
  switch child->NodeChildProcess.exitCode->Nullable.toOption {
  | Some(code) =>
    Error(`the platform exited with code ${code->Int.toString} before serving both contracts`)
  | None =>
    switch await introspectAll() {
    | Ok(sdl) => Ok(sdl)
    | Error(msg) =>
      if Date.now() > deadline {
        Error(`the platform did not serve both contracts in time: ${msg}`)
      } else {
        await Web.Timers.delay(1000)
        await waitForContracts(child, ~deadline)
      }
    }
  }

// ── Comparison ──────────────────────────────────────────────────────────────

/** The first line where the two disagree. A full diff of a 1800-line schema
    buries the answer; the first divergence usually is the answer. */
let firstDiff = (~golden: string, ~actual: string): string => {
  let goldenLines = golden->String.split("\n")
  let actualLines = actual->String.split("\n")
  let lineCount = Math.Int.max(Array.length(goldenLines), Array.length(actualLines))
  let show = line => line->Option.getOr("(end of file)")
  let rec find = i =>
    if i >= lineCount {
      "(the files differ only in trailing content)"
    } else if goldenLines->Array.get(i) != actualLines->Array.get(i) {
      `line ${(i + 1)->Int.toString}:\n` ++
      `  golden: ${show(goldenLines->Array.get(i))}\n` ++
      `  actual: ${show(actualLines->Array.get(i))}`
    } else {
      find(i + 1)
    }
  find(0)
}

// ── Entry point ─────────────────────────────────────────────────────────────

let main = async () => {
  // The platform's own `serve` script silences this one, and it is the same
  // process being started here — without it every run prints Node's SQLite
  // experimental warning through the inherited stderr. Appended rather than
  // set, so a NODE_OPTIONS the caller already relies on survives.
  let nodeOptions = switch NodeProcess.env->Dict.get("NODE_OPTIONS") {
  | Some(existing) => `${existing} --disable-warning=ExperimentalWarning`
  | None => "--disable-warning=ExperimentalWarning"
  }

  let env =
    NodeProcess.env
    ->Dict.toArray
    ->Array.concat([
      ("NODE_OPTIONS", nodeOptions),
      ("REVENTLESS_LOCAL_BACKEND", "memory"),
      ("REVENTLESS_DOMAIN_PORT", domainPort),
      ("REVENTLESS_PLATFORM_PORT", platformPort),
      ("REVENTLESS_DOMAIN_MCP_PORT", domainMcpPort),
      ("REVENTLESS_PLATFORM_MCP_PORT", platformMcpPort),
    ])
    ->Dict.fromArray

  let child = NodeChildProcess.spawn(
    "node",
    ["src/Main.res.mjs"],
    {
      cwd: platformDir,
      env,
      // stdout discarded, stderr through: a clean run stays quiet, and a boot
      // failure still says why on its way past.
      stdio: ["ignore", "ignore", "inherit"],
    },
  )

  let outcome = await waitForContracts(child, ~deadline=Date.now() +. bootTimeoutMs)
  let _ = child->NodeChildProcess.kill("SIGTERM")

  switch outcome {
  | Error(msg) =>
    Console.error(msg)
    NodeProcess.exit(1)
  | Ok(sdl) =>
    if !(goldenDir->NodeFs.existsSync) {
      NodeFs.mkdirSync(goldenDir, {recursive: true})
    }

    let drifted = []
    contracts->Array.forEachWithIndex((contract, i) => {
      let path = NodePath.join([goldenDir, contract.file])
      let actual = (sdl->Array.getUnsafe(i))->String.trim ++ "\n"
      let existed = path->NodeFs.existsSync

      if update || !existed {
        NodeFs.writeFileSync(path, actual)
        Console.log(`${existed ? "updated" : "wrote"} ${contract.file}`)
      } else {
        let golden = path->NodeFs.readFileSync
        if golden == actual {
          Console.log(`ok ${contract.file}`)
        } else {
          drifted->Array.push(contract.file)
          Console.error(`\ndrift in ${contract.file}\n${firstDiff(~golden, ~actual)}`)
        }
      }
    })

    if Array.length(drifted) > 0 {
      Console.error(
        `\n${drifted->Array.length->Int.toString} GraphQL contract(s) changed. ` ++
        `If the change is intended, run\n` ++
        `  pnpm run check:graphql:update\n` ++
        `and commit the goldens. A platform-api.graphql diff also means the UI\n` ++
        `shell's own SDL snapshot has to be regenerated against this platform.`,
      )
      NodeProcess.exit(1)
    }
  }
}

let _ = main()

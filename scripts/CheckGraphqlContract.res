/**
Golden SDL snapshots of the two GraphQL contracts a UI shell talks to.

This boots the hybrid example's local platform and introspects both servers, so
a change that alters either contract shows up as a diff in a tracked file in the
PR that causes it. Two separate goldens, owned by different things and read for
different reasons:

- `platform-api.graphql` — the admin API (`Platform_*` only, plugin-independent).
  A shell's Relay queries compile against this one. It is framework-owned rather
  than example-owned — the example is just the cheapest way to get a platform
  serving — so it is written into the spec package and published from there, and
  a shell takes it as a dependency instead of keeping a copy that nothing keeps
  fresh. Lerna versions this repo off conventional commits, so the spec version a
  shell pins is the contract version it compiles against.

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

// The two goldens live apart because they are owned by different things. The
// platform admin API is framework-owned — every type in it is `Platform_*` or
// framework-level, nothing from this example's plugins — so it ships from the
// spec package, and a shell depends on it rather than keeping a copy. The
// domain API is generated from this example's own plugin specs, so its golden
// stays with the example that produces it.
let platformGoldenDir = NodePath.join([repoRoot, "reventless", "spec", "schema"])
let domainGoldenDir = NodePath.join([repoRoot, "examples", "online-shop-hybrid", "schema"])

// Off the platform's defaults (4000/4001/3001/3002) so a run never fights a dev
// server the developer already has going.
let domainPort = "4700"
let platformPort = "4701"
let domainMcpPort = "3700"
let platformMcpPort = "3701"

type contract = {dir: string, file: string, url: string}

let contracts = [
  {
    dir: platformGoldenDir,
    file: "platform-api.graphql",
    url: `http://localhost:${platformPort}/graphql`,
  },
  {dir: domainGoldenDir, file: "domain-api.graphql", url: `http://localhost:${domainPort}/graphql`},
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

let reportLimit = 25

/** The declaration a line sits inside, for lines that open one. A field name on
    its own is ambiguous across a 42-type schema — the same field can be added to
    several types in one change, and three bare `ownerField: String` lines say
    nothing about which types grew one. */
let declarationName = (line: string): option<string> =>
  ["type ", "input ", "enum ", "union ", "interface ", "scalar "]
  ->Array.find(keyword => line->String.startsWith(keyword))
  ->Option.flatMap(keyword =>
    line
    ->String.slice(~start=String.length(keyword), ~end=String.length(line))
    ->String.split(" ")
    ->Array.get(0)
  )

/** Closing braces and blank lines are punctuation: they differ in step with the
    declarations around them and carry nothing on their own. */
let isPunctuation = (line: string): bool =>
  switch line->String.trim {
  | "" | "}" => true
  | _ => false
  }

/**
Every comparable line of a schema, qualified by the declaration it sits in.

`Type.field: String!` rather than `field: String!`, and the qualification is what
makes the comparison correct rather than only the report readable. A bare field
line is not unique across a 42-type schema — `address: String!` belongs to two
types here — so a multiset keyed on the raw text lets an unrelated type's
identical line answer for the one that actually changed. The count came out
right and the name came out wrong: adding `address` to `NotificationDelivery`
was reported against `SendNotificationTodoItem`, sending a reader to a file
nothing had touched.

Punctuation is dropped rather than carried, since it is never reported: a `}`
qualified by its owner would only add keys that cannot appear in a diff.
*/
let comparableLines = (sdl: string): array<string> => {
  let lines = []
  let declaration = ref(None)
  sdl
  ->String.split("\n")
  ->Array.forEach(line => {
    switch declarationName(line) {
    | Some(_) as name => declaration := name
    | None => ()
    }
    if !isPunctuation(line) {
      let body = line->String.trim
      lines->Array.push(
        switch (declarationName(line), declaration.contents) {
        | (Some(_), _) => body
        | (None, Some(owner)) => `${owner}.${body}`
        | (None, None) => body
        },
      )
    }
  })
  lines
}

/** The lines one side has that the other does not, each named by the declaration
    it belongs to.

    Compared as multisets rather than position by position. Both files are
    `lexicographicSortSchema`-sorted, so this is a true diff: a rename is one
    removal plus one addition, and — the reason for the change — an insertion
    stays one line instead of shifting every line after it into disagreement. A
    positional walk reported the first *shifted* line as the mismatch, so adding
    `ownerField` to two types printed `golden: references: …` against
    `actual: ownerField: String`: a replacement that never happened. */
let exclusiveTo = (~from: string, ~other: string): array<string> => {
  let remaining = Dict.make()
  comparableLines(other)->Array.forEach(key =>
    remaining->Dict.set(key, remaining->Dict.get(key)->Option.getOr(0) + 1)
  )

  let found = []
  comparableLines(from)->Array.forEach(key =>
    switch remaining->Dict.get(key) {
    // Present on both sides — spend one of the other side's copies, so a line
    // that appears twice here and once there still reports one occurrence.
    | Some(count) if count > 0 => remaining->Dict.set(key, count - 1)
    | _ => found->Array.push(key)
    }
  )
  found
}

let describe = (~marker: string, lines: array<string>): string =>
  lines
  ->Array.slice(~start=0, ~end=reportLimit)
  ->Array.map(line => `  ${marker} ${line}`)
  ->Array.join("\n")
  ->(shown =>
    Array.length(lines) > reportLimit
      ? `${shown}\n  … and ${(Array.length(lines) - reportLimit)->Int.toString} more`
      : shown)

let driftReport = (~golden: string, ~actual: string): string => {
  let added = exclusiveTo(~from=actual, ~other=golden)
  let removed = exclusiveTo(~from=golden, ~other=actual)
  switch (added, removed) {
  | ([], []) => "  (the files differ only in blank lines or braces)"
  | ([], removed) => describe(~marker="-", removed)
  | (added, []) => describe(~marker="+", added)
  | (added, removed) => `${describe(~marker="-", removed)}\n${describe(~marker="+", added)}`
  }
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
    let drifted = []
    contracts->Array.forEachWithIndex((contract, i) => {
      if !(contract.dir->NodeFs.existsSync) {
        NodeFs.mkdirSync(contract.dir, {recursive: true})
      }
      let path = NodePath.join([contract.dir, contract.file])
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
          Console.error(`\ndrift in ${contract.file}\n${driftReport(~golden, ~actual)}`)
        }
      }
    })

    if Array.length(drifted) > 0 {
      Console.error(
        `\n${drifted->Array.length->Int.toString} GraphQL contract(s) changed. ` ++
        `If the change is intended, run\n` ++
        `  pnpm run check:graphql:update\n` ++
        `and commit the goldens alongside the change that moved them.`,
      )
      NodeProcess.exit(1)
    }
  }
}

let _ = main()

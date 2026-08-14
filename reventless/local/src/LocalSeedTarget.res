// Which running platform `seed` and `seed:reset` are aimed at.
//
// The two are supposed to be inverses, and they were resolving their target by
// different means: `seed` addressed an ENDPOINT (`REVENTLESS_GRAPHQL_ENDPOINT`,
// defaulting to :4000), `seed:reset` opened a FILE (`REVENTLESS_LOCAL_BACKEND`,
// defaulting to ./.reventless/local.db). With two platforms up — a hand-started
// one and the VS Code runner's child — they answered about different databases
// and both reported success: "Nothing to do." followed by "the target store is
// not empty".
//
// One selector for both fixes that by construction. The endpoint identifies the
// platform (parallel platforms already differ by port); the platform names its
// store (`LocalPlatformRegistry`). Nothing is inferred from the tool's own
// environment except the deliberate override.

open ReventlessSeed

type origin =
  | // A platform that is up and said so.
  Running(LocalPlatformRegistry.entry)
  | // `REVENTLESS_GRAPHQL_ENDPOINT` was set: the operator named a target, so no
  // discovery runs and no prompt appears.
  EnvOverride
  | // Nothing is registered here. The endpoint default is still tried, so a
  // platform from a build without the registry keeps working.
  NoneRunning

type t = {endpoint: string, loginEndpoint: string, origin: origin}

let defaultEndpoint = "http://localhost:4000/graphql"

// The login route sits on the same server as the GraphQL one, so deriving it
// from the endpoint is what keeps a `REVENTLESS_GRAPHQL_ENDPOINT` pointing at
// :4010 from logging in against :4000 — a mismatch that used to require setting
// both variables to avoid, and silently seeded through the wrong door when only
// one was set. An explicit `REVENTLESS_LOGIN_ENDPOINT` still wins.
let loginFor = (endpoint: string): string =>
  switch endpoint->String.indexOf("://") {
  | -1 => endpoint
  | i =>
    let afterScheme = i + 3
    switch endpoint->String.indexOfFrom("/", afterScheme) {
    | -1 => endpoint
    | slash => endpoint->String.slice(~start=0, ~end=slash)
    } ++ "/__inmemory/login"
  }

let relativeIfInside = (path: string): string => {
  let cwd = NodeProcess.cwd()
  path->String.startsWith(cwd ++ NodePath.sep)
    ? path->String.slice(~start=(cwd ++ NodePath.sep)->String.length)
    : path
}

let storeLabel = (store: LocalPlatformRegistry.store): string =>
  switch (store.kind, store.path) {
  | ("sqlite", Some(path)) => `sqlite ${relativeIfInside(path)}`
  | (kind, _) => kind
  }

// The scope is dropped from the app name for the menu only — `@scope/app-local`
// is the same width in every row and carries none of the distinction.
let shortAppName = (app: string): string =>
  switch app->String.indexOf("/") {
  | -1 => app
  | i => app->String.slice(~start=i + 1)
  }

let entryLabel = (e: LocalPlatformRegistry.entry): string =>
  `:${e.port->Int.toString}  ${e.app->shortAppName}  ${e.store->storeLabel}`

/** Resolves the platform this run acts on.

    Precedence — explicit target, then the running platforms, then the historical
    default:

    1. `REVENTLESS_GRAPHQL_ENDPOINT` — named a target, so it is used verbatim.
    2. one platform registered — it, with no prompt.
    3. several — a menu, preselectable with `SEED_PLATFORM` (port or menu index)
       so a run without a TTY is not stuck.
    4. none — the :4000 default, so this stays backwards compatible with a
       platform started from a build that does not register itself. */
let select = async (): t => {
  switch Seed.Prompt.envValue("REVENTLESS_GRAPHQL_ENDPOINT") {
  | Some(endpoint) => {
      endpoint,
      loginEndpoint: Seed.Prompt.envValue("REVENTLESS_LOGIN_ENDPOINT")->Option.getOr(
        endpoint->loginFor,
      ),
      origin: EnvOverride,
    }
  | None =>
    let running = LocalPlatformRegistry.list()
    // Matched on the port rather than through `select`'s own `~env`, which
    // compares against the whole rendered label — `SEED_PLATFORM=4000` is the
    // form an operator would write, and no label will ever equal it.
    let preselected =
      Seed.Prompt.envValue("SEED_PLATFORM")->Option.flatMap(v =>
        running->Array.find(e => e.port->Int.toString == v)
      )
    let chosen = switch (preselected, running) {
    | (Some(entry), _) => Some(entry)
    | (None, []) => None
    | (None, entries) =>
      Some(
        await Seed.Prompt.select(
          ~title="Platform:",
          ~options=entries->Array.map(e => (e->entryLabel, e)),
          ~env="SEED_PLATFORM",
        ),
      )
    }
    switch chosen {
    | Some(entry) => {
        endpoint: entry.endpoint,
        loginEndpoint: entry.loginEndpoint,
        origin: Running(entry),
      }
    | None => {
        endpoint: defaultEndpoint,
        loginEndpoint: defaultEndpoint->loginFor,
        origin: NoneRunning,
      }
    }
  }
}

/** Says which platform was picked, before anything is written or deleted.

    Printed even when there was no choice to make: the single-platform case is
    the one that produced a reset and a seed acting on different stores, and one
    line naming the endpoint and the store is what makes that visible. */
let announce = (t: t): unit =>
  switch t.origin {
  | Running(entry) =>
    Console.log(`→ ${entry.endpoint}  ·  ${entry.store->storeLabel}  (${entry.app->shortAppName})`)
  | EnvOverride => Console.log(`→ ${t.endpoint}  (REVENTLESS_GRAPHQL_ENDPOINT)`)
  | NoneRunning =>
    Console.log(`→ ${t.endpoint}  (no local platform registered here — trying the default)`)
  }

/** The store the selected platform opened: `Some(path)` only for one this
    machine can open by name. `None` carries the reason, already phrased for the
    operator, because "no path" has three different meanings and a tool that
    collapsed them would tell an in-memory platform to check its disk. */
let storePath = (t: t): result<string, string> =>
  switch t.origin {
  | Running({store: {kind: "sqlite", path: Some(path)}}) => Ok(path)
  | Running({store: {kind: "memory"}, endpoint}) =>
    Error(`the platform at ${endpoint} keeps its store in memory; restart it to empty it.`)
  | Running({store: {kind: "postgres"}, endpoint}) =>
    Error(
      `the platform at ${endpoint} is backed by Postgres, which keeps its event logs off this machine. Reset it against the database.`,
    )
  | Running({store: {kind}, endpoint}) =>
    Error(`the platform at ${endpoint} reports an unknown store kind "${kind}".`)
  | EnvOverride =>
    Error(
      `REVENTLESS_GRAPHQL_ENDPOINT names ${t.endpoint}, which does not say which store that platform opened. Set REVENTLESS_LOCAL_BACKEND to the store file, or unset REVENTLESS_GRAPHQL_ENDPOINT to pick a running platform.`,
    )
  | NoneRunning =>
    Error(
      "no local platform is running here. Start one, or set REVENTLESS_LOCAL_BACKEND to reset a store directly.",
    )
  }

/** A `Seed.Runner.seed`-shaped `~connect` that targets the selected platform.

    `~connect` is already a thunk, so the selection — prompt included — happens
    when seeding starts rather than at module load, and `Seed_Connect.local`
    stays untouched: it takes the endpoints, it does not go looking for them. */
let connect = (): (unit => promise<Seed.Connect.connection>) =>
  async () => {
    let target = await select()
    target->announce
    await Seed.Connect.local(~graphql=target.endpoint, ~login=target.loginEndpoint, ())()
  }

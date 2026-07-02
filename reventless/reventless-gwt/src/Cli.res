// Entry point for the `reventless-gwt` CLI. Orchestrates discovery, the
// module-level Collector, each formatter, and the watch / cancellation
// plumbing. Parses a minimal argv layer — no optparse library, no colour
// auto-detection — kept deliberately thin so the formatters own all
// presentational logic.

let toolVersion = "0.1.0"

type format = Human | Json | Tap | Junit | VsCode

type subcommand = Run | Discover | Watch | Platform

type options = {
  subcommand: subcommand,
  format: format,
  stream: bool,
  watch: bool,
  filters: array<string>,
  schemaVersion: option<string>,
  roots: array<string>,
  // `platform` only: the REVENTLESS_LOCAL_BACKEND value passed to the spawned
  // platform child ("memory" default, or "sqlite:<path>[?reset]").
  backend: string,
  // `platform` only: pin the spawned platform to the fixed default ports
  // (4000/4001/3001/3002) instead of allocating ephemeral ones. The VS Code
  // extension passes this when it is also launching the host-shell UI, whose
  // Vite proxy hardcodes localhost:4000/4001.
  uiPorts: bool,
  // `platform --list` only: enumerate the launchable platform packages (one
  // NDJSON `{name, dir}` line each) and exit, rather than spawning one. Used by
  // the VS Code extension to populate its active-app picker.
  listPlatforms: bool,
  toolVersion: string,
  // When `Some`, `runOnce` runs exactly these compiled test paths instead of
  // walking the tree. Set by the watch loop's worker passes (the parent owns
  // discovery and narrows to the affected package); `None` for the one-shot
  // `run`/`discover` commands, which discover from `roots`.
  paths: option<array<string>>,
}

@val external argv: array<string> = "process.argv"

// chokidar reports paths in the same form as its watched roots (relative when
// roots are `["."]`), while `Discovery` returns absolute paths. Normalize a
// changed path to absolute before mapping it to an owning package so the
// prefix match against the discovered set holds.
@module("node:path") external resolvePath: string => string = "resolve"

@val external now: unit => float = "performance.now"

let dateNowIso: unit => string = %raw(`() => new Date().toISOString()`)

let parseFormat = (s: string) =>
  switch s {
  | "human" => Ok(Human)
  | "json" => Ok(Json)
  | "tap" => Ok(Tap)
  | "junit" => Ok(Junit)
  | "vscode" => Ok(VsCode)
  | other => Error("Unknown --format value: " ++ other)
  }

// With no explicit path argument, scan the whole working-directory subtree.
// `Discovery.walk` already prunes `node_modules`/`lib`/`.git`/`dist`/`.history`,
// so pointing at the cwd auto-discovers every plugin's GWT tests in a
// multi-package workspace (e.g. an example root) with no roots configured.
let defaultRoots = () => ["."]

let help = () => `reventless-dev — Reventless dev CLI: GWT runner, domain graph, components, platform runner

USAGE:
  reventless-dev run [--format=<fmt>] [--filter=<id>] [--stream] [--watch] [path...]
  reventless-dev discover [--format=vscode] [path...]
  reventless-dev watch [--format=<fmt>] [--filter=<id>] [path...]
  reventless-dev platform [--format=vscode] [--backend=<b>] [--ui-ports] [path...]
  reventless-dev platform --list [path...]

FORMATS:
  human   ANSI-coloured terminal output (default)
  json    Structured JSON envelope (--stream for NDJSON)
  tap     TAP 14 with YAML diagnostics
  junit   JUnit XML (single batch)
  vscode  NDJSON event stream for the VS Code Testing API

FLAGS:
  --filter <id>         Restrict execution to tests whose id contains <id>.
                        Repeatable.
  --stream              NDJSON streaming (json/vscode)
  --watch               Re-run on file change
  --schema-version <v>  Pin a JSON schema version for stable AI prompts
  --backend <b>         platform: storage backend for the spawned local platform
                        ("memory" default, or "sqlite:<path>[?reset]")
  --ui-ports            platform: pin the platform to the fixed default ports
                        (4000/4001/3001/3002) instead of ephemeral ones, so the
                        host-shell UI's Vite proxy can reach it
  --list                platform: list launchable platform packages as NDJSON
                        ({name, dir} per line) and exit
  --help                Show this help and exit

Exit code is 1 if any test failed, 0 otherwise.
`

let parseArgv = (argv: array<string>): result<options, string> => {
  let slice = argv->Array.slice(~start=2, ~end=argv->Array.length)
  let subcommand = ref(Run)
  let format = ref(Human)
  let stream = ref(false)
  let watch = ref(false)
  let filters = ref([])
  let schemaVersion: ref<option<string>> = ref(None)
  let roots = ref([])
  let backend = ref("memory")
  let uiPorts = ref(false)
  let listPlatforms = ref(false)
  let error = ref(None)
  let showHelp = ref(false)
  let i = ref(0)
  let len = slice->Array.length
  if len > 0 {
    let first = slice->Array.getUnsafe(0)
    switch first {
    | "run" => {
        subcommand := Run
        i := 1
      }
    | "discover" => {
        subcommand := Discover
        format := VsCode
        i := 1
      }
    | "watch" => {
        subcommand := Watch
        watch := true
        i := 1
      }
    | "platform" => {
        subcommand := Platform
        i := 1
      }
    | "--help" | "-h" => showHelp := true
    | _ => ()
    }
  }
  while i.contents < len && error.contents == None && !showHelp.contents {
    let arg = slice->Array.getUnsafe(i.contents)
    if arg == "--help" || arg == "-h" {
      showHelp := true
    } else if String.startsWith(arg, "--format=") {
      let v = String.slice(arg, ~start=9, ~end=String.length(arg))
      switch parseFormat(v) {
      | Ok(f) => format := f
      | Error(e) => error := Some(e)
      }
    } else if arg == "--format" && i.contents + 1 < len {
      let v = slice->Array.getUnsafe(i.contents + 1)
      switch parseFormat(v) {
      | Ok(f) => format := f
      | Error(e) => error := Some(e)
      }
      i := i.contents + 1
    } else if String.startsWith(arg, "--filter=") {
      let v = String.slice(arg, ~start=9, ~end=String.length(arg))
      filters := Array.concat(filters.contents, [v])
    } else if arg == "--filter" && i.contents + 1 < len {
      let v = slice->Array.getUnsafe(i.contents + 1)
      filters := Array.concat(filters.contents, [v])
      i := i.contents + 1
    } else if arg == "--stream" {
      stream := true
    } else if arg == "--watch" {
      watch := true
    } else if String.startsWith(arg, "--schema-version=") {
      let v = String.slice(arg, ~start=17, ~end=String.length(arg))
      schemaVersion := Some(v)
    } else if String.startsWith(arg, "--backend=") {
      backend := String.slice(arg, ~start=10, ~end=String.length(arg))
    } else if arg == "--backend" && i.contents + 1 < len {
      backend := slice->Array.getUnsafe(i.contents + 1)
      i := i.contents + 1
    } else if arg == "--ui-ports" {
      uiPorts := true
    } else if arg == "--list" {
      listPlatforms := true
    } else if String.startsWith(arg, "--") {
      error := Some("Unknown flag: " ++ arg)
    } else {
      roots := Array.concat(roots.contents, [arg])
    }
    i := i.contents + 1
  }
  if showHelp.contents {
    Error(help())
  } else {
    switch error.contents {
    | Some(e) => Error(e ++ "\n\n" ++ help())
    | None =>
      Ok({
        subcommand: subcommand.contents,
        format: format.contents,
        stream: stream.contents,
        watch: watch.contents,
        filters: filters.contents,
        schemaVersion: schemaVersion.contents,
        roots: roots.contents->Array.length == 0 ? defaultRoots() : roots.contents,
        backend: backend.contents,
        uiPorts: uiPorts.contents,
        listPlatforms: listPlatforms.contents,
        toolVersion,
        paths: None,
      })
    }
  }
}

// Apply --filter: pass if id contains every filter substring, OR if no filters.
let passesFilter = (id: string, filters: array<string>) =>
  filters->Array.length == 0 ||
    filters->Array.some(f => id->String.includes(f))

// Extract a human-readable message from any thrown value. JS Errors carry a
// `.message`; ReScript exceptions are tagged objects (`RE_EXN_ID` + an optional
// string payload), e.g. `failwith("…")` raises `Failure("…")`. Without this the
// catch block below collapsed every ReScript exception to "unknown error",
// hiding messages like a slice's `failwith("not implemented: …")`.
let exnMessage: exn => string = %raw(`function(e) {
  if (e == null) return "unknown error"
  if (typeof e === "string") return e
  if (typeof e.message === "string" && e.message.length) return e.message
  if (typeof e.RE_EXN_ID === "string") {
    var id = e.RE_EXN_ID
    var tag = id.lastIndexOf(".") >= 0 ? id.slice(id.lastIndexOf(".") + 1) : id
    return (typeof e._1 === "string" && e._1.length) ? e._1 : tag
  }
  return "unknown error"
}`)

// Default per-test deadline (ms) when a test body doesn't set `~timeout`.
// Mirrors Jest's default so behaviour is consistent across both runners.
let defaultTimeoutMs = 5000

// Resolve to a timeout `Outcome` after `ms`. Raced against the test body so a
// hung await reports a failure instead of wedging the entire run.
type timeoutHandle
@val external setTimeout: (unit => unit, int) => timeoutHandle = "setTimeout"
@val external clearTimeout: timeoutHandle => unit = "clearTimeout"
let raceWithTimeout = (body: unit => promise<Outcome.outcome>, ms: int): promise<
  Outcome.outcome,
> => {
  let handleRef: ref<option<timeoutHandle>> = ref(None)
  let timeout = Promise.make((resolve, _reject) => {
    handleRef :=
      Some(
        setTimeout(
          () =>
            resolve(
              Outcome.fail(
                Throw({error: `timed out after ${Int.toString(ms)}ms`, stack: ""}),
              ),
            ),
          ms,
        ),
      )
  })
  Promise.race([body(), timeout])->Promise.then(o => {
    switch handleRef.contents {
    | Some(h) => clearTimeout(h)
    | None => ()
    }
    Promise.resolve(o)
  })
}

// Execute a single entry, catching exceptions and thrown values so a
// misbehaved slice doesn't abort the rest of the suite.
let runEntry = async (entry: Collector.entry): RunnerTypes.testResult => {
  let start = now()
  let status = ref(RunnerTypes.Pass)
  let mismatch: ref<option<Outcome.mismatch>> = ref(None)
  switch entry.status {
  | Collector.Skipped => status := Skip
  | _ =>
    try {
      let deadline = entry.timeout->Option.getOr(defaultTimeoutMs)
      let outcome = await raceWithTimeout(entry.body, deadline)
      switch outcome {
      | Ok() => status := Pass
      | Error(m) => {
          status := Fail
          mismatch := Some(m)
        }
      }
    } catch {
    | exn => {
        status := Fail
        let err = exnMessage(exn)
        let stack: string = %raw(`(e => (e && e.stack) || "")`)(exn)
        mismatch := Some(Outcome.Throw({error: err, stack: stack}))
      }
    }
  }
  let durationMs = now() -. start
  {
    id: entry.id,
    name: entry.name,
    describePath: entry.describePath,
    status: status.contents,
    durationMs,
    location: entry.location,
    slice: entry.slice,
    mismatch: mismatch.contents,
    skipReason: entry.status == Collector.Skipped ? Some("skipped at source") : None,
  }
}

let loadAndCollect = async (path: string): array<Collector.entry> => {
  Collector.activate()
  Collector.setCurrentFile(path)
  try {
    await Loader.loadFile(path)
  } catch {
  | exn =>
    let msg =
      exn
      ->JsExn.fromException
      ->Option.flatMap(JsExn.message)
      ->Option.getOr("import failed")
    Collector.push(
      `<file-load-error>`,
      () =>
        Promise.resolve(
          Outcome.fail(
            Throw({error: "Failed to load " ++ path ++ ": " ++ msg, stack: ""}),
          ),
        ),
    )
  }
  let entries = Collector.drain()
  Collector.deactivate()
  entries
}

let runFiles = async (
  opts: options,
  paths: array<string>,
  ~onFileFinished: option<RunnerTypes.fileResult => unit>=?,
  ~onTestStart: option<(string, Collector.entry) => unit>=?,
  ~onTestFinished: option<(string, RunnerTypes.testResult) => unit>=?,
): RunnerTypes.runResult => {
  let startedAt = dateNowIso()
  let startTime = now()
  let files: array<RunnerTypes.fileResult> = []
  for i in 0 to paths->Array.length - 1 {
    let path = paths->Array.getUnsafe(i)
    if Cancellation.isCancelled() {
      ()
    } else {
      let entries = await loadAndCollect(path)
      let onlyActive = Collector.hasOnly.contents
      let selected = entries->Array.filter(e => {
        let keepByOnly = onlyActive ? e.status == Only : true
        // Match filters against both the bare entry id (`describe::name`) and
        // the fully-qualified id the VS Code extension uses
        // (`<absFile>::<describe>::<name>`). Without the qualified form the
        // extension's `--filter=<testId>` never matches — see continuous-run
        // stale-failure fix.
        let qualifiedId = path ++ "::" ++ e.id
        let keepByFilter =
          passesFilter(e.id, opts.filters) || passesFilter(qualifiedId, opts.filters)
        keepByOnly && keepByFilter
      })
      let tests: array<RunnerTypes.testResult> = []
      for j in 0 to selected->Array.length - 1 {
        if Cancellation.isCancelled() {
          let e = selected->Array.getUnsafe(j)
          let r: RunnerTypes.testResult = {
            id: e.id,
            name: e.name,
            describePath: e.describePath,
            status: Skip,
            durationMs: 0.0,
            location: e.location,
            slice: e.slice,
            mismatch: None,
            skipReason: Some("cancelled"),
          }
          tests->Array.push(r)
          switch onTestFinished {
          | Some(cb) => cb(path, r)
          | None => ()
          }
        } else {
          let entry = selected->Array.getUnsafe(j)
          switch onTestStart {
          | Some(cb) => cb(path, entry)
          | None => ()
          }
          let r = await runEntry(entry)
          tests->Array.push(r)
          switch onTestFinished {
          | Some(cb) => cb(path, r)
          | None => ()
          }
        }
      }
      let fr: RunnerTypes.fileResult = {path, tests}
      files->Array.push(fr)
      switch onFileFinished {
      | Some(cb) => cb(fr)
      | None => ()
      }
    }
  }
  let durationMs = now() -. startTime
  let summary = RunnerTypes.summaryOf(files, durationMs, startedAt)
  {summary, files}
}

let emitResult = (opts: options, r: RunnerTypes.runResult) =>
  switch opts.format {
  | Human => FormatterHuman.emit(r)
  | Json =>
    if opts.stream {
      FormatterJson.streamRunEnd(r)
    } else {
      FormatterJson.emit(r, ~toolVersion=opts.toolVersion)
    }
  | Tap => FormatterTap.emit(r)
  | Junit => FormatterJunit.emit(r)
  | VsCode => FormatterVsCode.runEnd(r.summary)
  }

// Watch re-run scope. A plain edit under a test-owning package narrows the pass
// to that package's test files (`RunPackages`); structural rebuilds, new-file
// adds, and any non-VsCode watch use `RunAll`. Scopes accumulate while a pass is
// in flight — `RunAll` is absorbing (an all-run unioned with anything is an
// all-run), and `RunPackages` unions its dirs.
type runScope = RunAll | RunPackages(array<string>)

let mergeScope = (a: runScope, b: runScope): runScope =>
  switch (a, b) {
  | (RunAll, _) | (_, RunAll) => RunAll
  | (RunPackages(x), RunPackages(y)) =>
    let seen = Dict.make()
    let union = []
    Array.concat(x, y)->Array.forEach(d =>
      switch seen->Dict.get(d) {
      | Some(_) => ()
      | None => {
          seen->Dict.set(d, true)
          union->Array.push(d)
        }
      }
    )
    RunPackages(union)
  }

// True when `path` sits inside directory `dir` (dir is an ancestor). Lets a
// package dir be mapped to its test files by prefix, with no per-path fs walk.
let pathUnderDir = (path: string, dir: string): bool =>
  String.startsWith(path, String.endsWith(dir, "/") ? dir : dir ++ "/")

// The subset of `allPaths` a scope re-runs.
let scopeSubset = (scope: runScope, allPaths: array<string>): array<string> =>
  switch scope {
  | RunAll => allPaths
  | RunPackages(dirs) => allPaths->Array.filter(p => dirs->Array.some(d => pathUnderDir(p, d)))
  }

let runOnce = async (opts: options): int => {
  // A watch worker pass supplies the exact path set (parent-owned discovery,
  // narrowed to the affected package); the one-shot commands discover the tree.
  let paths = switch opts.paths {
  | Some(p) => p
  | None => await Discovery.discover(opts.roots)
  }
  if opts.format == Json && opts.stream {
    FormatterJson.streamRunStart(~toolVersion=opts.toolVersion, ~startedAt=dateNowIso())
  }
  let onFileFinished: option<RunnerTypes.fileResult => unit> = switch (
    opts.format,
    opts.stream,
  ) {
  | (Json, true) =>
    Some(
      (f: RunnerTypes.fileResult) => {
        f.tests->Array.forEach(FormatterJson.streamTest)
        FormatterJson.streamFileFinished(f)
      },
    )
  | _ => None
  }
  // VS Code emits per-test events (testStart / testPass / testFail / testSkip)
  // so the extension can update the UI in real time. IDs are prefixed with the
  // absolute file path to match the ids emitted by `discover`.
  let onTestStart: option<(string, Collector.entry) => unit> =
    opts.format == VsCode
      ? Some((path, e) => FormatterVsCode.testStart(path ++ "::" ++ e.id))
      : None
  let onTestFinished: option<(string, RunnerTypes.testResult) => unit> =
    opts.format == VsCode
      ? Some(
          (path, t) => {
            let id = path ++ "::" ++ t.id
            switch t.status {
            | Pass => FormatterVsCode.testPass(id, t.durationMs)
            | Fail => FormatterVsCode.testFail(t, id)
            | Skip =>
              FormatterVsCode.testSkip(id, t.skipReason->Option.getOr("skipped"))
            }
          },
        )
      : None
  // For streaming formatters, emit per-file events; emitResult only emits
  // the terminal `runEnd`.
  if opts.format == Json && opts.stream {
    paths->Array.forEach(p => FormatterJson.streamFileStart(p))
  } else if opts.format == VsCode {
    FormatterVsCode.runStart(~total=0, ~filter=opts.filters)
  }
  let result = await runFiles(opts, paths, ~onFileFinished?, ~onTestStart?, ~onTestFinished?)
  emitResult(opts, result)
  result.summary.failed > 0 ? 1 : 0
}

// Reflects each plugin's pluginStructure via the local host (a single cold load) and
// emits the domain-analysis events: `deadCode` (orphan events) and `graph` (the
// Event-Modeling node/edge model). Skips silently when there are no plugin packages
// or the local platform isn't resolvable, and swallows any load failure so the
// discovery stream is never compromised.
let emitDomainAnalysis = async (pkgs: array<PackageScan.pkg>): unit =>
  switch LocalHost.discover(~packageDirs=pkgs->Array.map(p => p.dir)) {
  | [] => ()
  | plugins =>
    switch LocalHost.resolveLocalPlatform(~fromPackageDir=(plugins->Array.getUnsafe(0)).packageDir) {
    | None => ()
    | Some(platformModulePath) =>
      try {
        let loaded = await LocalHost.loadGraph(~platformModulePath, ~plugins)
        FormatterVsCode.deadCode(DomainDeadCode.analyze(~structures=loaded.structures))
        FormatterVsCode.graph(DomainGraph.build(~structures=loaded.structures))
        // Field schemas for command/event/read-side state (Phase 6.3): the same
        // per-plugin entry the Platform_ComponentDefinitions GraphQL query returns.
        FormatterVsCode.definitions(
          loaded.structures->Array.map(((pluginId, s)) =>
            ReventlessCore.Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId, s)
          ),
        )
      } catch {
      | _ => ()
      }
    }
  }

// Emits the full VS Code discovery stream (tree items + `packages`) for a set
// of already-discovered test files. Shared by `discover` and `watch`.
let emitDiscovery = async (paths: array<string>): unit => {
  FormatterVsCode.discoverStart()
  let fileTests: array<(string, array<RunnerTypes.testResult>)> = []
  for i in 0 to paths->Array.length - 1 {
    let path = paths->Array.getUnsafe(i)
    let entries = await loadAndCollect(path)
    let tests: array<RunnerTypes.testResult> =
      entries->Array.map(e => {
        RunnerTypes.id: e.id,
        name: e.name,
        describePath: e.describePath,
        status: Skip,
        durationMs: 0.0,
        location: e.location,
        slice: e.slice,
        mismatch: None,
        skipReason: None,
      })
    fileTests->Array.push((path, tests))
  }
  FormatterVsCode.emitDiscoveryItems(fileTests)
  let total = fileTests->Array.reduce(0, (a, (_, ts)) => a + ts->Array.length)
  let pkgs = PackageScan.scan(paths)
  FormatterVsCode.packages(pkgs)
  // Full component inventory (incl. untested components) from each package's src/.
  let comps = await ComponentScan.scan(pkgs->Array.map(p => p.dir))
  FormatterVsCode.components(comps)
  FormatterVsCode.discoverEnd(total)
  // Domain analysis (dead-code + graph): emitted after the core stream so the tree
  // shows first. One cold load of the local platform reflects pluginStructure —
  // best-effort; never breaks discovery.
  await emitDomainAnalysis(pkgs)
}

let runDiscover = async (opts: options): int => {
  let paths = await Discovery.discover(opts.roots)
  await emitDiscovery(paths)
  0
}

// Spawns (or adopts) a `rescript build -w` per package owning tests, wiring its
// output to build-status events. Only for the VS Code client — a human `watch`
// in a terminal keeps the lean re-run-only loop.
let startBuildWatchers = (paths: array<string>): unit => {
  Cancellation.onCancel(ProcessManager.killAll)
  PackageScan.scan(paths)->Array.forEach(pkg =>
    if WatcherProbe.hasLiveWatcher(pkg.dir) {
      // A developer's own watcher already covers this package — defer to it.
      FormatterVsCode.buildExternal(pkg.dir)
    } else {
      let feed = BuildClassifier.make({
        onStart: () => FormatterVsCode.buildStart(pkg.dir),
        onOk: ms => FormatterVsCode.buildOk(pkg.dir, ms),
        onFail: msg => FormatterVsCode.buildFail(pkg.dir, msg),
      })
      ProcessManager.spawnWatcher(pkg, ~onStdout=(_dir, line) => feed(line))
    }
  )
}

let runWatch = async (opts: options): int => {
  let roots = opts.roots
  // Parent-owned discovery set for the VS Code engine: walked once here and
  // refreshed only on structural rebuilds / new-file adds. A plain edit's re-run
  // pass reuses it (no per-pass tree re-walk) and narrows to the edited file's
  // owning test package (`affectedScope`), so an unrelated plugin's tests aren't
  // re-executed. The per-test NDJSON protocol keeps the client's other results
  // untouched across a narrowed pass.
  let discoveredPaths: ref<array<string>> = ref([])
  // For the VS Code client, watch mode is the whole engine: emit the test tree
  // and package set, take over the ReScript builds, then run + re-run on change.
  if opts.format == VsCode {
    let paths = await Discovery.discover(roots)
    discoveredPaths := paths
    await emitDiscovery(paths)
    startBuildWatchers(paths)
  }
  // Each re-run pass executes in a short-lived Worker so it gets a fresh ESM
  // module registry (recompiled implementation modules are re-imported instead
  // of served stale from Node's never-evicting cache) and reclaims the imported
  // graph on exit. The worker's stdout is piped to ours, so its NDJSON reaches
  // the client unchanged. One worker per pass; the parent keeps ownership of the
  // build watchers and chokidar.
  let currentWorker: ref<option<Worker.t>> = ref(None)
  Cancellation.onCancel(() =>
    switch currentWorker.contents {
    | Some(w) =>
      let _ = Worker.terminate(w)
    | None => ()
    }
  )
  // Run one pass in a fresh worker over `paths`. `None` lets the worker discover
  // the full tree itself — kept for a human terminal `watch`, whose full-summary
  // output must always reflect every file.
  let runInWorker = (paths: option<array<string>>): promise<unit> =>
    Promise.make((resolve, _reject) => {
      let w = Worker.make(Worker.runWorkerUrl, {workerData: {...opts, paths}})
      currentWorker := Some(w)
      let settled = ref(false)
      let settle = () =>
        if !settled.contents {
          settled := true
          currentWorker := None
          resolve()
        }
      w->Worker.on("exit", (_code: int) => settle())
      w->Worker.on("error", e => {
        Console.error2("gwt run worker error:", e)
        settle()
      })
    })
  // Resolve a scope to the concrete path subset for a worker pass. The VS Code
  // engine passes the parent-owned subset; a human terminal `watch` passes None
  // (worker discovers), preserving its full-summary semantics.
  let pathsForScope = (scope: runScope): option<array<string>> =>
    opts.format == VsCode ? Some(scopeSubset(scope, discoveredPaths.contents)) : None
  // Single-flight run state machine. A re-run requested while a pass is in flight
  // coalesces into `pendingScope` (scopes merge; `RunAll` absorbing) and drains
  // after the current pass. Holding `runInProgress` across the whole drain loop
  // means only one worker ever runs at a time — a third concurrent request can't
  // corrupt the run or interleave NDJSON.
  let runInProgress = ref(false)
  let pendingScope: ref<option<runScope>> = ref(None)
  let requestRun = async (scope: runScope) =>
    if runInProgress.contents {
      pendingScope :=
        Some(
          switch pendingScope.contents {
          | Some(s) => mergeScope(s, scope)
          | None => scope
          },
        )
    } else {
      runInProgress := true
      let _ = await runInWorker(pathsForScope(scope))
      let rec drain = async () =>
        switch pendingScope.contents {
        | Some(next) => {
            pendingScope := None
            let _ = await runInWorker(pathsForScope(next))
            await drain()
          }
        | None => runInProgress := false
        }
      await drain()
    }
  let _ = await requestRun(RunAll)
  // Re-walk discovery (VS Code) then re-run everything. Used after a structural
  // clean-rebuild, whose relocation may have changed the discovered test set.
  let rediscoverAndRun = async () => {
    if opts.format == VsCode {
      discoveredPaths := (await Discovery.discover(roots))
    }
    let _ = await requestRun(RunAll)
  }
  // A *relocation* (a module moved to another directory — a chapter rename /
  // ungroup / move-to-chapter in the extension, or a terminal `mv`) leaves
  // dependents' emitted `.res.mjs` pointing at the old path: incremental
  // compilation never marks them dirty (their source + the moved module's
  // interface hash are unchanged), so the live watcher and a restart both skip
  // them and the stale import surfaces as a `<file-load-error>`. The only
  // reliable repair is a `rescript clean` of the owning package. Detect the
  // structural signal — an `unlink` of a source `.res` (a module left a
  // directory) — and clean-rebuild that package, gating the re-run on build
  // completion. Edits and adds stay on the lean incremental re-run. VS Code
  // only: a human terminal `watch` keeps the re-run-only loop (it doesn't own
  // the builds, so there's nothing to clean-rebuild).
  // Guards against two structural paths from the *same* burst (a multi-file move
  // within one package) each launching a concurrent clean-rebuild of that
  // package. The first sets the flag; siblings coalesce into its completion
  // re-run. Watch now emits one callback per distinct structural path, so this
  // is what makes "rebuild every distinct owning package" (not per-file) true.
  let rebuilding: Dict.t<bool> = Dict.make()
  let structuralRebuild = (path: string): unit =>
    switch PackageScan.findOwning(path) {
    | None => ignore(requestRun(RunAll))
    | Some(pkg) if rebuilding->Dict.get(pkg.dir)->Option.getOr(false) => ()
    | Some(pkg) =>
      rebuilding->Dict.set(pkg.dir, true)
      let t0 = Date.now()
      FormatterVsCode.buildStart(pkg.dir)
      // Surface a compile error during the rebuild (the clean/build stream is
      // classified for the error marker); the re-run is gated on completion
      // below, not on the classifier, since a one-shot `rescript build` has no
      // "Finished … compilation" terminator.
      let sawError = ref(false)
      let feed = BuildClassifier.make({
        onStart: () => (),
        onOk: _ms => (),
        onFail: msg => {
          sawError := true
          FormatterVsCode.buildFail(pkg.dir, msg)
        },
      })
      ProcessManager.cleanRebuild(
        pkg,
        ~onStdout=(_dir, line) => feed(line),
        ~onDone=ok => {
          rebuilding->Dict.set(pkg.dir, false)
          // Only report success when the build actually succeeded. On failure
          // the classifier's `onFail` has usually already emitted the compiler
          // error; emit a fallback `buildFail` only if it didn't (e.g. a crash
          // with no recognisable marker), so we never claim `buildOk` over a
          // broken build and re-run against stale `.res.mjs`.
          if ok {
            FormatterVsCode.buildOk(pkg.dir, Date.now() -. t0)
          } else if !sawError.contents {
            FormatterVsCode.buildFail(pkg.dir, "clean rebuild failed")
          }
          ignore(rediscoverAndRun())
        },
      )
    }
  // A test file added mid-session runs (discover re-scans each pass) but never
  // appears in the client's tree, which was emitted once at start. On an `Add`
  // of a *source* `.res` re-emit the discovery stream (idempotent snapshot) and
  // (re)claim build watchers for any new package before re-running.
  let refreshDiscovery = async () => {
    let paths = await Discovery.discover(roots)
    discoveredPaths := paths
    await emitDiscovery(paths)
    startBuildWatchers(paths)
    let _ = await requestRun(RunAll)
  }
  // Narrow a plain edit's re-run to the edited file's owning test package (VS
  // Code only). `RunAll` when the file has no owning package, or the owner isn't
  // one of the discovered test packages (e.g. a framework edit that ripples into
  // several plugins — full re-run is the safe choice there). A human terminal
  // `watch` always re-runs everything (full-summary output).
  let affectedScope = (path: string): runScope =>
    if opts.format == VsCode {
      let abs = resolvePath(path)
      switch PackageScan.findOwning(PackageScan.dirname(abs)) {
      | Some(pkg) if discoveredPaths.contents->Array.some(p => pathUnderDir(p, pkg.dir)) =>
        RunPackages([pkg.dir])
      | _ => RunAll
      }
    } else {
      RunAll
    }
  let _watcher = Watch.start(roots, (event, path) =>
    if opts.format == VsCode && Watch.isStructuralSource(event, path) {
      structuralRebuild(path)
    } else if opts.format == VsCode && event == Watch.Add && path->String.endsWith(".res") {
      ignore(refreshDiscovery())
    } else {
      ignore(requestRun(affectedScope(path)))
    }
  )
  // Keep the process alive until cancelled. Awaiting here (rather than letting
  // runWatch return) is essential: the bin wrapper calls `process.exit` on the
  // resolved code, so a returning runWatch would tear down chokidar and the
  // spawned build watchers immediately. Cancellation handlers run in
  // registration order — ProcessManager.killAll first, then this resolve — so
  // the watchers are killed before the process exits.
  await Promise.make((resolve, _reject) => Cancellation.onCancel(() => resolve()))
  0
}

// Launches an app's reventless-local platform as a managed child with the domain
// event tap on, streaming lifecycle + events. For the VS Code client the callbacks
// emit NDJSON; a human `platform` prints readable lines and passes the child's own
// logs through.
let runPlatform = async (opts: options): int => {
  let callbacks: PlatformRunner.callbacks = if opts.format == VsCode {
    {
      onStart: (~package, ~dir, ~domainPort, ~platformPort) =>
        FormatterVsCode.platformStart(~package, ~dir, ~domainPort, ~platformPort),
      onReady: (~domainEndpoint) => FormatterVsCode.platformReady(~domainEndpoint),
      onDomainEvent: json => FormatterVsCode.domainEvent(json),
      onLog: line => FormatterVsCode.platformLog(~line),
      onStop: code => FormatterVsCode.platformStop(~code),
    }
  } else {
    {
      onStart: (~package, ~dir as _, ~domainPort, ~platformPort as _) =>
        Console.log(`▶ platform ${package} starting (domain http://localhost:${Int.toString(domainPort)})`),
      onReady: (~domainEndpoint) => Console.log(`✓ platform ready — ${domainEndpoint}`),
      onDomainEvent: json => Console.log("· event " ++ JSON.stringify(json)),
      onLog: line => Console.log(line),
      onStop: code =>
        Console.log(`■ platform stopped (code ${code->Option.mapOr("?", c => Int.toString(c))})`),
    }
  }
  await PlatformRunner.run(
    ~roots=opts.roots,
    ~backend=opts.backend,
    ~fixedPorts=opts.uiPorts,
    ~callbacks,
  )
}

// `platform --list`: enumerate the launchable platform packages under the roots
// and print one NDJSON `{name, dir}` object per line. The VS Code extension reads
// these to populate its active-app picker (app root = the package's parent dir).
// Plain stdout, no protocol handshake — it's a one-shot query, not a stream.
let listPlatforms = async (opts: options): int => {
  let pkgs = await PlatformScan.scan(opts.roots)
  pkgs->Array.forEach(pkg => {
    let obj = Dict.fromArray([("name", JSON.String(pkg.name)), ("dir", JSON.String(pkg.dir))])
    Console.log(JSON.stringify(JSON.Object(obj)))
  })
  0
}

let main = async (): int => {
  Cancellation.install()
  let args = argv
  switch parseArgv(args) {
  | Error(msg) => {
      Console.error(msg)
      args->Array.some(a => a == "--help" || a == "-h") ? 0 : 2
    }
  | Ok(opts) =>
    // Protocol handshake first, so a version-skewed extension can detect the
    // CLI before interpreting the stream.
    if opts.format == VsCode {
      FormatterVsCode.hello()
    }
    switch opts.subcommand {
    | Run => await runOnce(opts)
    | Discover => await runDiscover(opts)
    | Watch => await runWatch(opts)
    | Platform => opts.listPlatforms ? await listPlatforms(opts) : await runPlatform(opts)
    }
  }
}

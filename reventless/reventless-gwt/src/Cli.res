// Entry point for the `reventless-gwt` CLI. Orchestrates discovery, the
// module-level Collector, each formatter, and the watch / cancellation
// plumbing. Parses a minimal argv layer — no optparse library, no colour
// auto-detection — kept deliberately thin so the formatters own all
// presentational logic.

let toolVersion = "0.1.0"

type format = Human | Json | Tap | Junit | VsCode

type subcommand = Run | Discover | Watch

type options = {
  subcommand: subcommand,
  format: format,
  stream: bool,
  watch: bool,
  filters: array<string>,
  schemaVersion: option<string>,
  roots: array<string>,
  toolVersion: string,
}

@val external argv: array<string> = "process.argv"

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

let defaultRoots = () => ["tests"]

let help = () => `reventless-gwt — Given/When/Then runner for Reventless slices

USAGE:
  reventless-gwt run [--format=<fmt>] [--filter=<id>] [--stream] [--watch] [path...]
  reventless-gwt discover [--format=vscode] [path...]
  reventless-gwt watch [--format=<fmt>] [--filter=<id>] [path...]

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
        toolVersion,
      })
    }
  }
}

// Apply --filter: pass if id contains every filter substring, OR if no filters.
let passesFilter = (id: string, filters: array<string>) =>
  filters->Array.length == 0 ||
    filters->Array.some(f => id->String.includes(f))

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
      let outcome = await entry.body()
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
        let jsExn = exn->JsExn.fromException
        let err = jsExn->Option.flatMap(JsExn.message)->Option.getOr("unknown error")
        let stack: option<string> = %raw(`(jsExn && jsExn.stack) || null`)
        mismatch :=
          Some(Outcome.Throw({error: err, stack: stack->Option.getOr("")}))
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
        let keepByFilter = passesFilter(e.id, opts.filters)
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

let runOnce = async (opts: options): int => {
  let paths = await Discovery.discover(opts.roots)
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

let runDiscover = async (opts: options): int => {
  let paths = await Discovery.discover(opts.roots)
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
  FormatterVsCode.discoverEnd(total)
  0
}

let runWatch = async (opts: options): int => {
  let roots = opts.roots
  let runInProgress = ref(false)
  let rerunPending = ref(false)
  let run = async () => {
    if runInProgress.contents {
      rerunPending := true
    } else {
      runInProgress := true
      let _ = await runOnce(opts)
      runInProgress := false
      if rerunPending.contents {
        rerunPending := false
        let _ = await runOnce(opts)
        ()
      }
    }
  }
  let _ = await run()
  let _watcher = Watch.start(roots, _path => {
    ignore(run())
  })
  // Keep the event loop alive indefinitely.
  let _: promise<unit> = Promise.make((_resolve, _reject) => ())
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
    switch opts.subcommand {
    | Run => await runOnce(opts)
    | Discover => await runDiscover(opts)
    | Watch => await runWatch(opts)
    }
  }
}

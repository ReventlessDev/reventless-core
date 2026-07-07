// NDJSON event stream tailored for the VS Code Testing API. Each line maps directly
// to a `TestRun` method call; field names mirror `TestItem` / `TestMessage` so the
// extension needs no translation layer.
//
// The contract is the shared `@reventlessdev/reventless-vscode-protocol` `Protocol`
// module — the SAME sury `@schema` the extension decodes with. Every event is built as
// a `Protocol.streamEvent` variant and serialized via `Protocol.toJsonLine`, so a
// `protocolVersion` bump or field change touches that one definition instead of
// drifting between this emitter and the extension's decoder.

module P = ReventlessVscodeProtocol.Protocol

@val external processStdout: {"write": string => unit} = "process.stdout"
let write = (s: string) => processStdout["write"](s)
let writeLine = (s: string) => write(s ++ "\n")

// Serialize one contract event to its NDJSON line (single source: Protocol).
let emit = (e: P.streamEvent) => writeLine(P.toJsonLine(e))

let uriOf = (path: string) => "file://" ++ path

@val external processCwd: unit => string = "process.cwd"
@module("node:path") external pathBasename: string => string = "basename"
@module("node:path") external pathRelative: (string, string) => string = "relative"

let fileLabelOf = (abs: string) => {
  let base = pathBasename(abs)
  if String.endsWith(base, ".res.mjs") {
    String.slice(base, ~start=0, ~end=String.length(base) - 8)
  } else {
    base
  }
}

let relativeToCwd = (abs: string) => pathRelative(processCwd(), abs)

// ─── .res-source locator ───────────────────────────────────────────────────
// ReScript v12 does not emit JS source maps, so V8 stack frames (the basis for
// Collector.captureLocation) point at `.res.mjs`. Every GWT combinator takes a string
// literal as its first argument — scanning the sibling `.res` file for that literal
// yields an exact line, turning tree-node clicks into `.res` jumps.

@module("node:fs") external _readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external _existsSync: string => bool = "existsSync"

let sourceLineCache: Dict.t<option<array<string>>> = Dict.make()

let mjsToRes = (mjsPath: string): option<string> =>
  if String.endsWith(mjsPath, ".res.mjs") {
    Some(String.slice(mjsPath, ~start=0, ~end=String.length(mjsPath) - 4))
  } else {
    None
  }

let readLinesCached = (resPath: string): option<array<string>> =>
  switch sourceLineCache->Dict.get(resPath) {
  | Some(v) => v
  | None => {
      let v = try {
        _existsSync(resPath)
          ? Some(_readFileSync(resPath, "utf8")->String.split("\n"))
          : None
      } catch {
      | _ => None
      }
      sourceLineCache->Dict.set(resPath, v)
      v
    }
  }

let escapeForDouble = (s: string) =>
  s->String.replaceAll("\\", "\\\\")->String.replaceAll("\"", "\\\"")

let escapeForSingle = (s: string) =>
  s->String.replaceAll("\\", "\\\\")->String.replaceAll("'", "\\'")

let locateInSource = (mjsPath: string, label: string): option<Collector.location> =>
  switch mjsToRes(mjsPath) {
  | None => None
  | Some(resPath) =>
    switch readLinesCached(resPath) {
    | None => None
    | Some(lines) => {
        let needleD = "\"" ++ escapeForDouble(label) ++ "\""
        let needleS = "'" ++ escapeForSingle(label) ++ "'"
        let total = lines->Array.length
        let rec find = i =>
          if i >= total {
            None
          } else {
            let line = lines->Array.getUnsafe(i)
            let idxD = String.indexOf(line, needleD)
            let idxS = String.indexOf(line, needleS)
            let col = switch (idxD, idxS) {
            | (-1, -1) => -1
            | (-1, c) => c + 1
            | (c, -1) => c + 1
            | (a, b) => (a < b ? a : b) + 1
            }
            if col < 0 {
              find(i + 1)
            } else {
              Some({Collector.file: resPath, line: i + 1, column: col})
            }
          }
        find(0)
      }
    }
  }

// 1-based Collector.location → 0-based vscode range (both ends at the token start, as
// the previous emitter did).
let rangeOf = (loc: Collector.location): P.vsRange => {
  let pos: P.position = {line: loc.line - 1, character: loc.column - 1}
  {start: pos, end: pos}
}

let locationOf = (loc: Collector.location): P.failLocation => {
  uri: uriOf(loc.file),
  range: rangeOf(loc),
}

// Bumped whenever the event contract changes — single source in `Protocol`.
let protocolVersion = P.protocolVersion

// First line of every `--format=vscode` invocation, so a client can detect a
// version-skewed CLI before interpreting the stream.
let hello = () => emit(Hello({protocol: P.protocolVersion}))

let discoverStart = () => emit(DiscoverStart({}))

// Used in both `discover` and `run` flows — emit one `item` per file, one per describe,
// one per test so the tree populates before any test runs. File / suite / test URIs
// point at `.res` sources whenever the sibling `.res` is readable.
let emitDiscoveryItems = (files: array<(string, array<RunnerTypes.testResult>)>) => {
  files->Array.forEach(((path, tests)) => {
    let fileId = path
    let fileUri = switch mjsToRes(path) {
    | Some(resPath) if _existsSync(resPath) => uriOf(resPath)
    | _ => uriOf(path)
    }
    let component =
      ComponentMeta.componentOfTestFile(path)->Option.map((c): P.componentMeta => {
        // `ComponentKind.folderName` spellings ARE the typed vocabulary's constructor
        // names, so the identity conversion lands every known kind on its constructor.
        kind: P.componentKindOfString(c.kind),
        name: c.name,
      })
    emit(
      Item({
        id: fileId,
        kind: File,
        label: fileLabelOf(path),
        description: relativeToCwd(path),
        uri: fileUri,
        component: ?component,
      }),
    )
    // Emit describe suites and test leaves.
    let seenDescribes = Dict.make()
    tests->Array.forEach(t => {
      let stack = ref([])
      t.describePath->Array.forEach(label => {
        let parent =
          stack.contents->Array.length == 0
            ? fileId
            : fileId ++ "::" ++ stack.contents->Array.join("::")
        stack := Array.concat(stack.contents, [label])
        let id = fileId ++ "::" ++ stack.contents->Array.join("::")
        switch seenDescribes->Dict.get(id) {
        | Some(_) => ()
        | None => {
            seenDescribes->Dict.set(id, true)
            let loc = locateInSource(path, label)
            emit(
              Item({
                id,
                parent,
                kind: Suite,
                label,
                uri: ?loc->Option.map(l => uriOf(l.file)),
                range: ?loc->Option.map(rangeOf),
              }),
            )
          }
        }
      })
      let parent =
        t.describePath->Array.length == 0
          ? fileId
          : fileId ++ "::" ++ t.describePath->Array.join("::")
      let testId = fileId ++ "::" ++ t.id
      let resLoc = locateInSource(path, t.name)
      let loc = switch (resLoc, t.location) {
      | (Some(loc), _) | (None, Some(loc)) => Some(loc)
      | (None, None) => None
      }
      emit(
        Item({
          id: testId,
          parent,
          kind: Test,
          label: t.name,
          uri: ?loc->Option.map(l => uriOf(l.file)),
          range: ?loc->Option.map(rangeOf),
        }),
      )
    })
  })
}

let discoverEnd = (total: int) => emit(DiscoverEnd({total: total}))

// The set of workspace packages owning discovered tests — the build set a watch
// session keeps compiling.
let packages = (pkgs: array<PackageScan.pkg>) =>
  emit(
    Packages({
      packages: pkgs->Array.map((p): P.packageInfo => {name: p.name, dir: p.dir, build: p.build}),
    }),
  )

// The full component inventory across the owning packages — every Aggregate / slice /
// ReadModel / … in src/, whether or not it has a GWT test.
let components = (comps: array<ComponentScan.component>) =>
  emit(
    Components({
      components: comps->Array.map((c): P.componentRef => {
        dir: c.dir,
        kind: P.componentKindOfString(c.kind),
        name: c.name,
        files: c.files,
      }),
    }),
  )

// Domain-level dead code (Phase 5) — produced events no component consumes.
let deadCode = (findings: array<DomainDeadCode.finding>) =>
  emit(
    DeadCode({
      findings: findings->Array.map((f): P.deadCodeFinding => {
        kind: f.kind,
        plugin: f.pluginName,
        component: f.componentName,
        detail: f.detail,
      }),
    }),
  )

// Event-Modeling graph (Phase 6) — the node/edge model assembled from each plugin's
// `pluginStructure` + cross-plugin edges.
// `DomainGraph` already builds `P.graphNode`/`P.graphEdge`, so the graph event
// forwards them directly — no field-by-field re-map to drift from the contract.
let graph = (g: DomainGraph.graph) => emit(Graph({nodes: g.nodes, edges: g.edges}))

// Component definitions (Phase 6.3) — one `encodePluginStructureEntry` JSON object
// per plugin (commands/events with field schemas, read-side state schemas), used by
// the extension to render field rows.
let definitions = (entries: array<JSON.t>) => emit(Definitions({entries: entries}))

// ─── Build status (watch mode) ──────────────────────────────────────────────

let buildStart = (pkg: string) => emit(BuildStart({package: pkg}))
let buildOk = (pkg: string, durationMs: float) => emit(BuildOk({package: pkg, durationMs: durationMs}))
let buildFail = (pkg: string, message: string) => emit(BuildFail({package: pkg, message: message}))
let buildExternal = (pkg: string) => emit(BuildExternal({package: pkg}))

// ── Local platform runner events (protocol 7) ───────────────────────────────

let platformStart = (~package: string, ~dir: string, ~domainPort: int, ~platformPort: int) =>
  emit(PlatformStart({package, dir, domainPort, platformPort}))

let platformReady = (~domainEndpoint: string) => emit(PlatformReady({domainEndpoint: domainEndpoint}))

// `payload` is the parsed JSON object the LocalBus tap emitted (already shaped
// `{event:"domainEvent", seq, topic, service, payload, ts}`) — re-emitted verbatim as
// one NDJSON line so the extension parses it like any other engine event.
let domainEvent = (payload: JSON.t) => writeLine(JSON.stringify(payload))

let platformLog = (~line: string) => emit(PlatformLog({line: line}))

let platformStop = (~code: option<int>) => emit(PlatformStop({code: ?code}))

let runStart = (~total: int, ~filter: array<string>) => emit(RunStart({total, filter}))

let testStart = (id: string) => emit(TestStart({id: id}))

let testPass = (id: string, durationMs: float) => emit(TestPass({id, durationMs}))

let testSkip = (id: string, reason: string) => emit(TestSkip({id, reason}))

// The failure payload the extension renders — built as a typed `Protocol.failMessage`.
let messagePayload = (t: RunnerTypes.testResult): P.failMessage =>
  switch t.mismatch {
  | Some(m) =>
    let hint = Hint.forMismatch(~slice=?t.slice, m)
    // Expected / actual for the diff view, rendered as ReScript syntax.
    let (expected, actual) = switch m {
    | EventsMismatch({expected, actual}) => (
        Some(RenderRescript.renderMany(expected)),
        Some(RenderRescript.renderMany(actual)),
      )
    | ErrorMismatch({expected, actual, actualEvents}) =>
      let actStr = switch actual {
      | Some(v) => "Error(" ++ RenderRescript.render(v) ++ ")"
      | None => "Ok(" ++ RenderRescript.renderMany(actualEvents) ++ ")"
      }
      (Some("Error(" ++ RenderRescript.render(expected) ++ ")"), Some(actStr))
    | StateMismatch({expected, actual, _}) => (
        Some(RenderRescript.renderOption(expected)),
        Some(RenderRescript.renderOption(actual)),
      )
    | NoEventExpected({actual}) => (Some("[]"), Some(RenderRescript.renderMany(actual)))
    | QueryRowsMismatch({expected, actual}) => (
        Some(RenderRescript.renderMany(expected)),
        Some(RenderRescript.renderMany(actual)),
      )
    | PublishedActionsMismatch({expected, actual}) => (
        Some(RenderRescript.renderMany(expected)),
        Some(RenderRescript.renderMany(actual)),
      )
    | AppendConditionMismatch({expected, actual}) => (
        Some(RenderRescript.render(expected)),
        Some(RenderRescript.render(actual)),
      )
    | TranslateError({expected, actual}) => (Some(expected), Some(actual->Option.getOr("(none)")))
    | TodoMismatch(_) => (Some(Outcome.format(m)), Some(""))
    | Throw({error}) => (Some(""), Some(error))
    }
    // Location points at the test file — prefer the sibling `.res` resolved via the
    // test label so Cmd+Click jumps to readable source, not compiled `.res.mjs`.
    let location =
      t.location->Option.map(loc => locationOf(locateInSource(loc.file, t.name)->Option.getOr(loc)))
    {
      message: hint.message,
      // The mismatch family — lets a client gate the apply-expected quick-fix.
      // `Outcome.kindName` stays string-returning (JUnit/JSON formatters consume it
      // raw); its spellings are the assertionKind constructor names, so the identity
      // conversion types it losslessly.
      kind: ?Some(P.assertionKindOfString(Outcome.kindName(m))),
      expected: ?expected,
      actual: ?actual,
      location: ?location,
    }
  | None => {message: "failed"}
  }

let testFail = (t: RunnerTypes.testResult, id: string) =>
  emit(TestFail({id, durationMs: t.durationMs, messages: [messagePayload(t)]}))

let runEnd = (s: RunnerTypes.summary) =>
  emit(RunEnd({passed: s.passed, failed: s.failed, skipped: s.skipped, durationMs: s.durationMs}))

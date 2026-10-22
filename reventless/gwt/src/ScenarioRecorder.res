// Decision scenarios as they run, written as sidecars `check-lifecycle` reads.
//
// The PPX writes a `.gwt.json` sidecar from a `_GWT.res` file's source, so it can only name what
// the source spells out: a literal constructor in a step. A suite written against a binding (a
// trait's conformance suite, whose `B.request(…)` is whatever the host's binding builds) names
// nothing in its source, and the host's file that registers it has no `describe` of its own, so
// no sidecar is written and `check-lifecycle` sees none of its scenarios. The run has the values,
// and the spec's schemas name them; this records them.
//
// Only with `REVENTLESS_EMIT_SIDECAR` set in the test process, the switch the PPX reads at build
// time; otherwise every call is a no-op. A test file whose sidecar the PPX wrote is left alone:
// read from source, it carries values and ids a run cannot.

type entry = {kind: string, element: string}

type scenario = {
  title: string,
  given: array<entry>,
  when_: array<entry>,
  then_: array<entry>,
}

let enabled = () =>
  switch NodeProcess.env->Dict.get("REVENTLESS_EMIT_SIDECAR") {
  | Some("1" | "true" | "TRUE") => true
  | _ => false
  }

// The scenario of the test running now, if one is being recorded.
let current: ref<option<scenario>> = ref(None)

// The test file an external runner says it is running; Jest says it itself.
let fileOverride: ref<option<string>> = ref(None)

/** Names the test file an external runner (registered through `RunnerHook`) is about to run, so
    what its tests record lands beside it. */
let setFile = (path: string) => fileOverride := Some(path)

// The running test's file under Jest, while a test runs.
let jestTestPath: unit => option<string> = %raw(`function () {
  try {
    const state = globalThis.expect && globalThis.expect.getState && globalThis.expect.getState();
    return state && typeof state.testPath === "string" ? state.testPath : undefined;
  } catch (_) { return undefined; }
}`)

let testFile = () =>
  switch fileOverride.contents {
  | Some(f) => Some(f)
  | None => jestTestPath()
  }

// What has been recorded in this process, per sidecar path: the spec it names and its scenarios.
let recorded: Map.t<string, (string, array<scenario>)> = Map.make()

// Per test file, the specs recorded from it in order, the first owning `<File>_GWT.gwt.json`.
let specsOf: Map.t<string, array<string>> = Map.make()

// Sidecar paths found written by the PPX: never written over.
let foreign: Set.t<string> = Set.make()

// `…/X_GWT.res.mjs` (or `.res`, `.mjs`, `.js`) → `…/X_GWT`.
let baseOf = (file: string) =>
  [".res.mjs", ".res.js", ".res", ".mjs", ".js"]->Array.reduce(file, (f, ext) =>
    f->String.endsWith(ext)
      ? f->String.slice(~start=0, ~end=String.length(f) - String.length(ext))
      : f
  )

let sidecarFor = (~file: string, ~spec: string) => {
  let specs = specsOf->Map.get(file)->Option.getOr([])
  if !(specs->Array.includes(spec)) {
    specs->Array.push(spec)
    specsOf->Map.set(file, specs)
  }
  specs->Array.indexOf(spec) == 0 ? `${baseOf(file)}.gwt.json` : `${baseOf(file)}.${spec}.gwt.json`
}

// Whether a sidecar at `path` is the PPX's: present and not marked recorded.
let writtenByPpx = (path: string) =>
  switch NodeFs.existsSync(path) {
  | false => false
  | true =>
    switch NodeFs.readFileSync(path)->JSON.parseOrThrow {
    | Object(d) => d->Dict.get("recorded") != Some(Boolean(true))
    | _ => true
    | exception _ => true
    }
  }

let entryJson = (e: entry) => JSON.Object(
  Dict.fromArray([
    ("kind", JSON.String(e.kind)),
    ("element", JSON.String(e.element)),
    ("values", JSON.Array([])),
  ]),
)

let write = (~path: string, ~file: string, ~spec: string, scenarios: array<scenario>) => {
  let json = JSON.Object(
    Dict.fromArray([
      ("specName", JSON.String(`${spec} (recorded)`)),
      // What `check-lifecycle` takes the file's component from.
      ("stem", JSON.String(spec)),
      ("file", JSON.String(file)),
      ("componentKind", JSON.String("Decision")),
      ("recorded", JSON.Boolean(true)),
      (
        "scenarios",
        JSON.Array(
          scenarios->Array.map(s => JSON.Object(
            Dict.fromArray([
              ("title", JSON.String(s.title)),
              ("given", JSON.Array(s.given->Array.map(entryJson))),
              ("when", JSON.Array(s.when_->Array.map(entryJson))),
              ("then", JSON.Array(s.then_->Array.map(entryJson))),
            ]),
          )),
        ),
      ),
    ]),
  )
  let text = JSON.stringifyAny(json, ~space=2)->Option.getOr("{}") ++ "\n"
  // Written only when it says something new: a watch reacts to the write, and the same run
  // records the same scenarios each time.
  let same = switch NodeFs.readFileSync(path) {
  | old => old == text
  | exception _ => false
  }
  if !same {
    NodeFs.writeFileSync(path, text)
  }
}

/** Runs one test's `body`, recording its steps when recording is on, and adds the scenario to
    its file's sidecar. `spec` is the spec the test runs against, the component the sidecar names. */
let around = (~spec: string, title: string, body: unit => 'outcome): 'outcome =>
  if !enabled() {
    body()
  } else {
    current := Some({title, given: [], when_: [], then_: []})
    let finish = () => {
      let scenario = current.contents
      current := None
      switch (scenario, testFile()) {
      | (Some(s), Some(file)) =>
        let path = sidecarFor(~file, ~spec)
        if !(foreign->Set.has(path)) && !(recorded->Map.has(path)) && writtenByPpx(path) {
          foreign->Set.add(path)
        }
        if !(foreign->Set.has(path)) {
          let (_, scenarios) = recorded->Map.get(path)->Option.getOr((spec, []))
          let scenarios = scenarios->Array.filter(o => o.title != s.title)->Array.concat([s])
          recorded->Map.set(path, (spec, scenarios))
          write(~path, ~file, ~spec, scenarios)
        }
      | _ => ()
      }
    }
    switch body() {
    | outcome =>
      finish()
      outcome
    | exception e =>
      finish()
      throw(e)
    }
  }

/** Whether a test is being recorded now: the steps name what they get only then. */
let recording = () => current.contents->Option.isSome

let push = (pick: scenario => array<entry>, entries: array<entry>) =>
  current.contents->Option.forEach(s => entries->Array.forEach(e => pick(s)->Array.push(e)))

/** The history a command is decided on, by event name. */
let given = (names: array<string>) =>
  push(s => s.given, names->Array.map(element => {kind: "event", element}))

/** The command a test sends. */
let whenCommand = (name: string) => push(s => s.when_, [{kind: "command", element: name}])

/** What a test expects: these events. */
let thenEvents = (names: array<string>) =>
  push(s => s.then_, names->Array.map(element => {kind: "event", element}))

/** What a test expects: this error. */
let thenError = (name: string) => push(s => s.then_, [{kind: "error", element: name}])

/** What a test expects: no event. */
let thenNoEvent = () => push(s => s.then_, [{kind: "noEvent", element: ""}])

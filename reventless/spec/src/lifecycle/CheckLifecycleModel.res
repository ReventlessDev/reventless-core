/**
The lifecycle model each example's own scenarios describe, and what it says about
the edges each command declares beside them.

`Moves([Placed], Shipped)` is authored, and until now nothing compared it to
behaviour. The compiler resolves the state constructors and the platform checks
they belong to the linked view — both much weaker properties than agreement: a
command can declare `Moves([Deactivated], Active)` while its `decide` accepts an
active row, or emit an event the view folds into something else, and every static
check still passes.

The scenarios already answer this. Each `@@reventless.gwt` file is a corpus of
`given / when / then`, and the PPX writes it out as a `<Stem>.gwt.json` sidecar
under `REVENTLESS_EMIT_SIDECAR=1`. This script drives that build, folds the
scenarios into a `(fromState, command, outcome, toState)` relation, and reports
each declared edge as **confirmed**, **contradicted** or **unverified**.

Two properties are worth stating because they are what makes the result
trustworthy:

- **It reads a compile-time artifact, not a test run.** The sidecar is written
  while the file is parsed, so a scenario counts whether or not it passes, and
  whether or not anyone ran it. Metadata that depended on a test *run* would mean
  a deleted test file silently changing a command menu.

- **It keys on effect, not on acceptance.** A command is in a state's from-set
  when a scenario shows it *emitting* there. The repository's `Ok([])`-on-no-change
  convention means `decide` accepts commands a menu should not offer, so keying
  on acceptance would derive a from-set that disagrees with every declaration.

Contradictions fail the run; unverified edges are warnings, counted so a corpus
getting thinner is visible.

Two artifacts come out of the same derivation. `schema/lifecycle-model.json` is
the reviewable golden, one per app. `src/LifecycleModel.res` is the value
structure assembly reads, one per plugin — written here rather than by
`generate-plugin`, which runs in `prebuild` and would therefore always be one
build behind the sidecars it would have to read.

An **app root** is a directory whose immediate subdirectories are plugins, a
plugin being a directory with both a composition root (`src/Plugin.res`) and a
corpus (`tests/`). `examples/online-shop-hybrid` is one; so is the root of an app
`create-app` generated. With no `--root`, every subdirectory of `<cwd>/examples`
is taken as one, which is what this repository's own gate wants and was for a
while the only thing this could do.

Usage, in this repository:

```
pnpm run check:lifecycle           # fail on contradictions or artifact drift
pnpm run check:lifecycle:update    # rewrite the goldens and the models
pnpm run check:lifecycle -- --reuse-sidecars   # read what a prior build wrote
pnpm run check:lifecycle -- --reuse-sidecars --json   # the same run, machine-readable
```

and against an app, through the `check-lifecycle` binary this package ships:

```
check-lifecycle --root . --reuse-sidecars --json
check-lifecycle --root . --update     # write this app's models and golden
```
*/

// The model this script writes is folded into `pluginStructure`, so by the time
// it runs again the "declared" side it reads back would be its own last answer —
// every edge confirmed, and a real disagreement between an annotation and the
// corpus invisible. This asks the structure for the declarations alone. Set
// before anything imports a plugin, because `Plugin_Structure` reads it once.
NodeProcess.env->Dict.set("REVENTLESS_DECLARED_TRANSITIONS_ONLY", "1")

// ── Where things live ───────────────────────────────────────────────────────

let repoRoot = NodeProcess.cwd()
let examplesDir = NodePath.join([repoRoot, "examples"])
let update = NodeProcess.argv->Array.includes("--update")

/** Every `<flag> <value>` pair on the command line, so a flag can be repeated.

    A value that looks like another flag is not consumed, so `--root --json`
    reports no roots rather than silently checking a directory named `--json`. */
let flagValues = (flag: string): array<string> => {
  let argv = NodeProcess.argv
  let out = []
  for i in 0 to Array.length(argv) - 1 {
    if argv->Array.get(i) == Some(flag) {
      switch argv->Array.get(i + 1) {
      | Some(value) if !(value->String.startsWith("--")) => out->Array.push(value)->ignore
      | _ => ()
      }
    }
  }
  out
}

/** An app whose plugins are checked together, and the name it is reported under.

    The golden is per app because a command's edge is only meaningful beside the
    other plugins it shares an event log with. */
type appRoot = {label: string, dir: string}

/** Read the sidecars a prior build already wrote instead of driving one. CI's
    build step sets `REVENTLESS_EMIT_SIDECAR=1`, so by the time this runs the
    corpus is on disk; a second pass over a warm tree buys nothing and costs the
    multi-root build chain's habit of cleaning artifacts outside the root it is
    building, which lands intermittently on a stale `.cmi`. */
let reuseSidecars = NodeProcess.argv->Array.includes("--reuse-sidecars")

/** Report the run as one JSON document on stdout instead of the grouped prose.

    For a consumer that has to place a finding somewhere — an editor putting a
    squiggle on the arm that made the claim — rather than read it. The prose
    bakes component, command and state into a sentence; this keeps them as
    fields, so the consumer does not parse English back into a range.

    Artifacts are neither written nor compared under `--json`: a reader asking
    what the corpus says now must not, as a side effect, rewrite what the
    repository says it said — nor fail because the two have drifted, which is a
    fact about the repository rather than about the corpus it was asked to
    report. A contradiction still exits non-zero, so this composes with a gate. */
let json = NodeProcess.argv->Array.includes("--json")

/** The label a state carries when no row exists yet. Not a lifecycle case — no
    enum declares it — so it is spelled in a way no constructor can name, and a
    command whose successful scenarios all start here is creating rather than
    guarding. */
let noRow = "(none)"

// ── Small JSON readers ──────────────────────────────────────────────────────

// Read field by field rather than parsed through the published schema. A
// `pluginStructure` has two legitimate representations — an absent optional is
// `undefined` in memory and an explicit `null` on the wire — and the schema
// describes the wire form, so a whole-structure parse fails on every optional
// that happens to be empty.

let asObj = (j: JSON.t): option<dict<JSON.t>> => j->JSON.Decode.object
let getStr = (d: dict<JSON.t>, k: string): option<string> =>
  d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
let getArr = (d: dict<JSON.t>, k: string): array<JSON.t> =>
  d->Dict.get(k)->Option.flatMap(JSON.Decode.array)->Option.getOr([])
let getObjs = (d: dict<JSON.t>, k: string): array<dict<JSON.t>> =>
  getArr(d, k)->Array.filterMap(asObj)
let getStrs = (d: dict<JSON.t>, k: string): array<string> =>
  getArr(d, k)->Array.filterMap(JSON.Decode.string)

/** `Some` only for an explicit array. `allowedStates` is three-valued —
    unannotated, annotated with a set, annotated with the empty set — and
    flattening the first two into `[]` erases the distinction the whole report
    rests on. */
let getStrsOpt = (d: dict<JSON.t>, k: string): option<array<string>> =>
  switch d->Dict.get(k) {
  | None => None
  | Some(v) => v->JSON.Decode.array->Option.map(a => a->Array.filterMap(JSON.Decode.string))
  }

/** A constructor is written qualified as often as not — `Customer.Registered`,
    `Customers_Projections.OrderEvents.OrderPlaced` — and the qualification is
    about where the test could see the type from, not about which event it is. */
let last = (xs: array<'a>): option<'a> => xs->Array.get(Array.length(xs) - 1)

let lastSegment = (name: string): string => {
  let parts = name->String.split(".")
  parts->last->Option.getOr(name)
}

let sortedUnique = (xs: array<string>): array<string> => {
  let out = []
  xs->Array.forEach(x =>
    if !(out->Array.includes(x)) {
      out->Array.push(x)
    }
  )
  out->Array.toSorted(String.compare)
}

// ── The corpus ──────────────────────────────────────────────────────────────

/** A named thing a step mentions, with the literal values the scenario wrote for
    it. The values are what let a history be read as belonging to one row: a
    slice's setup routinely names other entities, and folding those into this
    row's state is how a scenario about a second order gets read as a scenario
    about the first one's. */
type element = {name: string, values: array<(string, JSON.t)>}

/** One scenario, reduced to what the harvest reads. `then` carries at most one
    step in every DSL here, so it is a kind and a payload rather than a list. */
type scenario = {
  title: string,
  given: array<element>,
  whenKind: string,
  whenElements: array<element>,
  thenKind: string,
  thenElements: array<element>,
  thenValues: array<(string, JSON.t)>,
}

type corpus = {
  /** The component the file is about: the filename stem with `_GWT` removed,
      which is the spec name the plugin structure knows it by. */
  component: string,
  path: string,
  scenarios: array<scenario>,
}

/** `[[name, exampleValue], …]` — the shape the sidecar writes a record literal
    in. Anything that is not a two-element pair is skipped rather than guessed
    at. */
let valuesOf = (step: dict<JSON.t>): array<(string, JSON.t)> =>
  getArr(step, "values")->Array.filterMap(v =>
    switch v->JSON.Decode.array {
    | Some([name, value]) => name->JSON.Decode.string->Option.map(n => (n, value))
    | _ => None
    }
  )

let elementsOf = (steps: array<dict<JSON.t>>): array<element> =>
  steps->Array.filterMap(s =>
    s->getStr("element")->Option.map(name => {name: lastSegment(name), values: valuesOf(s)})
  )

let kindOf = (steps: array<dict<JSON.t>>): string =>
  steps->Array.get(0)->Option.flatMap(s => s->getStr("kind"))->Option.getOr("")

let scenarioOf = (j: JSON.t): option<scenario> =>
  j
  ->asObj
  ->Option.map(d => {
    let given = getObjs(d, "given")
    let when_ = getObjs(d, "when")
    let then_ = getObjs(d, "then")
    {
      title: d->getStr("title")->Option.getOr(""),
      given: elementsOf(given),
      whenKind: kindOf(when_),
      whenElements: elementsOf(when_),
      thenKind: kindOf(then_),
      thenElements: elementsOf(then_),
      thenValues: then_->Array.get(0)->Option.map(valuesOf)->Option.getOr([]),
    }
  })

let readCorpus = (path: string): option<corpus> =>
  switch path->NodeFs.readFileSync->JSON.parseOrThrow->asObj {
  | None => None
  | Some(d) =>
    let stem = d->getStr("stem")->Option.getOr("")
    Some({
      component: stem->String.replace("_GWT", ""),
      path,
      scenarios: getArr(d, "scenarios")->Array.filterMap(scenarioOf),
    })
  | exception _ => None
  }

let rec filesUnder = (dir: string, ~suffix: string): array<string> =>
  switch NodeFs.readdirSync(dir, {withFileTypes: true}) {
  | entries =>
    entries->Array.flatMap(entry => {
      let name = entry->NodeFs.direntName
      let full = NodePath.join([dir, name])
      if entry->NodeFs.isDirectory {
        // `lib` holds a second copy of every compiled module, and `node_modules`
        // a copy of every dependency's tests. Both would be harvested twice, and
        // neither copy is the one the plugin's own imports resolve to.
        name == "node_modules" || name == "lib" || name->String.startsWith(".")
          ? []
          : filesUnder(full, ~suffix)
      } else if name->String.endsWith(suffix) {
        [full]
      } else {
        []
      }
    })
  | exception _ => []
  }

// ── Driving the build that writes the sidecars ──────────────────────────────

let gwtSources = (~pluginDirs: array<string>): array<string> =>
  pluginDirs->Array.flatMap(dir => filesUnder(NodePath.join([dir, "tests"]), ~suffix="_GWT.res"))

let sidecarOf = (gwt: string): string => gwt->String.replace("_GWT.res", "_GWT.gwt.json")

/** A build that never set `REVENTLESS_EMIT_SIDECAR` leaves no corpus at all, and
    an empty corpus reads as every edge `unverified` — a warning, so the run
    would pass having checked nothing. Say so instead.

    Only the empty case is checked, not sidecar-per-file: a GWT file whose
    `describe` argument is not a string literal legitimately emits none, and the
    committed goldens are what catch a corpus that merely got thinner. */
let hasCorpus = (~pluginDirs: array<string>): bool =>
  gwtSources(~pluginDirs)->Array.some(f => f->sidecarOf->NodeFs.existsSync)

let checkSidecars = (~pluginDirs: array<string>): result<unit, string> =>
  hasCorpus(~pluginDirs)
    ? Ok()
    : Error(
        "--reuse-sidecars was passed, but no scenario sidecar exists. Build with " ++
        "REVENTLESS_EMIT_SIDECAR=1 first, or drop the flag.",
      )

/** Sidecars are gitignored build artifacts, so the harvest produces its own
    rather than trusting whatever a previous build happened to leave behind.

    The touch is not superstition. `rescript` caches on source mtime, and the
    sidecar is a side effect of *parsing* — so a tree that is already built emits
    nothing at all no matter what the environment says. Making the sources look
    newer is the only lever a caller has over a compiler's cache.

    **One root build, not one per plugin.** Each build root's clean step orphans
    the in-source test outputs of packages in its dependency graph but outside
    itself, and the root `build` script is a chain ordered to re-emit them. Six
    per-plugin builds would leave several packages' test outputs deleted, which
    is not a build failure — it is a jest project that discovers nothing and
    passes. So the harvest drives the same ordered chain everyone else does, and
    leaves the tree exactly as it found it.

    **The chain it drives is the working directory's**, not each root's. That is
    right for the ordinary invocations — this repository's gate, and `--root .`
    from an app — and wrong for a `--root` pointing somewhere else, which is why
    the caller checks for a corpus afterwards either way rather than trusting
    that a build it did not target wrote one. */
let emitSidecars = (~pluginDirs: array<string>): result<unit, string> => {
  let now = Date.now() /. 1000.0
  gwtSources(~pluginDirs)->Array.forEach(f => NodeFs.utimesSync(f, now, now))

  let env =
    NodeProcess.env
    ->Dict.toArray
    ->Array.concat([("REVENTLESS_EMIT_SIDECAR", "1")])
    ->Dict.fromArray

  try {
    let _ = NodeChildProcess.execFileSync(
      "pnpm",
      ["run", "build"],
      {cwd: repoRoot, env, encoding: "utf8", maxBuffer: 256 * 1024 * 1024},
    )
    Ok()
  } catch {
  | exn =>
    Error(
      exn
      ->JsExn.fromException
      ->Option.flatMap(JsExn.message)
      ->Option.getOr("the build that emits the scenario sidecars failed"),
    )
  }
}

// ── The declared side ───────────────────────────────────────────────────────

type declaredCommand = {
  command: string,
  level: string,
  /** The field carrying the id of the row the command addresses, where the
      component has one. Used to tell this row's setup from the rest of it. */
  aggregateIdField: option<string>,
  allowedStates: option<array<string>>,
  targetState: option<string>,
  /** `"unrestricted"` is the one value this reads for: it is how a declared
      "legal in every state" reaches here, since the from-set it publishes is
      the same `None` as saying nothing at all. */
  allowedStatesSource: option<string>,
}

type declaredWritable = {
  name: string,
  linkedViews: array<string>,
  commands: array<declaredCommand>,
}

type declaredView = {name: string, lifecycleField: option<string>}

type declared = {writables: array<declaredWritable>, views: array<declaredView>}

/** `commandLevel` is a sury-encoded variant, so it arrives as `"Collection"` /
    `"Instance"` or as a tagged object depending on how it was built. Both are
    read; anything else is left blank rather than guessed, since a wrong level is
    worse than an absent one. */
let levelOf = (d: dict<JSON.t>): string =>
  switch d->Dict.get("level") {
  | Some(String(s)) => s
  | Some(Object(o)) => o->getStr("TAG")->Option.getOr("")
  | _ => ""
  }

let declaredCommandOf = (d: dict<JSON.t>): option<declaredCommand> =>
  d
  ->getStr("name")
  ->Option.map(command => {
    command,
    level: levelOf(d),
    aggregateIdField: d->getStr("aggregateIdField"),
    allowedStates: getStrsOpt(d, "allowedStates"),
    targetState: d->getStr("targetState"),
    allowedStatesSource: d->getStr("allowedStatesSource"),
  })

let declaredOf = (structure: JSON.t): option<declared> =>
  structure
  ->asObj
  ->Option.map(s => {
    let writablesFrom = key =>
      getObjs(s, key)->Array.filterMap(w =>
        w
        ->getStr("name")
        ->Option.map(name => {
          name,
          linkedViews: getStrs(w, "linkedViews"),
          commands: getObjs(w, "commands")->Array.filterMap(declaredCommandOf),
        })
      )
    let viewsFrom = key =>
      getObjs(s, key)->Array.filterMap(v =>
        v->getStr("name")->Option.map(name => {name, lifecycleField: v->getStr("lifecycleField")})
      )
    {
      writables: Array.concat(writablesFrom("aggregates"), writablesFrom("stateChangeSlices")),
      views: Array.concat(viewsFrom("readModels"), viewsFrom("stateViewSlices")),
    }
  })

@module("./loadPluginStructure.mjs")
external loadPluginStructure: string => promise<JSON.t> = "loadPluginStructure"

let readDeclared = async (~pluginDir: string): result<declared, string> => {
  let raw = await loadPluginStructure(pluginDir)
  switch raw->asObj {
  | None => Error("the structure loader returned something unreadable")
  | Some(d) =>
    switch d->Dict.get("ok") {
    | Some(Boolean(true)) =>
      switch d->Dict.get("structure")->Option.flatMap(declaredOf) {
      | Some(declared) => Ok(declared)
      | None => Error("the plugin structure could not be read")
      }
    | _ => Error(d->getStr("error")->Option.getOr("the plugin structure could not be loaded"))
    }
  }
}

// ── Rule 1: labelling a history with a lifecycle state ──────────────────────

/** The lifecycle value a `thenState` step asserts, for the field the view
    declares as its lifecycle. A lifecycle case is a payload-less constructor, so
    it arrives as the sidecar's `enum` kind; a view whose lifecycle is spelled as
    a string is read too, since nothing forbids one. */
let lifecycleValue = (values: array<(string, JSON.t)>, ~field: string): option<string> =>
  values
  ->Array.find(((name, _)) => name == field)
  ->Option.flatMap(((_, value)) => value->asObj)
  ->Option.flatMap(v =>
    switch v->getStr("kind") {
    | Some("enum") | Some("string") => v->getStr("value")->Option.map(lastSegment)
    | _ => None
    }
  )

/** Which lifecycle value each event *sets*, per view.

    An event that leaves the value alone must not be recorded as setting it, or
    every history ends at whatever its last event happened to be tested from. So
    an event earns a mapping only where a scenario shows it *changing* the value:
    creating the row from nothing, or landing somewhere its own setup was not.

    That takes more than one pass — a scenario's setup can only be folded once
    the events in it have mappings — so this runs to a fixpoint. The bound is a
    guard against a corpus that oscillates, not an expected exit. */
let lifecycleMapFor = (
  ~scenarios: array<scenario>,
  ~field: string,
  ~ambiguities: array<(string, string)>,
  ~view: string,
): dict<string> => {
  let map = Dict.make()

  let fold = (events: array<element>) =>
    events->Array.reduce(noRow, (current, event) =>
      switch map->Dict.get(event.name) {
      | Some(value) => value
      | None => current
      }
    )

  let record = (event, value, ~title) =>
    switch map->Dict.get(event) {
    | Some(existing) if existing != value =>
      // Two scenarios disagree about where this event lands. Reported rather
      // than resolved: picking one would invent a precision the corpus does not
      // have, and the honest answer is that the view needs another scenario.
      ambiguities
      ->Array.push((
        view,
        `${view}: ${event} is projected as both "${existing}" and "${value}" ` ++
        `(seen in "${title}") — the harvest keeps "${existing}"`,
      ))
      ->ignore
    | Some(_) => ()
    | None => map->Dict.set(event, value)
    }

  let changed = ref(true)
  let rounds = ref(0)
  while changed.contents && rounds.contents < 8 {
    changed := false
    rounds := rounds.contents + 1
    let before = map->Dict.keysToArray->Array.length

    scenarios->Array.forEach(s =>
      if s.whenKind == "event" && s.thenKind == "state" {
        switch (s.whenElements->last, lifecycleValue(s.thenValues, ~field)) {
        | (Some(event), Some(value)) =>
          if Array.length(s.given) == 0 || fold(s.given) != value {
            record(event.name, value, ~title=s.title)
          }
        | _ => ()
        }
      }
    )

    if map->Dict.keysToArray->Array.length != before {
      changed := true
    }
  }

  map
}

// ── Rule 2 and 3: the relation a command's own scenarios describe ───────────

type outcome = Emitted | NoChange | Refused

type observation = {
  title: string,
  command: string,
  from: string,
  outcome: outcome,
  to: string,
}

type derivedCommand = {
  component: string,
  command: string,
  /** States a scenario shows the command taking effect from — the from-set. */
  allowedStates: array<string>,
  /** States a scenario exercises where the command has no effect: refused, or
      accepted and silent. Kept separately because it is what turns a declared
      state the corpus disagrees with into a contradiction rather than a gap. */
  inertStates: array<string>,
  /** Where the edges land. A relation, not a single value: a command observed
      landing in two states is the signal that the published `targetState` cannot
      carry the model, and that is worth seeing before spending the change. */
  targets: array<string>,
  /** `""` where the corpus cannot say. Without a lifecycle map every history
      folds to "no row", which would make every command in the plugin look like
      it creates one — a confident wrong answer where the honest one is silence. */
  level: string,
  scenarios: int,
}

let outcomeOf = (s: scenario): outcome =>
  switch s.thenKind {
  | "event" => Emitted
  // `thenNoEvent`, and the empty `then` an older sidecar wrote for the same
  // thing. Accepted, and nothing happened.
  | "noEvent" | "" => NoChange
  | "error" => Refused
  // A `then` this harvest has no reading for — a side effect, a published
  // command. Not an effect on this row either way.
  | _ => NoChange
  }

let valueOf = (values: array<(string, JSON.t)>, ~field: string): option<JSON.t> =>
  values->Array.find(((name, _)) => name == field)->Option.map(((_, v)) => v)

/** Whether a setup event is about the row the command names.

    A slice's `given` names whatever the decision needs, which for a DCB slice is
    routinely a different entity — a synced product, another customer's order. It
    also, quite legitimately, names *this* entity's other rows: "placing a second
    order" sets up `OrderPlaced(o1)` and then places `o2`. Folding either into
    this row's state is how a scenario about a fresh row gets read as a scenario
    about an existing one, and it is the difference between a command reported as
    creating and the same command reported as guarding.

    An event that does not carry the id field at all is kept. That is the normal
    shape for an aggregate, whose events identify their instance by the stream
    they are in rather than by a field, and dropping them would empty every
    aggregate's history. */
let sameRow = (event: element, ~idField: option<string>, ~idValue: option<JSON.t>): bool =>
  switch (idField, idValue) {
  | (Some(field), Some(wanted)) =>
    switch event.values->valueOf(~field) {
    | Some(actual) => actual == wanted
    | None => true
    }
  | _ => true
  }

let observe = (
  ~scenarios: array<scenario>,
  ~map: dict<string>,
  ~idFieldFor: string => option<string>,
): array<observation> => {
  let fold = (events: array<element>) =>
    events->Array.reduce(noRow, (current, event) =>
      switch map->Dict.get(event.name) {
      | Some(value) => value
      | None => current
      }
    )

  scenarios->Array.filterMap(s =>
    switch s.whenElements->Array.get(0) {
    | Some(command) if s.whenKind == "command" =>
      let idField = idFieldFor(command.name)
      let idValue = idField->Option.flatMap(field => command.values->valueOf(~field))
      let history = s.given->Array.filter(e => e->sameRow(~idField, ~idValue))
      let from = fold(history)
      let outcome = outcomeOf(s)
      Some({
        title: s.title,
        command: command.name,
        from,
        outcome,
        to: outcome == Emitted ? fold(Array.concat(history, s.thenElements)) : from,
      })
    | _ => None
    }
  )
}

let deriveCommands = (
  ~component: string,
  ~observations: array<observation>,
  ~labelled: bool,
): array<derivedCommand> => {
  let names = sortedUnique(observations->Array.map(o => o.command))
  names->Array.map(command => {
    let mine = observations->Array.filter(o => o.command == command)
    let effective = mine->Array.filter(o => o.outcome == Emitted)
    {
      component,
      command,
      allowedStates: sortedUnique(
        effective->Array.filterMap(o => o.from == noRow ? None : Some(o.from)),
      ),
      inertStates: sortedUnique(
        mine->Array.filterMap(o =>
          o.outcome == Emitted || o.from == noRow ? None : Some(o.from)
        ),
      ),
      targets: sortedUnique(
        effective->Array.filterMap(o => o.to == o.from || o.to == noRow ? None : Some(o.to)),
      ),
      // A command whose every successful scenario starts from no row is creating
      // one. This is what the published metadata guesses at today from the
      // command's name stem, which misreads `Enroll`, `Provision`, `Onboard`.
      level: switch (labelled, Array.length(effective)) {
      | (false, _) | (_, 0) => ""
      | (true, _) => effective->Array.every(o => o.from == noRow) ? "Collection" : "Instance"
      },
      scenarios: Array.length(mine),
    }
  })
}

// ── The three verdicts ──────────────────────────────────────────────────────

type finding = {
  severity: string, // "contradicted" | "unverified" | "undeclared" | "level" | "ambiguous"
  plugin: string,
  /** The component the finding is about: the writable whose switch made the
      claim, or — for `ambiguous` — the view whose corpus disagrees with itself.
      Kept beside `message` rather than only inside it, because a consumer has to
      find the file before it can say anything about it. */
  component: string,
  /** Empty for a finding that is about the component rather than one command. */
  command: string,
  /** The lifecycle state(s) the finding names, where it names any. This is what
      a generated scenario's `given` has to fold to, so it is the one part of the
      sentence a consumer cannot re-derive. */
  states: array<string>,
  message: string,
}

/** A corpus the walk can only partly read.

    Several DSL verbs record their `given` and nothing else — `thenIssuesCommand`,
    `whenReacts`, `whenPublishedThrough` and the rest — and so does a readable
    verb handed a let-bound value rather than a literal, since the sidecar records
    the constructor application it can see. Either way the scenario reaches here
    with an empty `when`, and the walk has nothing to exercise.

    Counted per component and published, because the distinction a consumer MUST
    keep is "not covered" against "not analysed": a slice with twenty thorough
    scenarios and no readable `when` is not an untested slice, and rendering it as
    one is the fastest way to teach people to ignore the warning. */
type opaque = {
  plugin: string,
  component: string,
  path: string,
  scenarios: int,
  /** Of those, the ones whose `when` the sidecar recorded as empty. */
  unreadable: int,
}

/** Everything a declared command claims, reported as unverified.

    Reached two ways, and both are the same statement: a command with no
    scenarios at all, and a command whose corpus cannot be labelled because its
    views declare no lifecycle. In neither case has anything ever exercised what
    the declaration claims, which is exactly what a warning is for. */
let allUnverified = (
  ~cmd: declaredCommand,
  ~add: (string, array<string>, string) => unit,
  ~why: string,
): unit => {
  switch cmd.allowedStates {
  | Some(states) if Array.length(states) > 0 =>
    add("unverified", states, `the switch names ${states->Array.join(", ")}, and ${why}`)
  | _ => ()
  }
  switch cmd.targetState {
  | Some(target) => add("unverified", [target], `the switch targets "${target}", and ${why}`)
  | None => ()
  }
}

let compare = (
  ~plugin: string,
  ~writable: declaredWritable,
  ~derived: derivedCommand,
  ~findings: array<finding>,
): unit => {
  let where = `${plugin}/${writable.name}.${derived.command}`
  let add = (severity, states, message) =>
    findings
    ->Array.push({
      severity,
      plugin,
      component: writable.name,
      command: derived.command,
      states,
      message: `${where}: ${message}`,
    })
    ->ignore

  let declared = writable.commands->Array.find(c => c.command == derived.command)

  switch declared {
  | None => ()
  | Some(cmd) =>
    switch cmd.allowedStates {
    // "Legal in every state", declared. A scenario showing the command taking
    // effect somewhere agrees with that rather than narrowing it — the corpus
    // covers the states somebody wrote a scenario for, and silence about the
    // rest is not refusal. What DOES refute the claim is a state the command was
    // exercised in and did nothing: that is the switch and the behaviour
    // disagreeing about the same row.
    | None if cmd.allowedStatesSource == Some("unrestricted") =>
      derived.inertStates->Array.forEach(state =>
        add(
          "contradicted",
          [state],
          `the switch declares it legal in every state, and a scenario from "${state}" ` ++
          `shows it refused or producing nothing`,
        )
      )
    | None =>
      if Array.length(derived.allowedStates) > 0 {
        add(
          "undeclared",
          derived.allowedStates,
          `scenarios show it taking effect from ${derived.allowedStates->Array.join(", ")}, ` ++
          `and it declares no edge`,
        )
      }
    | Some(states) =>
      states->Array.forEach(state =>
        if derived.allowedStates->Array.includes(state) {
          ()
        } else if derived.inertStates->Array.includes(state) {
          add(
            "contradicted",
            [state],
            `the switch names "${state}", and a scenario from "${state}" shows it ` ++
            `refused or producing nothing`,
          )
        } else {
          add("unverified", [state], `the switch names "${state}", and no scenario starts there`)
        }
      )
      derived.allowedStates->Array.forEach(state =>
        if !(states->Array.includes(state)) {
          add(
            "contradicted",
            [state],
            `a scenario shows it taking effect from "${state}", which its declared ` ++
            `from-set (${states->Array.join(", ")}) excludes`,
          )
        }
      )
      if Array.length(states) > 0 && Array.length(derived.allowedStates) == 0 {
        add(
          "unverified",
          states,
          `the switch declares ${Array.length(states)->Int.toString} state(s) and ` ++
          `no scenario shows the command taking effect anywhere`,
        )
      }
    }

    switch (cmd.targetState, derived.targets) {
    | (None, _) => ()
    | (Some(target), []) =>
      add("unverified", [target], `the switch targets "${target}", and no scenario shows an edge`)
    | (Some(target), observed) =>
      if !(observed->Array.includes(target)) {
        add(
          "contradicted",
          [target],
          `the switch targets "${target}", and scenarios land in ` ++
          `${observed->Array.join(", ")}`,
        )
      }
      observed->Array.forEach(state =>
        if state != target {
          add(
            "contradicted",
            [target, state],
            `the switch targets "${target}", and a scenario lands in "${state}" — ` ++
            `the published targetState carries one state, so this edge cannot be expressed`,
          )
        }
      )
    }

    if derived.level != "" && cmd.level != "" && derived.level != cmd.level {
      add(
        "level",
        [],
        `scenarios make it ${derived.level}-level; the published metadata says ${cmd.level}`,
      )
    }
  }
}

// ── Per-app run ─────────────────────────────────────────────────────────────

/** A plugin is a directory with both a composition root and a corpus. Found
    rather than listed so a new app, or a new plugin in one, is covered without
    this file being edited. */
let pluginDirsIn = (exampleDir: string): array<string> =>
  switch NodeFs.readdirSync(exampleDir, {withFileTypes: true}) {
  | entries =>
    entries
    ->Array.filter(e => e->NodeFs.isDirectory)
    ->Array.map(e => NodePath.join([exampleDir, e->NodeFs.direntName]))
    ->Array.filter(dir =>
      NodePath.join([dir, "src", "Plugin.res"])->NodeFs.existsSync &&
        NodePath.join([dir, "tests"])->NodeFs.existsSync
    )
  | exception _ => []
  }

/** The apps to check: every `--root`, or — with none — every subdirectory of
    `<cwd>/examples`, which is what this repository's own gate passes nothing to
    get. A `--root` is resolved against the working directory so a relative one
    means what the person who typed it meant, and labelled by its basename so the
    prose reads the same either way. */
// `--root` typed with nothing usable after it — `--root --json`, or a trailing
// `--root`. Falling back to the default scan below would check the whole examples
// tree while the person believed they had narrowed it to one app, so refuse here
// rather than answer a question nobody asked.
if NodeProcess.argv->Array.includes("--root") && Array.length(flagValues("--root")) == 0 {
  Console.error("--root needs a directory after it")
  NodeProcess.exit(1)
}

let roots: array<appRoot> = switch flagValues("--root") {
| [] =>
  switch NodeFs.readdirSync(examplesDir, {withFileTypes: true}) {
  | entries =>
    entries
    ->Array.filter(e => e->NodeFs.isDirectory)
    ->Array.map(e => e->NodeFs.direntName)
    ->Array.toSorted(String.compare)
    ->Array.map(name => {label: name, dir: NodePath.join([examplesDir, name])})
  | exception _ => []
  }
| given =>
  given->Array.map(given => {
    let dir = NodePath.resolve([given])
    {label: NodePath.basename(dir), dir}
  })
}

/** Sidecar paths that describe a queryable, and those that describe a writable.
    Told apart by the folder the source sits in, which is the same vocabulary the
    plugin generator and the PPX already read a component's kind from. */
let isViewPath = (path: string) =>
  ["/ReadModel/", "/ReadModelStream/", "/StateViewSlice/", "/StateViewSliceStream/"]->Array.some(
    seg => path->String.includes(seg),
  )

let isWritablePath = (path: string) =>
  ["/Aggregate/", "/StateChangeSlice/"]->Array.some(seg => path->String.includes(seg))

let runPlugin = async (
  ~plugin: string,
  ~pluginDir: string,
  ~findings: array<finding>,
  ~opaque: array<opaque>,
): result<array<derivedCommand>, string> =>
  switch await readDeclared(~pluginDir) {
  | Error(msg) => Error(msg)
  | Ok(declared) =>
      let corpora =
        filesUnder(NodePath.join([pluginDir, "tests"]), ~suffix=".gwt.json")->Array.filterMap(
          readCorpus,
        )

      // Every corpus, not only the ones the walk goes on to use: the kinds that
      // are unreadable in full — extension points, automation and translation
      // slices — are exactly the ones that sit outside the view/writable folders
      // below, and they are the ones a coverage UI would otherwise slander.
      corpora->Array.forEach(c => {
        let unreadable = c.scenarios->Array.filter(s => Array.length(s.whenElements) == 0)
        if Array.length(unreadable) > 0 {
          opaque
          ->Array.push({
            plugin,
            component: c.component,
            path: c.path,
            scenarios: Array.length(c.scenarios),
            unreadable: Array.length(unreadable),
          })
          ->ignore
        }
      })

      // Views first: a command's history cannot be labelled until the events in
      // it have somewhere to land.
      let mapsByView = Dict.make()
      let ambiguities = []
      corpora->Array.forEach(c =>
        if isViewPath(c.path) {
          switch declared.views->Array.find(v => v.name == c.component) {
          | Some({lifecycleField: Some(field)}) =>
            mapsByView->Dict.set(
              c.component,
              lifecycleMapFor(~scenarios=c.scenarios, ~field, ~ambiguities, ~view=c.component),
            )
          // A view with no lifecycle field labels nothing, and that is ordinary
          // — most views have no lifecycle at all.
          | _ => ()
          }
        }
      )
      ambiguities->Array.forEach(((view, message)) =>
        findings
        ->Array.push({
          severity: "ambiguous",
          plugin,
          component: view,
          command: "",
          states: [],
          message,
        })
        ->ignore
      )

      let derived = []
      corpora->Array.forEach(c =>
        if isWritablePath(c.path) {
          switch declared.writables->Array.find(w => w.name == c.component) {
          | None => ()
          | Some(writable) =>
            // The union of the maps of every view this writable feeds. A union
            // rather than a single view for the reason the platform's own name
            // check uses one: a slice feeding two views is not claiming which of
            // them a state belongs to.
            let map = Dict.make()
            writable.linkedViews->Array.forEach(view =>
              switch mapsByView->Dict.get(view) {
              | Some(m) => m->Dict.forEachWithKey((value, event) => map->Dict.set(event, value))
              | None => ()
              }
            )
            let labelled = Array.length(map->Dict.keysToArray) > 0
            let idFieldFor = command =>
              writable.commands
              ->Array.find(c => c.command == command)
              ->Option.flatMap(c => c.aggregateIdField)
            let observations = observe(~scenarios=c.scenarios, ~map, ~idFieldFor)
            let commands = deriveCommands(~component=c.component, ~observations, ~labelled)

            commands->Array.forEach(d => {
              // Without a lifecycle map every history folds to "no row", so
              // there is nothing to confirm a claim against and nothing to
              // contradict it with. Reporting the claim as unverified is the
              // honest answer; running the comparison would manufacture
              // contradictions out of a missing map.
              if labelled {
                compare(~plugin, ~writable, ~derived=d, ~findings)
              }
              derived->Array.push(d)
            })

            let why = labelled
              ? "no scenario exercises the command"
              : `${writable.linkedViews->Array.join(", ")} declares no lifecycle field, so its ` ++
                `scenarios cannot be labelled`
            writable.commands->Array.forEach(cmd =>
              if labelled && commands->Array.some(d => d.command == cmd.command) {
                ()
              } else {
                allUnverified(~cmd, ~why, ~add=(severity, states, message) =>
                  findings
                  ->Array.push({
                    severity,
                    plugin,
                    component: writable.name,
                    command: cmd.command,
                    states,
                    message: `${plugin}/${writable.name}.${cmd.command}: ${message}`,
                  })
                  ->ignore
                )
              }
            )
          }
        }
      )
      Ok(derived)
  }

// ── The golden ──────────────────────────────────────────────────────────────

/** The derived model, written out so a change to it shows up as a reviewable
    diff in the pull request that causes it — the same contract the GraphQL
    goldens hold. A rule that stops holding for a corpus it was never validated
    against becomes a line in a diff instead of a silent change of answer. */
let byComponentThenCommand = (derived: array<derivedCommand>): array<derivedCommand> =>
  derived->Array.toSorted((a, b) =>
    switch String.compare(a.component, b.component) {
    | 0. => String.compare(a.command, b.command)
    | c => c
    }
  )

let goldenJson = (derived: array<derivedCommand>): string => {
  let entries =
    derived
    ->byComponentThenCommand
    ->Array.map(d =>
      JSON.Encode.object(
        Dict.fromArray([
          ("component", JSON.Encode.string(d.component)),
          ("command", JSON.Encode.string(d.command)),
          ("level", JSON.Encode.string(d.level)),
          ("allowedStates", JSON.Encode.array(d.allowedStates->Array.map(JSON.Encode.string))),
          ("targets", JSON.Encode.array(d.targets->Array.map(JSON.Encode.string))),
          ("scenarios", JSON.Encode.int(d.scenarios)),
        ]),
      )
    )
  JSON.stringify(JSON.Encode.array(entries), ~space=2) ++ "\n"
}

let goldenPath = (~root: appRoot) => NodePath.join([root.dir, "schema", "lifecycle-model.json"])

// ── The machine-readable run ────────────────────────────────────────────────

/** The same run as the prose, as fields.

    Three things travel here that the prose does not carry, each because a
    consumer cannot recover it from the sentence:

    - `states` on a finding — the state a generated scenario's `given` has to
      fold to. The sentence names it; parsing it back out is the thing this
      exists to avoid.
    - `inertStates` on a command — internal to the check until now. With it, a
      state in neither `allowedStates` nor `inertStates` is one no scenario has
      ever exercised, which is a sharper "missing scenario" than a verdict.
    - `opaque` — the corpora the walk cannot read, so a consumer can say "not
      analysed" where it would otherwise say "not covered".

    `str` is the schema's own version, bumped when a consumer would have to
    change. */
let reportJson = (
  ~findings: array<finding>,
  ~opaque: array<opaque>,
  ~derived: array<(string, derivedCommand)>,
  ~failures: array<string>,
): string => {
  let strs = xs => JSON.Encode.array(xs->Array.map(JSON.Encode.string))
  let obj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

  let findingJson = (f: finding) =>
    obj([
      ("verdict", JSON.Encode.string(f.severity)),
      ("plugin", JSON.Encode.string(f.plugin)),
      ("component", JSON.Encode.string(f.component)),
      ("command", JSON.Encode.string(f.command)),
      ("states", strs(f.states)),
      ("message", JSON.Encode.string(f.message)),
    ])

  let commandJson = ((plugin, d): (string, derivedCommand)) =>
    obj([
      ("plugin", JSON.Encode.string(plugin)),
      ("component", JSON.Encode.string(d.component)),
      ("command", JSON.Encode.string(d.command)),
      ("level", JSON.Encode.string(d.level)),
      ("allowedStates", strs(d.allowedStates)),
      ("inertStates", strs(d.inertStates)),
      ("targets", strs(d.targets)),
      ("scenarios", JSON.Encode.int(d.scenarios)),
    ])

  let opaqueJson = (o: opaque) =>
    obj([
      ("plugin", JSON.Encode.string(o.plugin)),
      ("component", JSON.Encode.string(o.component)),
      ("path", JSON.Encode.string(o.path)),
      ("scenarios", JSON.Encode.int(o.scenarios)),
      ("unreadable", JSON.Encode.int(o.unreadable)),
    ])

  JSON.stringify(
    obj([
      ("version", JSON.Encode.int(1)),
      ("findings", JSON.Encode.array(findings->Array.map(findingJson))),
      ("commands", JSON.Encode.array(derived->Array.map(commandJson))),
      ("opaque", JSON.Encode.array(opaque->Array.map(opaqueJson))),
      ("unreadable", strs(failures)),
    ]),
    ~space=2,
  ) ++ "\n"
}

// ── The value structure assembly reads ──────────────────────────────────────

/** The same derivation as a committed ReScript value, so `buildStructure` gets
    the model as data. It cannot read the corpus itself: tests are not published
    with a plugin package, and metadata that read them would make deleting a test
    file change a production command menu.

    Only what the structure resolves an edge from travels — a scenario count says
    nothing to a menu, and belongs in the golden a person reads. A command the
    corpus could label nothing about is left out for the same reason: an entry
    that resolves to no level, no from-set and no target is read exactly as an
    absent one, and writing it out would make most of the file say nothing. */
let modelSource = (~plugin: string, ~derived: array<derivedCommand>): string => {
  let saysSomething = (d: derivedCommand) =>
    d.level != "" || Array.length(d.allowedStates) > 0 || Array.length(d.targets) > 0
  let quoted = (xs: array<string>) =>
    "[" ++ xs->Array.map(s => `"${s}"`)->Array.join(", ") ++ "]"
  let entries = derived->Array.filter(saysSomething)->byComponentThenCommand->Array.map(d => {
    // Omitted rather than written as an absent value: `level` is an optional
    // field, and a corpus that could not label this command's histories has
    // nothing to say about it.
    let level = switch d.level {
    | "Collection" | "Instance" => `level: Reventless.Plugin.${d.level}, `
    | _ => ""
    }
    `  {component: "${d.component}", command: "${d.command}", ${level}` ++
    `allowedStates: ${quoted(d.allowedStates)}, targets: ${quoted(d.targets)}},`
  })
  Array.flat([
    [
      `// AUTO-GENERATED — do not edit. Run \`pnpm run check:lifecycle:update\` to update.`,
      `//`,
      `// What ${plugin}'s own given/when/then scenarios say about each command: the`,
      `// states one shows it taking effect from, the states those land in, and whether`,
      `// it brings a row into existence. \`Plugin_Structure\` prefers this to the`,
      `// \`@transition\` annotation where it says anything, and falls back to the`,
      `// annotation where it is silent.`,
      ``,
      `let model: array<Reventless.Plugin.derivedEdge> = [`,
    ],
    entries,
    ["]", ""],
  ])->Array.join("\n")
}

let modelPath = (~pluginDir: string) => NodePath.join([pluginDir, "src", "LifecycleModel.res"])

/** Rewrite under `--update`, and when nothing is there yet so a plugin harvested
    for the first time is not a failure. Otherwise compare, and record the drift:
    a derivation that moved belongs in the diff of the change that moved it. */
let writeOrCompare = (~path: string, ~actual: string, ~label: string, ~drifted: array<string>) => {
  let existed = path->NodeFs.existsSync
  if update || !existed {
    NodeFs.writeFileSync(path, actual)
    Console.log(`${existed ? "updated" : "wrote"} ${label}`)
  } else if path->NodeFs.readFileSync != actual {
    drifted->Array.push(label)->ignore
    Console.error(`\ndrift in ${label}`)
  }
}

// ── Entry point ─────────────────────────────────────────────────────────────

let main = async () => {
  let findings = []
  let opaque = []
  let failures = []
  let drifted = []
  let allDerived = []

  let allPluginDirs = roots->Array.flatMap(root => pluginDirsIn(root.dir))

  // A run that found nothing to check is a mistyped `--root` far more often than
  // an app with no plugins, and reporting "ok" for it is how that typo survives.
  if Array.length(allPluginDirs) == 0 {
    Console.error(
      `no plugins found under ${roots->Array.map(r => r.dir)->Array.join(", ")} — a plugin is a ` ++
      `directory with both src/Plugin.res and tests/`,
    )
    NodeProcess.exit(1)
  }

  switch reuseSidecars
    ? checkSidecars(~pluginDirs=allPluginDirs)
    : emitSidecars(~pluginDirs=allPluginDirs) {
  | Error(msg) =>
    Console.error(msg)
    NodeProcess.exit(1)
  | Ok() => ()
  }

  // The build above is the working directory's, so a `--root` elsewhere can come
  // back successful having emitted nothing for the tree actually being checked.
  // An empty corpus reads as every edge unverified — a warning — so without this
  // the run would pass having checked nothing, which is the one outcome worth
  // refusing outright.
  if !hasCorpus(~pluginDirs=allPluginDirs) {
    Console.error(
      `no scenario sidecar exists under ${roots->Array.map(r => r.dir)->Array.join(", ")} after ` ++
      `the build. Build that tree with REVENTLESS_EMIT_SIDECAR=1 and pass --reuse-sidecars.`,
    )
    NodeProcess.exit(1)
  }

  for i in 0 to Array.length(roots) - 1 {
    switch roots->Array.get(i) {
    | None => ()
    | Some(root) =>
      let example = root.label
      let exampleDir = root.dir
      let derived = []
      let dirs = pluginDirsIn(exampleDir)

      for j in 0 to Array.length(dirs) - 1 {
        switch dirs->Array.get(j) {
        | None => ()
        | Some(pluginDir) =>
          let plugin = NodePath.basename(pluginDir)
          let qualified = `${example}/${plugin}`
          switch await runPlugin(~plugin=qualified, ~pluginDir, ~findings, ~opaque) {
          | Ok(commands) =>
            commands->Array.forEach(c => {
              derived->Array.push(c)
              allDerived->Array.push((qualified, c))
            })
            if !json {
              writeOrCompare(
                ~path=modelPath(~pluginDir),
                ~actual=modelSource(~plugin, ~derived=commands),
                ~label=`${example}/${plugin}/src/LifecycleModel.res`,
                ~drifted,
              )
            }
          | Error(msg) => failures->Array.push(`${example}/${plugin}: ${msg}`)->ignore
          }
        }
      }

      if Array.length(dirs) > 0 && !json {
        let dir = NodePath.join([exampleDir, "schema"])
        if !(dir->NodeFs.existsSync) {
          NodeFs.mkdirSync(dir, {recursive: true})
        }
        writeOrCompare(
          ~path=goldenPath(~root),
          ~actual=goldenJson(derived),
          ~label=`${example}/schema/lifecycle-model.json`,
          ~drifted,
        )
        Console.log(
          `ok ${example} — ${Array.length(derived)->Int.toString} commands derived from scenarios`,
        )
      }
    }
  }

  let of_ = severity => findings->Array.filter(f => f.severity == severity)
  let contradicted = of_("contradicted")

  if json {
    Console.log(reportJson(~findings, ~opaque, ~derived=allDerived, ~failures))
  } else {
    ["contradicted", "unverified", "undeclared", "level", "ambiguous"]->Array.forEach(severity => {
      let group = of_(severity)
      if Array.length(group) > 0 {
        Console.log(`\n${severity} (${Array.length(group)->Int.toString})`)
        group->Array.forEach(f => Console.log(`  ${f.message}`))
      }
    })
  }

  if Array.length(failures) > 0 && !json {
    Console.error(`\ncould not read:`)
    failures->Array.forEach(f => Console.error(`  ${f}`))
  }

  if Array.length(drifted) > 0 {
    Console.error(
      `\n${Array.length(drifted)->Int.toString} lifecycle artifact(s) changed. If the change is ` ++
      `intended, re-run with --update and commit them alongside the change that moved them.`,
    )
  }

  // Warnings do not fail the build: an unverified edge is a corpus that has not
  // caught up, which is a thing to work on rather than a thing to stop for. A
  // contradiction is a disagreement between two statements about the same
  // command, and one of them is wrong.
  if Array.length(contradicted) > 0 || Array.length(drifted) > 0 || Array.length(failures) > 0 {
    NodeProcess.exit(1)
  }
}

let _ = main()

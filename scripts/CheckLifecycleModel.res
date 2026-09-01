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

Report-only: nothing published changes. Contradictions fail the run; unverified
edges are warnings, counted so a corpus getting thinner is visible.

Usage:

```
pnpm run check:lifecycle           # fail on contradictions or golden drift
pnpm run check:lifecycle:update    # rewrite the goldens
pnpm run check:lifecycle -- --reuse-sidecars   # read what a prior build wrote
```
*/

// ── Where things live ───────────────────────────────────────────────────────

let repoRoot = NodeProcess.cwd()
let examplesDir = NodePath.join([repoRoot, "examples"])
let update = NodeProcess.argv->Array.includes("--update")

/** Read the sidecars a prior build already wrote instead of driving one. CI's
    build step sets `REVENTLESS_EMIT_SIDECAR=1`, so by the time this runs the
    corpus is on disk; a second pass over a warm tree buys nothing and costs the
    multi-root build chain's habit of cleaning artifacts outside the root it is
    building, which lands intermittently on a stale `.cmi`. */
let reuseSidecars = NodeProcess.argv->Array.includes("--reuse-sidecars")

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
let checkSidecars = (~pluginDirs: array<string>): result<unit, string> =>
  gwtSources(~pluginDirs)->Array.some(f => f->sidecarOf->NodeFs.existsSync)
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
    leaves the tree exactly as it found it. */
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
  ~ambiguities: array<string>,
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
      ->Array.push(
        `${view}: ${event} is projected as both "${existing}" and "${value}" ` ++
        `(seen in "${title}") — the harvest keeps "${existing}"`,
      )
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
  severity: string, // "contradicted" | "unverified" | "undeclared" | "ambiguous"
  plugin: string,
  message: string,
}

/** Everything a declared command claims, reported as unverified.

    Reached two ways, and both are the same statement: a command with no
    scenarios at all, and a command whose corpus cannot be labelled because its
    views declare no lifecycle. In neither case has anything ever exercised what
    the declaration claims, which is exactly what a warning is for. */
let allUnverified = (~cmd: declaredCommand, ~add: (string, string) => unit, ~why: string): unit => {
  switch cmd.allowedStates {
  | Some(states) if Array.length(states) > 0 =>
    add("unverified", `the switch names ${states->Array.join(", ")}, and ${why}`)
  | _ => ()
  }
  switch cmd.targetState {
  | Some(target) => add("unverified", `the switch targets "${target}", and ${why}`)
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
  let add = (severity, message) =>
    findings->Array.push({severity, plugin, message: `${where}: ${message}`})->ignore

  let declared = writable.commands->Array.find(c => c.command == derived.command)

  switch declared {
  | None => ()
  | Some(cmd) =>
    switch cmd.allowedStates {
    | None =>
      if Array.length(derived.allowedStates) > 0 {
        add(
          "undeclared",
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
            `the switch names "${state}", and a scenario from "${state}" shows it ` ++
            `refused or producing nothing`,
          )
        } else {
          add("unverified", `the switch names "${state}", and no scenario starts there`)
        }
      )
      derived.allowedStates->Array.forEach(state =>
        if !(states->Array.includes(state)) {
          add(
            "contradicted",
            `a scenario shows it taking effect from "${state}", which its declared ` ++
            `from-set (${states->Array.join(", ")}) excludes`,
          )
        }
      )
      if Array.length(states) > 0 && Array.length(derived.allowedStates) == 0 {
        add(
          "unverified",
          `the switch declares ${Array.length(states)->Int.toString} state(s) and ` ++
          `no scenario shows the command taking effect anywhere`,
        )
      }
    }

    switch (cmd.targetState, derived.targets) {
    | (None, _) => ()
    | (Some(target), []) =>
      add("unverified", `the switch targets "${target}", and no scenario shows an edge`)
    | (Some(target), observed) =>
      if !(observed->Array.includes(target)) {
        add(
          "contradicted",
          `the switch targets "${target}", and scenarios land in ` ++
          `${observed->Array.join(", ")}`,
        )
      }
      observed->Array.forEach(state =>
        if state != target {
          add(
            "contradicted",
            `the switch targets "${target}", and a scenario lands in "${state}" — ` ++
            `the published targetState carries one state, so this edge cannot be expressed`,
          )
        }
      )
    }

    if derived.level != "" && cmd.level != "" && derived.level != cmd.level {
      add(
        "level",
        `scenarios make it ${derived.level}-level; the published metadata says ${cmd.level}`,
      )
    }
  }
}

// ── Per-example run ─────────────────────────────────────────────────────────

/** A plugin is a directory with both a composition root and a corpus. Found
    rather than listed so a new example, or a new plugin in one, is covered
    without this file being edited. */
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

let examples = switch NodeFs.readdirSync(examplesDir, {withFileTypes: true}) {
| entries =>
  entries
  ->Array.filter(e => e->NodeFs.isDirectory)
  ->Array.map(e => e->NodeFs.direntName)
  ->Array.toSorted(String.compare)
| exception _ => []
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

let runPlugin = async (~plugin: string, ~pluginDir: string, ~findings: array<finding>): result<
  array<derivedCommand>,
  string,
> =>
  switch await readDeclared(~pluginDir) {
  | Error(msg) => Error(msg)
  | Ok(declared) =>
      let corpora =
        filesUnder(NodePath.join([pluginDir, "tests"]), ~suffix=".gwt.json")->Array.filterMap(
          readCorpus,
        )

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
      ambiguities->Array.forEach(message =>
        findings->Array.push({severity: "ambiguous", plugin, message})->ignore
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
                allUnverified(~cmd, ~why, ~add=(severity, message) =>
                  findings
                  ->Array.push({
                    severity,
                    plugin,
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
let goldenJson = (derived: array<derivedCommand>): string => {
  let entries =
    derived
    ->Array.toSorted((a, b) =>
      switch String.compare(a.component, b.component) {
      | 0. => String.compare(a.command, b.command)
      | c => c
      }
    )
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

let goldenPath = (~example: string) =>
  NodePath.join([examplesDir, example, "schema", "lifecycle-model.json"])

// ── Entry point ─────────────────────────────────────────────────────────────

let main = async () => {
  let findings = []
  let failures = []
  let drifted = []

  let allPluginDirs =
    examples->Array.flatMap(example => pluginDirsIn(NodePath.join([examplesDir, example])))

  switch reuseSidecars
    ? checkSidecars(~pluginDirs=allPluginDirs)
    : emitSidecars(~pluginDirs=allPluginDirs) {
  | Error(msg) =>
    Console.error(msg)
    NodeProcess.exit(1)
  | Ok() => ()
  }

  for i in 0 to Array.length(examples) - 1 {
    switch examples->Array.get(i) {
    | None => ()
    | Some(example) =>
      let exampleDir = NodePath.join([examplesDir, example])
      let derived = []
      let dirs = pluginDirsIn(exampleDir)

      for j in 0 to Array.length(dirs) - 1 {
        switch dirs->Array.get(j) {
        | None => ()
        | Some(pluginDir) =>
          let plugin = NodePath.basename(pluginDir)
          switch await runPlugin(~plugin=`${example}/${plugin}`, ~pluginDir, ~findings) {
          | Ok(commands) => commands->Array.forEach(c => derived->Array.push(c))
          | Error(msg) => failures->Array.push(`${example}/${plugin}: ${msg}`)->ignore
          }
        }
      }

      if Array.length(dirs) > 0 {
        let dir = NodePath.join([exampleDir, "schema"])
        if !(dir->NodeFs.existsSync) {
          NodeFs.mkdirSync(dir, {recursive: true})
        }
        let path = goldenPath(~example)
        let actual = goldenJson(derived)
        let existed = path->NodeFs.existsSync
        if update || !existed {
          NodeFs.writeFileSync(path, actual)
          Console.log(`${existed ? "updated" : "wrote"} ${example}/schema/lifecycle-model.json`)
        } else if path->NodeFs.readFileSync == actual {
          Console.log(
            `ok ${example} — ${Array.length(derived)->Int.toString} commands derived from scenarios`,
          )
        } else {
          drifted->Array.push(example)->ignore
          Console.error(`\ndrift in ${example}/schema/lifecycle-model.json`)
        }
      }
    }
  }

  let of_ = severity => findings->Array.filter(f => f.severity == severity)
  let contradicted = of_("contradicted")

  ["contradicted", "unverified", "undeclared", "level", "ambiguous"]->Array.forEach(severity => {
    let group = of_(severity)
    if Array.length(group) > 0 {
      Console.log(`\n${severity} (${Array.length(group)->Int.toString})`)
      group->Array.forEach(f => Console.log(`  ${f.message}`))
    }
  })

  if Array.length(failures) > 0 {
    Console.error(`\ncould not read:`)
    failures->Array.forEach(f => Console.error(`  ${f}`))
  }

  if Array.length(drifted) > 0 {
    Console.error(
      `\n${Array.length(drifted)->Int.toString} lifecycle model(s) changed. If the change is ` ++
      `intended, run\n  pnpm run check:lifecycle:update\nand commit the goldens alongside the ` ++
      `change that moved them.`,
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

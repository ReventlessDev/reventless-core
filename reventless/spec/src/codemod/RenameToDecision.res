// Move an application from the write-side logic module's former name, *behavior*,
// to *decision*: `X_Behavior.res` becomes `X_Decision.res`, and the spellings that
// name it in `.res` sources follow.
//
// The framework accepts none of the former spellings, so a consumer's bump is this
// command plus a build. Everything is planned before anything changes: a target
// that already exists stops the run with nothing touched.

let usage = `Usage: reventless-rename-to-decision [--dry-run] [<dir>]

  <dir>      where to start; the default is the current directory
  --dry-run  print what would change, change nothing

  Renames every *_Behavior.res to *_Decision.res (git mv inside a git work tree,
  with its compiled output beside it), and in every .res and .resi file:
  @@reventless.behavior -> @@reventless.decision, Behavior_GWT -> Decision_GWT,
  Reventless.Behavior -> Reventless.Decision, thenRefused -> thenForbidden, and
  <Spec>_Behavior -> <Spec>_Decision. Skips node_modules and lib.`

type args = {dir: string, dryRun: bool}

let parseArgs = (argv: array<string>): result<args, string> =>
  CliArgs.parse(~bools=["dry-run"], argv)
  ->Result.flatMap(a => a->CliArgs.atMost(1))
  ->Result.map(a => {
    dir: a->CliArgs.positionals->Array.get(0)->Option.getOr("."),
    dryRun: a->CliArgs.bool("dry-run"),
  })

let cli: CliArgs.cli<args> = {bin: "reventless-rename-to-decision", usage, parse: parseArgs}

// ── The text ─────────────────────────────────────────────────────────────────

// In order: the qualified forms before the bare module names they contain.
let replacements: array<(RegExp.t, string)> = [
  (/@@reventless\.behavior\b/g, "@@reventless.decision"),
  (/\bBehavior_GWT\.BehaviorSpec\b/g, "Decision_GWT.DecisionSpec"),
  (/\bBehavior_GWT\.Behavior\b/g, "Decision_GWT.Decision"),
  (/\bBehavior_GWT\b/g, "Decision_GWT"),
  (/\bReventless\.Behavior\b/g, "Reventless.Decision"),
  (/\bStateChangeSlice\.Behavior\b/g, "StateChangeSlice.Decision"),
  (/\bMapping_GWT\.FromBehavior\b/g, "Mapping_GWT.FromDecision"),
  (/\bthenRefused\b/g, "thenForbidden"),
  (/\b([A-Z][A-Za-z0-9]*)_Behavior\b/g, "$1_Decision"),
]

// A trait's conformance binding names the decision module `Behavior`; where a
// file binds it, its uses in that file follow.
let localBinding = /^(\s*)module Behavior = /m

let rewrite = (source: string): string => {
  let text =
    replacements->Array.reduce(source, (text, (pattern, replacement)) =>
      text->String.replaceRegExp(pattern, replacement)
    )
  if localBinding->RegExp.test(text) {
    text
    ->String.replaceRegExp(/^(\s*)module Behavior = /gm, "$1module Decision = ")
    ->String.replaceRegExp(/\bBehavior\./g, "Decision.")
  } else {
    text
  }
}

// ── The tree ─────────────────────────────────────────────────────────────────

type move = {from: string, to_: string}
type edit = {path: string, contents: string}
type plan = {moves: array<move>, edits: array<edit>}

let skippedDirs = ["node_modules", "lib", ".git"]

let isSource = (name: string) => name->String.endsWith(".res") || name->String.endsWith(".resi")

// A moved source takes its compiled output and interface along.
let companions = [".res", ".resi", ".res.mjs", ".res.js", ".res.cjs"]

let rec walk = (dir: string, files: array<string>) =>
  NodeFs.readdirSync(dir, {withFileTypes: true})->Array.forEach(entry => {
    let name = entry->NodeFs.direntName
    let path = NodePath.join([dir, name])
    if entry->NodeFs.isDirectory {
      if !(skippedDirs->Array.includes(name)) {
        walk(path, files)
      }
    } else if entry->NodeFs.isFile {
      files->Array.push(path)
    }
  })

let byPath = (a: string, b: string) => String.compare(a, b)

/** What the run would do under `dir`, or why it cannot. */
let plan = (~dir: string): result<plan, string> => {
  let files = []
  walk(dir, files)
  files->Array.sort(byPath)
  let present = Set.fromArray(files)

  let moves =
    files
    ->Array.filter(path => path->String.endsWith("_Behavior.res"))
    ->Array.flatMap(source => {
      let stem = source->String.slice(~start=0, ~end=String.length(source) - 13)
      companions->Array.filterMap(suffix => {
        let from = stem ++ "_Behavior" ++ suffix
        present->Set.has(from) ? Some({from, to_: stem ++ "_Decision" ++ suffix}) : None
      })
    })

  let edits = files->Array.filterMap(path =>
    if path->NodePath.basename->isSource {
      let contents = NodeFs.readFileSync(path)
      let rewritten = rewrite(contents)
      rewritten == contents ? None : Some({path, contents: rewritten})
    } else {
      None
    }
  )

  switch moves->Array.find(({to_}) => present->Set.has(to_)) {
  | Some({from, to_}) =>
    Error(`${to_} already exists, so ${from} cannot take its name. Nothing was changed.`)
  | None => Ok({moves, edits})
  }
}

// ── Applying it ──────────────────────────────────────────────────────────────

let git = (~cwd: string, args: array<string>) =>
  NodeChildProcess.spawnSync(
    "git",
    args,
    {cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]},
  )

let succeeded = (result: NodeChildProcess.spawnSyncResult) =>
  result.status->Nullable.toOption == Some(0)

let isTracked = (path: string) =>
  git(
    ~cwd=NodePath.dirname(path),
    ["ls-files", "--error-unmatch", "--", NodePath.basename(path)],
  )->succeeded

let moveFile = ({from, to_}: move): result<unit, string> =>
  if isTracked(from) {
    let result = git(
      ~cwd=NodePath.dirname(from),
      ["mv", "--", NodePath.basename(from), NodePath.basename(to_)],
    )
    result->succeeded
      ? Ok()
      : Error(`git mv ${from}: ${result.stderr->Nullable.toOption->Option.getOr("")->String.trim}`)
  } else {
    try {
      NodeFs.renameSync(from, to_)
      Ok()
    } catch {
    | JsExn(e) => Error(`rename ${from}: ${e->JsExn.message->Option.getOr("failed")}`)
    }
  }

/** Edits are written at the old paths, then the files move, so a moved file
    keeps both its history and its new contents. */
let apply = ({moves, edits}: plan): result<unit, string> => {
  edits->Array.forEach(({path, contents}) => NodeFs.writeFileSync(path, contents))
  moves->Array.reduce(Ok(), (done, move) => done->Result.flatMap(() => moveFile(move)))
}

let describe = ({moves, edits}: plan, ~dryRun: bool): array<string> => {
  let verb = dryRun ? "would " : ""
  let lines = [
    ...moves->Array.map(({from, to_}) => `${verb}move  ${from} -> ${to_}`),
    ...edits->Array.map(({path}) => `${verb}edit  ${path}`),
  ]
  let movedSources = moves->Array.filter(({from}) => from->String.endsWith(".res"))->Array.length
  lines->Array.push(
    `${dryRun ? "Would rename" : "Renamed"} ${movedSources->Int.toString} file(s) and ${dryRun
        ? "edit"
        : "edited"} ${edits->Array.length->Int.toString}.`,
  )
  lines
}

/** The whole run without a process: the lines it prints, or why it failed. */
let execute = ({dir, dryRun}: args): result<array<string>, string> =>
  if !(dir->NodeFs.existsSync) {
    Error(`${dir} does not exist.`)
  } else {
    plan(~dir)->Result.flatMap(plan =>
      dryRun ? Ok(describe(plan, ~dryRun)) : apply(plan)->Result.map(() => describe(plan, ~dryRun))
    )
  }

let main = () =>
  CliArgs.run(cli, async args =>
    switch execute(args) {
    | Ok(lines) => lines->Array.forEach(line => Console.log(line))
    | Error(message) =>
      Console.error(`reventless-rename-to-decision: ${message}`)
      NodeProcess.exit(1)
    }
  )

// No top-level call: `../../run-rename-to-decision.mjs` invokes [main], so a test
// can import this module.

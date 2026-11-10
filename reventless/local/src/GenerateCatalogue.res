// Write a plugin's catalogue, `i18n/en.json`, and its lock file beside the plugin's sources.
//
// The plugin's composition root is applied to the local platform, as `emit-capabilities` does,
// and its `pluginStructure` turned into keys by `Reventless.Catalogue`: the same structure the
// deployed plugin reports, never a second scan of the sources. A rerun is idempotent and
// reports what it added, rewrote, kept as a person's edit, and found orphaned.

@val external dynImport: string => promise<'a> = "import"

type platform
type localPlatformExports = {"Make": unit => platform}
type builtPlugin = {"pluginStructure": Nullable.t<Reventless.Plugin.pluginStructure>}
type compositionExports = {"Make": platform => builtPlugin}

let usage = `Usage: generate-catalogue <srcDir> [<compositionModule>] [--plugin <Name>] [--check]
       generate-catalogue status <i18nDir>... [--languages <file>]
       generate-catalogue check <i18nDir>... [--languages <file>]
       generate-catalogue mark <lang> <i18nDir>... [--key <key>]... [--confirmed]

  Generating a plugin's English catalogue:
  <srcDir>             the plugin's sources; the catalogue goes to <srcDir>/../i18n/
  <compositionModule>  the composition root, when it is not the generated
                       Plugin.res: a module name inside <srcDir>, or a path
  --plugin <Name>      the plugin's name, where its GraphQL fields do not say it
  --check              write nothing; exit 1 when the files would change

  Run from the plugin package, after rescript build. Writes i18n/en.json, the
  English source catalogue, and i18n/en.lock.json, the hash of each text it
  generated: a text a person changed is kept on the next run, a key the
  structure no longer has is reported, never deleted.

  An app's catalogues, the <i18nDir>s in the order the platform merges them
  (each plugin's i18n/, then the app's):
  status               per language and layer: confirmed, proposed, missing,
                       stale, and the share ready to show
  check                exit 1 when a released language has a missing or stale
                       key, or any language a text that does not parse or
                       whose placeholders are not the English's
  mark <lang>          record in <lang>.lock.json the English each translated
                       key now answers to, so a later change shows it stale;
                       without --key only unmarked and stale keys
  --key <key>          a key, or a prefix ending in * (repeatable)
  --confirmed          mark the keys as reviewed (all of them without --key)
  --languages <file>   which languages are draft and which released; default
                       languages.json in the last <i18nDir>`

type generate = {srcDir: string, compositionModule?: string, plugin?: string, check: bool}

type args =
  | Generate(generate)
  | Status({dirs: array<string>, languages?: string})
  | Check({dirs: array<string>, languages?: string})
  | Mark({language: string, dirs: array<string>, keys: array<string>, confirmed: bool})

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(
    ~strings=["plugin", "languages"],
    ~bools=["check", "confirmed"],
    ~lists=["key"],
    argv,
  )->Result.flatMap(a => {
    let positionals = a->Reventless.CliArgs.positionals
    let rest = from => positionals->Array.slice(~start=from, ~end=Array.length(positionals))
    let languages = a->Reventless.CliArgs.string("languages")
    let dirsFrom = from =>
      switch rest(from) {
      | [] => Error("at least one <i18nDir> is required.")
      | dirs => Ok(dirs)
      }
    switch positionals->Array.get(0) {
    | None | Some("") => Error("<srcDir> is required.")
    | Some("status") => dirsFrom(1)->Result.map(dirs => Status({dirs, ?languages}))
    | Some("check") => dirsFrom(1)->Result.map(dirs => Check({dirs, ?languages}))
    | Some("mark") =>
      switch positionals->Array.get(1) {
      | None => Error("mark needs a <lang>.")
      | Some(language) if language == Reventless.CatalogueStatus.sourceLanguage =>
        Error(`${language} is the source language; mark a translation.`)
      | Some(language) =>
        dirsFrom(2)->Result.map(dirs => Mark({
          language,
          dirs,
          keys: a->Reventless.CliArgs.strings("key"),
          confirmed: a->Reventless.CliArgs.bool("confirmed"),
        }))
      }
    | Some(srcDir) =>
      a
      ->Reventless.CliArgs.atMost(2)
      ->Result.map(_ => Generate({
        srcDir,
        compositionModule: ?(positionals->Array.get(1)),
        plugin: ?(a->Reventless.CliArgs.string("plugin")),
        check: a->Reventless.CliArgs.bool("check"),
      }))
    }
  })

let cli: Reventless.CliArgs.cli<args> = {bin: "generate-catalogue", usage, parse: parseArgs}

let fail = (message: string) => {
  Console.error("generate-catalogue: " ++ message)
  NodeProcess.exit(1)
}

let readOr = (path: string, ~or: string): string =>
  NodeFs.existsSync(path) ? NodeFs.readFileSync(path) : or

/** One line per kind of change, the keys listed under it. */
let report = (merged: Reventless.Catalogue.merged): array<string> => {
  let section = (title, keys) =>
    switch keys {
    | [] => []
    | keys =>
      [`${title} (${keys->Array.length->Int.toString}):`, ...keys->Array.map(k => "  " ++ k)]
    }
  Array.flat([
    section("added", merged.added),
    section("rewritten from the structure", merged.updated),
    section("kept as edited by a person", merged.edited),
    section(
      "orphaned — the structure no longer has these; remove them once translated elsewhere",
      merged.orphans,
    ),
  ])
}

// ── An app's catalogues: status, check, mark ─────────────────────────────────

module Status = Reventless.CatalogueStatus

/** A layer's name: the package an `i18n/` directory sits in, else the directory's own name. */
let layerName = (dir: string): string => {
  let base = NodePath.basename(dir)
  base == "i18n" ? NodePath.basename(NodePath.dirname(dir)) : base
}

let readLayer = (dir: string): Status.layer => {
  if !NodeFs.existsSync(dir) {
    fail(`${dir} does not exist.`)
  }
  switch Status.layerOf(~name=layerName(dir), ReventlessCore.Platform_I18n.filesIn(dir)) {
  | Ok(layer) => layer
  | Error(message) =>
    fail(`${message}.`)
    {name: layerName(dir), catalogues: Dict.make(), marks: Dict.make()}
  }
}

let readReleases = (~dirs: array<string>, ~languages: option<string>): dict<Status.release> => {
  let path =
    languages->Option.getOr(
      NodePath.join([dirs->Array.at(-1)->Option.getOr("."), "languages.json"]),
    )
  switch (NodeFs.existsSync(path), languages) {
  | (false, Some(_)) =>
    fail(`${path} does not exist.`)
    Dict.make()
  | (false, None) => Dict.make()
  | (true, _) =>
    switch Status.readReleases(NodeFs.readFileSync(path)) {
    | Ok(releases) => releases
    | Error(message) =>
      fail(`${path}: ${message}`)
      Dict.make()
    }
  }
}

let pad = (text, width) => text ++ String.repeat(" ", Math.Int.max(0, width - String.length(text)))
let padStart = (text, width) =>
  String.repeat(" ", Math.Int.max(0, width - String.length(text))) ++ text

let releaseWord = (release: Status.release) =>
  switch release {
  | Draft => "draft"
  | Released => "released"
  }

/** The status table: a line per language, then one per layer. */
let statusLines = (statuses: array<Status.languageStatus>): array<string> => {
  let width =
    statuses
    ->Array.flatMap(s => s.layers->Array.map(((name, _)) => String.length(name)))
    ->Array.reduce(6, Math.Int.max)
  let row = (label, c: Status.counts) =>
    `  ${pad(label, width)}  ${padStart(Int.toString(c.total), 5)}  ` ++
    [c.confirmed, c.proposed, c.missing, c.stale]
    ->Array.map(n => padStart(Int.toString(n), 9))
    ->Array.join("  ") ++
    `  ${padStart(Int.toString(Status.percent(c)) ++ "%", 5)}`
  let header =
    `  ${pad("layer", width)}  ${padStart("keys", 5)}  ` ++
    ["confirmed", "proposed", "missing", "stale"]
    ->Array.map(h => padStart(h, 9))
    ->Array.join("  ") ++
    `  ${padStart("ready", 5)}`
  statuses->Array.flatMap(s =>
    s.source
      ? [`${s.language}  ${releaseWord(s.release)}  source, ${Int.toString(s.all.total)} keys`, ""]
      : Array.flat([
          [
            `${s.language}  ${releaseWord(s.release)}  ${Int.toString(Status.percent(s.all))}%`,
            header,
          ],
          s.layers->Array.map(((name, c)) => row(name, c)),
          s.layers->Array.length > 1 ? [row("all", s.all)] : [],
          s.all.unmarked > 0
            ? [
                `  ${Int.toString(
                    s.all.unmarked,
                  )} proposed key(s) carry no mark: run \`generate-catalogue mark ${s.language}\` so a change of the English shows them stale.`,
              ]
            : [],
          switch s.unknown {
          | [] => []
          | keys =>
            [
              `  not in the English (${Int.toString(
                  Array.length(keys),
                )}), usually a renamed key's old one:`,
              ...keys->Array.map(k => "    " ++ k),
            ]
          },
          [""],
        ])
  )
}

let runStatus = (~dirs, ~languages) => {
  let layers = dirs->Array.map(readLayer)
  let releases = readReleases(~dirs, ~languages)
  Status.status(layers, ~releases, ~hash=NodeCrypto.sha256Hex)
  ->statusLines
  ->Array.forEach(line => Console.log(line))
  NodeProcess.exit(0)
}

let runCheck = (~dirs, ~languages) => {
  let layers = dirs->Array.map(readLayer)
  let releases = readReleases(~dirs, ~languages)
  switch Status.problems(layers, ~releases, ~hash=NodeCrypto.sha256Hex) {
  | [] =>
    let released =
      releases
      ->Dict.toArray
      ->Array.filterMap(((l, r)) => r == Status.Released ? Some(l) : None)
      ->Array.toSorted(String.compare)
    Console.log(
      switch released {
      | [] => "Every catalogue parses; no language is released."
      | released => `Every catalogue parses; released and complete: ${released->Array.join(", ")}.`
      },
    )
    NodeProcess.exit(0)
  | problems =>
    problems->Array.forEach(p => Console.error(`${p.language}  ${p.layer}  ${p.key}: ${p.reason}`))
    Console.error(`${Int.toString(Array.length(problems))} problem(s).`)
    NodeProcess.exit(1)
  }
}

let runMark = (~language, ~dirs, ~keys, ~confirmed) => {
  let layers = dirs->Array.map(readLayer)
  let next = Status.mark(layers, ~language, ~patterns=keys, ~confirmed, ~hash=NodeCrypto.sha256Hex)
  let changed = ref(0)
  dirs->Array.forEachWithIndex((dir, i) => {
    let layer = layers->Array.getUnsafe(i)
    let before = layer.marks->Dict.get(language)->Option.getOr(Dict.make())
    next
    ->Array.get(i)
    ->Option.forEach(((_, marks)) => {
      let count =
        marks
        ->Dict.toArray
        ->Array.filter(((key, m)) => before->Dict.get(key) != Some(m))
        ->Array.length
      if count > 0 {
        let path = NodePath.join([dir, language ++ ".lock.json"])
        NodeFs.writeFileSync(path, Status.marksText(marks))
        Console.log(`${path}: ${Int.toString(count)} key(s) marked`)
        changed := changed.contents + count
      }
    })
  })
  if changed.contents == 0 {
    Console.log(`Nothing to mark in ${language}.`)
  }
  NodeProcess.exit(0)
}

let runGenerate = async ({srcDir: srcDirArg, ?compositionModule, ?plugin, check}: generate) => {
  switch NodeProcess.env->Dict.get("LOG_LEVEL") {
  | Some(_) => ()
  | None => NodeProcess.env->Dict.set("LOG_LEVEL", "warn")
  }

  let srcDir = NodePath.resolve([srcDirArg])
  let modulePath = EmitCapabilities.compositionModulePath(~srcDir, ~moduleArg=compositionModule)
  if !NodeFs.existsSync(modulePath) {
    fail(`${modulePath} not found — run \`rescript build\` first.`)
  }

  let platformModule: localPlatformExports = await dynImport("./Platform.res.mjs")
  let composition: compositionExports = await dynImport(NodeUrl.pathToFileURL(modulePath)["href"])
  let structure =
    composition["Make"](platformModule["Make"]())["pluginStructure"]->Nullable.toOption

  let generated = switch structure {
  | None => []
  | Some(structure) =>
    switch plugin->Option.orElse(Reventless.Catalogue.pluginNameOf(structure)) {
    | Some(plugin) => Reventless.Catalogue.entries(~plugin, structure)
    | None =>
      fail("the plugin's name is not on any view or command; pass --plugin <Name>.")
      []
    }
  }

  let i18nDir = NodePath.join([srcDir, "..", "i18n"])
  let cataloguePath = NodePath.join([i18nDir, "en.json"])
  let lockPath = NodePath.join([i18nDir, "en.lock.json"])
  let catalogueBefore = readOr(cataloguePath, ~or="{}")
  let lockBefore = readOr(lockPath, ~or="{}")

  let merged = Reventless.Catalogue.merge(
    ~generated,
    ~existing=Reventless.Catalogue.readCatalogue(catalogueBefore),
    ~locks=Reventless.Catalogue.readLocks(lockBefore),
    ~hash=NodeCrypto.sha256Hex,
  )
  let catalogueAfter = Reventless.Catalogue.catalogueText(merged.catalogue)
  let lockAfter = Reventless.Catalogue.lockText(merged.locks)
  let changed = catalogueAfter != catalogueBefore || lockAfter != lockBefore

  report(merged)->Array.forEach(line => Console.log(line))
  if check {
    if changed {
      Console.error(`${cataloguePath} is not current — run generate-catalogue.`)
      NodeProcess.exit(1)
    }
    Console.log(`${cataloguePath} is current.`)
  } else if changed {
    NodeFs.mkdirSync(i18nDir, {recursive: true})
    NodeFs.writeFileSync(cataloguePath, catalogueAfter)
    NodeFs.writeFileSync(lockPath, lockAfter)
    Console.log(
      `Generated: ${cataloguePath} (${merged.catalogue
        ->Dict.keysToArray
        ->Array.length
        ->Int.toString} keys)`,
    )
  } else {
    Console.log(`${cataloguePath} is current.`)
  }
  NodeProcess.exit(0)
}

let main = () =>
  Reventless.CliArgs.run(cli, async args =>
    switch args {
    | Status({dirs, ?languages}) => runStatus(~dirs, ~languages)
    | Check({dirs, ?languages}) => runCheck(~dirs, ~languages)
    | Mark({language, dirs, keys, confirmed}) => runMark(~language, ~dirs, ~keys, ~confirmed)
    | Generate(generate) => await runGenerate(generate)
    }
  )

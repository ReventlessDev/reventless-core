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

  <srcDir>             the plugin's sources; the catalogue goes to <srcDir>/../i18n/
  <compositionModule>  the composition root, when it is not the generated
                       Plugin.res: a module name inside <srcDir>, or a path
  --plugin <Name>      the plugin's name, where its GraphQL fields do not say it
  --check              write nothing; exit 1 when the files would change

  Run from the plugin package, after rescript build. Writes i18n/en.json, the
  English source catalogue, and i18n/en.lock.json, the hash of each text it
  generated: a text a person changed is kept on the next run, a key the
  structure no longer has is reported, never deleted.`

type args = {srcDir: string, compositionModule?: string, plugin?: string, check: bool}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(~strings=["plugin"], ~bools=["check"], argv)
  ->Result.flatMap(a => a->Reventless.CliArgs.atMost(2))
  ->Result.flatMap(a => {
    let positionals = a->Reventless.CliArgs.positionals
    switch positionals->Array.get(0) {
    | None | Some("") => Error("<srcDir> is required.")
    | Some(srcDir) =>
      Ok({
        srcDir,
        compositionModule: ?(positionals->Array.get(1)),
        plugin: ?(a->Reventless.CliArgs.string("plugin")),
        check: a->Reventless.CliArgs.bool("check"),
      })
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

let main = () =>
  Reventless.CliArgs.run(cli, async ({srcDir: srcDirArg, ?compositionModule, ?plugin, check}) => {
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
  })

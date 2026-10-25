// Entry point for the plugin generator.

let usage = `Usage: generate-plugin [--aws <Namespace>] <srcDir>

  <srcDir>           the plugin's sources; Plugin.res is written into it
  --aws <Namespace>  generate an -aws package instead: Plugin.res and Main.res
                     are written into ./src, composing the plugin whose sources
                     are <srcDir> under <Namespace>`

type args = {variant: Config.variant, srcDir: string}

let parseArgs = (argv: array<string>): result<args, string> =>
  CliArgs.parse(~strings=["aws"], argv)
  ->Result.flatMap(a => a->CliArgs.atMost(1))
  ->Result.flatMap(a =>
    switch (a->CliArgs.string("aws"), a->CliArgs.positionals->Array.get(0)) {
    | (Some(""), _) => Error("--aws needs a value")
    | (_, None | Some("")) => Error("<srcDir> is required.")
    | (None, Some(srcDir)) => Ok({variant: Config.Composition, srcDir})
    | (Some(compositionNamespace), Some(srcDir)) =>
      Ok({variant: Config.Aws({compositionNamespace: compositionNamespace}), srcDir})
    }
  )

let cli: CliArgs.cli<args> = {bin: "generate-plugin", usage, parse: parseArgs}

/** The generated files sit in the plugin's source tree, so they face its format
    gate like any other source. Codegen lays text out for reading, not for the
    formatter, so the formatter settles the layout before the file is written.
    Raising beats falling back: unformatted output would build and then fail the
    format gate on every regeneration. */
let formatted = (source: string, ~cwd: string): string =>
  NodeChildProcess.execFileSync(
    "pnpm",
    ["exec", "rescript", "format", "--stdin", ".res"],
    {cwd, encoding: "utf8", input: source},
  )

/** The composition for the plugin whose sources are `srcDir`, unformatted.
    Reads the sources and any package plugin.json lists; writes nothing. */
let render = (~srcDir: string, ~variant: Config.variant): (Config.config, string) => {
  let config = {...Config.read(~srcDir), variant}
  let packaged =
    config.slicesFrom
    ->Option.getOr([])
    ->Array.map(Packaged.scan(~pluginDir=NodePath.dirname(srcDir), ~exclude=config.exclude, _))
  let discovered = Array.concat(
    Discovery.scan(~srcDir, ~exclude=config.exclude),
    packaged->Array.flatMap(p => p.files),
  )
  let resolved = Pairing.resolve(discovered, ~srcDir)
  // Sits at the src root rather than in a kind folder, so `Discovery` never
  // sees it and it is not a component. Its presence is the whole question.
  let hasLifecycleModel = NodePath.join([srcDir, "LifecycleModel.res"])->NodeFs.existsSync
  let identities =
    Discovery.scanIdentities(~srcDir, ~exclude=config.exclude)
    ->Array.concat(packaged->Array.flatMap(p => p.identities))
    ->Array.toSorted(String.compare)
  // Beside `Roles.res`, at the src root for the same reason as the lifecycle
  // model: it is a declaration about the plugin, not a component.
  let hasAdmission = NodePath.join([srcDir, "Admission.res"])->NodeFs.existsSync
  let admissionDoors = Discovery.scanAdmissionDoors(~srcDir, discovered)
  let source = Codegen.render(
    ~config,
    ~resolved,
    ~discovered,
    ~hasLifecycleModel,
    ~identities,
    ~hasAdmission,
    ~admissionDoors,
    ~aliases=Packaged.aliases(packaged),
  )
  (config, source)
}

// A usage mistake exits non-zero, so `prebuild` (and CI) fail instead of
// continuing green with no Plugin.res generated.
let main = () =>
  CliArgs.run(cli, async ({variant, srcDir: srcDirArg}) => {
    // Resolve to absolute path (handles relative paths and trailing slashes)
    let srcDir = NodePath.resolve([srcDirArg])
    let (config, source) = render(~srcDir, ~variant)

    let outputDir = switch variant {
    | Config.Composition => srcDir
    | Config.Aws(_) => NodePath.join([NodeProcess.cwd(), "src"])
    }

    let pluginPath = NodePath.join([outputDir, "Plugin.res"])
    NodeFs.writeFileSync(pluginPath, source->formatted(~cwd=outputDir))
    Console.log("Generated: " ++ pluginPath)

    switch variant {
    | Config.Composition => ()
    | Config.Aws(_) =>
      let mainSource = Codegen.renderMain(~config)
      let mainPath = NodePath.join([outputDir, "Main.res"])
      NodeFs.writeFileSync(mainPath, mainSource->formatted(~cwd=outputDir))
      Console.log("Generated: " ++ mainPath)
    }
  })

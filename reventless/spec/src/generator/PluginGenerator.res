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

// A usage mistake exits non-zero, so `prebuild` (and CI) fail instead of
// continuing green with no Plugin.res generated.
let main = () =>
  CliArgs.run(cli, async ({variant, srcDir: srcDirArg}) => {
    // Resolve to absolute path (handles relative paths and trailing slashes)
    let srcDir = NodePath.resolve([srcDirArg])

    let config = {...Config.read(~srcDir), variant}
    let discovered = Discovery.scan(~srcDir, ~exclude=config.exclude)
    let resolved = Pairing.resolve(discovered, ~srcDir)
    // Sits at the src root rather than in a kind folder, so `Discovery` never
    // sees it and it is not a component. Its presence is the whole question.
    let hasLifecycleModel = NodePath.join([srcDir, "LifecycleModel.res"])->NodeFs.existsSync
    let source = Codegen.render(~config, ~resolved, ~discovered, ~hasLifecycleModel)

    let outputDir = switch variant {
    | Config.Composition => srcDir
    | Config.Aws(_) => NodePath.join([NodeProcess.cwd(), "src"])
    }

    let pluginPath = NodePath.join([outputDir, "Plugin.res"])
    NodeFs.writeFileSync(pluginPath, source)
    Console.log("Generated: " ++ pluginPath)

    switch variant {
    | Config.Composition => ()
    | Config.Aws(_) =>
      let mainSource = Codegen.renderMain(~config)
      let mainPath = NodePath.join([outputDir, "Main.res"])
      NodeFs.writeFileSync(mainPath, mainSource)
      Console.log("Generated: " ++ mainPath)
    }
  })

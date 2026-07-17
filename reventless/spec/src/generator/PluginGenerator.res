// Entry point for the plugin generator.
// Usage: generate-plugin <srcDir>
//        generate-plugin --aws <Namespace> <srcDir>

@val external processExit: int => unit = "process.exit"

let () = {
  let argv2 = Generator_Node.argv->Array.get(2)->Option.getOr("")
  let argv3 = Generator_Node.argv->Array.get(3)->Option.getOr("")
  let argv4 = Generator_Node.argv->Array.get(4)->Option.getOr("")

  let (variant, srcDirArg) = if argv2 === "--aws" {
    if argv3 !== "" && argv4 !== "" {
      (Config.Aws({compositionNamespace: argv3}), argv4)
    } else {
      Console.error("Usage: generate-plugin --aws <Namespace> <srcDir>")
      (Config.Composition, "")
    }
  } else {
    (Config.Composition, argv2)
  }

  if srcDirArg === "" {
    if argv2 !== "--aws" {
      Console.error("Usage: generate-plugin <srcDir>")
      Console.error("       generate-plugin --aws <Namespace> <srcDir>")
    }
    // Exit non-zero on a usage error so `prebuild` (and CI) actually fail
    // instead of continuing green with no Plugin.res generated.
    processExit(1)
  } else {
    // Resolve to absolute path (handles relative paths and trailing slashes)
    let srcDir = Generator_Node.resolve([srcDirArg])

    let config = {...Config.read(~srcDir), variant}
    let discovered = Discovery.scan(~srcDir, ~exclude=config.exclude)
    let resolved = Pairing.resolve(discovered, ~srcDir)
    let source = Codegen.render(~config, ~resolved, ~discovered)

    let outputDir = switch variant {
    | Config.Composition => srcDir
    | Config.Aws(_) => Generator_Node.join([Generator_Node.cwd(), "src"])
    }

    let pluginPath = Generator_Node.join([outputDir, "Plugin.res"])
    Generator_Node.writeFileSync(pluginPath, source)
    Console.log("Generated: " ++ pluginPath)

    switch variant {
    | Config.Composition => ()
    | Config.Aws(_) =>
      let mainSource = Codegen.renderMain(~config)
      let mainPath = Generator_Node.join([outputDir, "Main.res"])
      Generator_Node.writeFileSync(mainPath, mainSource)
      Console.log("Generated: " ++ mainPath)
    }
  }
}

// Entry point for the plugin generator.
// Usage: generate-plugin <srcDir>
//        generate-plugin --aws <Namespace> <srcDir>

let () = {
  let argv2 = Generator_Node.argv->Array.get(2)->Option.getOr("")
  let argv3 = Generator_Node.argv->Array.get(3)->Option.getOr("")
  let argv4 = Generator_Node.argv->Array.get(4)->Option.getOr("")

  let (variant, srcDirArg) = if argv2 === "--aws" {
    if argv3 !== "" && argv4 !== "" {
      (Config.Aws({sourceNamespace: argv3}), argv4)
    } else {
      Console.error("Usage: generate-plugin --aws <Namespace> <srcDir>")
      (Config.Standard, "")
    }
  } else {
    (Config.Standard, argv2)
  }

  if srcDirArg === "" {
    if argv2 !== "--aws" {
      Console.error("Usage: generate-plugin <srcDir>")
      Console.error("       generate-plugin --aws <Namespace> <srcDir>")
    }
  } else {
    // Resolve to absolute path (handles relative paths and trailing slashes)
    let srcDir = Generator_Node.resolve([srcDirArg])

    let config = {...Config.read(~srcDir), variant}
    let discovered = Discovery.scan(~srcDir, ~exclude=config.exclude)
    let resolved = Pairing.resolve(discovered, ~srcDir)
    let source = Codegen.render(~config, ~resolved)

    let outputPath = switch variant {
    | Config.Standard => Generator_Node.join([srcDir, "Plugin.res"])
    | Config.Aws({sourceNamespace}) =>
      Generator_Node.join([Generator_Node.cwd(), "src", sourceNamespace ++ "_Aws.res"])
    }
    Generator_Node.writeFileSync(outputPath, source)
    Console.log("Generated: " ++ outputPath)
  }
}

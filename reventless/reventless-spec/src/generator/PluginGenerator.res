// Entry point for the plugin generator.
// Usage: generate-plugin <srcDir>
// Reads srcDir, generates src/Plugin.res, and writes it to disk.

let () = {
  let srcDirArg = Generator_Node.argv->Array.get(2)->Option.getOr("")
  if srcDirArg === "" {
    Console.error("Usage: generate-plugin <srcDir>")
    Console.error("Example: generate-plugin src/")
  } else {
    // Resolve to absolute path (handles relative paths and trailing slashes)
    let srcDir = Generator_Node.resolve([srcDirArg])

    let config = Config.read(~srcDir)
    let discovered = Discovery.scan(~srcDir, ~exclude=config.exclude)
    let resolved = Pairing.resolve(discovered, ~srcDir)
    let source = Codegen.render(~config, ~resolved)

    let outputPath = Generator_Node.join([srcDir, "Plugin.res"])
    Generator_Node.writeFileSync(outputPath, source)
    Console.log("Generated: " ++ outputPath)
  }
}

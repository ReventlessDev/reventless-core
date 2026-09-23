// Emit `capabilities.json` beside a plugin's compiled composition root.
//
// Applies the plugin's composition root to the local platform and renders the
// structure-derived capability manifest — the same `pluginStructure` walk the
// deployed plugin reports at runtime, never a second scan of the sources.
//
// The two dynamically imported modules are the only untyped surface, and they
// are typed *at the boundary*: `Platform.res.mjs` and every composition root
// emit exactly the exports declared below, so `pluginStructure` arrives as
// `Reventless.Plugin.pluginStructure` and everything downstream is ordinary
// typed ReScript. Same shape as `ReventlessGwt.LocalHost`, which reflects the
// domain graph this way.
//
// The platform is reached through a dynamic import rather than by applying
// `Platform.Make` directly: a composition root's `Make` is a JS function
// expecting the platform *value*, and a ReScript module is not one. Importing
// it puts both sides on the same footing, and it keeps `LOG_LEVEL` (set below)
// in force before the platform's logger initialises.

// Emitted by ReScript as a literal `import(...)` expression — the composition
// root's path is only known at run time, so it cannot be a static binding.
@val external dynImport: string => promise<'a> = "import"

// ── The dynamic-import boundary ──────────────────────────────────────────────

type platform
type localPlatformExports = {"Make": unit => platform}
type builtPlugin = {"pluginStructure": Reventless.Plugin.pluginStructure}
type compositionExports = {"Make": platform => builtPlugin}

// ── Which module holds the composition root ──────────────────────────────────

/** `Plugin.res.mjs` is what `generate-plugin` emits, so it is the default and
    every existing caller is unaffected. A hand-written composition root is
    named after its plugin instead and says so: a bare module name (`Catalog`)
    resolves inside `<srcDir>`, a path (`../lib/Catalog.res.mjs`) from the
    working directory. */
let compositionModulePath = (~srcDir: string, ~moduleArg: option<string>): string => {
  let withExtension = name => name->String.endsWith(".mjs") ? name : name ++ ".res.mjs"
  switch moduleArg {
  | None | Some("") => NodePath.join([srcDir, "Plugin.res.mjs"])
  | Some(name) =>
    name->String.includes("/") || name->String.includes(NodePath.sep)
      ? NodePath.resolve([withExtension(name)])
      : NodePath.join([srcDir, withExtension(name)])
  }
}

// ── Entry point ──────────────────────────────────────────────────────────────

let fail = (message: string) => {
  Console.error("emit-capabilities: " ++ message)
  NodeProcess.exit(1)
}

let usage = `Usage: emit-capabilities <srcDir> [<compositionModule>]

  <srcDir>             the plugin's sources; capabilities.json is written there
  <compositionModule>  the composition root, when it is not the generated
                       Plugin.res: a module name inside <srcDir>, or a path

  Run from the plugin package, after rescript build.`

type args = {srcDir: string, compositionModule: option<string>}

let parseArgs = (argv: array<string>): result<args, string> =>
  Reventless.CliArgs.parse(argv)
  ->Result.flatMap(a => a->Reventless.CliArgs.atMost(2))
  ->Result.flatMap(a => {
    let positionals = a->Reventless.CliArgs.positionals
    switch positionals->Array.get(0) {
    | None | Some("") => Error("<srcDir> is required.")
    | Some(srcDir) => Ok({srcDir, compositionModule: positionals->Array.get(1)})
    }
  })

let cli: Reventless.CliArgs.cli<args> = {bin: "emit-capabilities", usage, parse: parseArgs}

let main = () =>
  Reventless.CliArgs.run(cli, async ({srcDir: srcDirArg, compositionModule}) => {
    // The local platform defaults to Debug-level logging; a build step should not.
    switch NodeProcess.env->Dict.get("LOG_LEVEL") {
    | Some(_) => ()
    | None => NodeProcess.env->Dict.set("LOG_LEVEL", "warn")
    }

    let srcDir = NodePath.resolve([srcDirArg])
    let modulePath = compositionModulePath(~srcDir, ~moduleArg=compositionModule)
    if !NodeFs.existsSync(modulePath) {
      fail(`${modulePath} not found — run \`rescript build\` first.`)
    }

    // Relative specifier: resolved against this module, so it finds the
    // sibling compiled platform whatever the working directory is.
    let platformModule: localPlatformExports = await dynImport("./Platform.res.mjs")
    let platform = platformModule["Make"]()

    let composition: compositionExports = await dynImport(NodeUrl.pathToFileURL(modulePath)["href"])
    let built = composition["Make"](platform)

    let manifestPath = NodePath.join([srcDir, "capabilities.json"])
    NodeFs.writeFileSync(
      manifestPath,
      Reventless.CapabilityManifest.renderForStructure(built["pluginStructure"]),
    )
    Console.log("Generated: " ++ manifestPath)

    // Applying the platform functor wires in-process infrastructure; exit
    // explicitly so no lingering handle keeps the build step alive.
    NodeProcess.exit(0)
  })

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
//
// Usage: emit-capabilities <srcDir> [<compositionModule>]
//   (run from the plugin package, after `rescript build`)

// ── Node ─────────────────────────────────────────────────────────────────────

@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external writeFileSync: (string, string, @as("utf8") _) => unit = "writeFileSync"

@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:path") @variadic external resolve: array<string> => string = "resolve"
@module("node:path") @val external sep: string = "sep"

@module("node:url") external pathToFileURL: string => {"href": string} = "pathToFileURL"

@val @scope("process") external argv: array<string> = "argv"
@val @scope("process") external env: Dict.t<string> = "env"
@val external processExit: int => unit = "process.exit"

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
  | None | Some("") => join([srcDir, "Plugin.res.mjs"])
  | Some(name) =>
    name->String.includes("/") || name->String.includes(sep)
      ? resolve([withExtension(name)])
      : join([srcDir, withExtension(name)])
  }
}

// ── Entry point ──────────────────────────────────────────────────────────────

let fail = (message: string) => {
  Console.error("emit-capabilities: " ++ message)
  processExit(1)
}

let main = async () => {
  // The local platform defaults to Debug-level logging; a build step should not.
  switch env->Dict.get("LOG_LEVEL") {
  | Some(_) => ()
  | None => env->Dict.set("LOG_LEVEL", "warn")
  }

  switch argv->Array.get(2) {
  | None | Some("") => {
      Console.error("Usage: emit-capabilities <srcDir> [<compositionModule>]")
      processExit(1)
    }
  | Some(srcDirArg) => {
      let srcDir = resolve([srcDirArg])
      let modulePath = compositionModulePath(~srcDir, ~moduleArg=argv->Array.get(3))
      if !existsSync(modulePath) {
        fail(`${modulePath} not found — run \`rescript build\` first.`)
      }

      // Relative specifier: resolved against this module, so it finds the
      // sibling compiled platform whatever the working directory is.
      let platformModule: localPlatformExports = await dynImport("./Platform.res.mjs")
      let platform = platformModule["Make"]()

      let composition: compositionExports = await dynImport(pathToFileURL(modulePath)["href"])
      let built = composition["Make"](platform)

      let manifestPath = join([srcDir, "capabilities.json"])
      writeFileSync(
        manifestPath,
        Reventless.CapabilityManifest.renderForStructure(built["pluginStructure"]),
      )
      Console.log("Generated: " ++ manifestPath)

      // Applying the platform functor wires in-process infrastructure; exit
      // explicitly so no lingering handle keeps the build step alive.
      processExit(0)
    }
  }
}

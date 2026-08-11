// Writes the curated component manifest where the local host shell serves its
// static assets from, so `manifestUrl` discovery works in dev exactly as it does
// in a deployment.
//
// Locally there is no deploy and no bucket: `reventless-host-shell` serves its
// own `dist/` (that is where the shipped `config.json` and `ui-hints.json` come
// from), so that is where the file goes. Rewritten on every boot, which also
// makes it self-healing — a `pnpm install` that replaces the package directory
// costs one restart, not a debugging session.
//
// The curation itself lives in `ReventlessCore.Platform_BakedManifest`, shared
// with any other platform that bakes: only the destination is local.

let hostShellPackage = "@reventlessdev/reventless-host-shell"

let log = ReventlessCore.Logger.fromEnv()

// Resolved from the running project rather than from this framework module: the
// bundle is a deploy input the project names in its own package.json, and a
// framework-rooted lookup would skip that pin (the same distinction
// `Util_Bundle.resolvePackageRoot(~fromPulumiProject)` draws on AWS).
let hostShellDistDir = (): option<string> =>
  try {
    Some(
      NodePath.dirname(
        NodeModule.createRequire(NodeProcess.cwd() ++ "/index.js")->NodeModule.requireResolve(
          hostShellPackage ++ "/package.json",
        ),
      ) ++ "/dist",
    )
  } catch {
  | _ => None
  }

let defaultKey = "component-manifest.json"

/**
 A declared bake writes the file or fails loudly. Both failure modes it can hit
 are the deployment's own mistake — a name that matches no component, or a shell
 package that is not installed — and both produce the same symptom if swallowed:
 a shop that renders nothing, with no line in the log saying why.
 */
let emit = (
  ~structures: array<(string, Reventless.Plugin.pluginStructure)>,
  ~config: ReventlessInfra.Platform.bakedManifest,
) => {
  let selections =
    config.components->Array.map((
      s
    ): ReventlessCore.Platform_BakedManifest.selection => {
      plugin: s.plugin,
      views: s.views,
      commands: s.commands,
    })
  switch ReventlessCore.Platform_BakedManifest.curate(~structures, ~selections) {
  | Error(e) => JsError.throwWithMessage(ReventlessCore.Platform_BakedManifest.describe(e))
  | Ok(manifest) =>
    switch hostShellDistDir() {
    | None =>
      JsError.throwWithMessage(
        `baked manifest: cannot resolve ${hostShellPackage} from ${NodeProcess.cwd()} — ` ++
        `the local shell serves the file from that package's dist/, so declaring a bake ` ++
        `without the package installed would write nothing and render an empty shell.`,
      )
    | Some(dir) =>
      let key = config.key->Option.getOr(defaultKey)
      let path = NodePath.join([dir, key])
      NodeFs.writeFileSync(path, JSON.stringify(manifest, ~space=2))
      log.info(~comp="BakedManifest", `wrote ${key} for ${selections->Array.length->Int.toString} plugin(s): ${path}`)
    }
  }
}

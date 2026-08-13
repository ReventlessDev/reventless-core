// Writes the curated component manifest where the local host shell serves its
// static assets from (`HostShellDist`), so `manifestUrl` discovery works in dev
// exactly as it does in a deployment. Rewritten on every boot, which also makes
// it self-healing — a `pnpm install` that replaces the package directory costs
// one restart, not a debugging session.
//
// The curation itself lives in `ReventlessCore.Platform_BakedManifest`, shared
// with any other platform that bakes: only the destination is local.

let log = ReventlessCore.Logger.fromEnv()

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
    switch HostShellDist.dir() {
    | None =>
      JsError.throwWithMessage(
        `baked manifest: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++
        `the local shell serves the file from that package's dist/, so declaring a bake ` ++
        `without the package installed would write nothing and render an empty shell.`,
      )
    | Some(dir) =>
      let key = config.key->Option.getOr(ReventlessCore.Platform_BakedManifest.defaultKey)
      let path = NodePath.join([dir, key])
      NodeFs.writeFileSync(path, JSON.stringify(manifest, ~space=2))
      log.info(~comp="BakedManifest", `wrote ${key} for ${selections->Array.length->Int.toString} plugin(s): ${path}`)
    }
  }
}

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
let toSelections = (
  components: array<ReventlessInfra.Platform.bakedManifestSelection>,
): array<ReventlessCore.Platform_BakedManifest.selection> =>
  components->Array.map((s): ReventlessCore.Platform_BakedManifest.selection => {
    plugin: s.plugin,
    views: s.views,
    commands: s.commands,
  })

/**
 Every file this declaration produces, as (key, selections) pairs.

 The default journey first, then one per declared journey. Separate from the
 write so the whole set is reachable from a test — the same reason
 `ShellConfig.overlay` exists apart from its write.
 */
let files = (
  ~config: ReventlessInfra.Platform.bakedManifest,
): array<(string, array<ReventlessCore.Platform_BakedManifest.selection>)> => {
  let base = [
    (
      config.key->Option.getOr(ReventlessCore.Platform_BakedManifest.defaultKey),
      toSelections(config.components),
    ),
  ]
  switch config.journeys {
  | None => base
  | Some(journeys) =>
    base->Array.concat(
      journeys->Array.map(j => (
        j.key->Option.getOr(ReventlessCore.Platform_BakedManifest.journeyKey(~group=j.group)),
        toSelections(j.components),
      )),
    )
  }
}

let emit = (
  ~structures: array<(string, Reventless.Plugin.pluginStructure)>,
  ~config: ReventlessInfra.Platform.bakedManifest,
) => {
  let outputs = files(~config)
  // Every file is curated before any is written. A declaration naming a
  // component that does not exist fails the boot, and failing it halfway would
  // leave a shell serving one audience's file and a stale copy of another's.
  let curated = outputs->Array.map(((key, selections)) => (
    key,
    switch ReventlessCore.Platform_BakedManifest.curate(~structures, ~selections) {
    | Error(e) => JsError.throwWithMessage(ReventlessCore.Platform_BakedManifest.describe(e))
    | Ok(manifest) => manifest
    },
  ))
  switch HostShellDist.dir() {
  | None =>
    JsError.throwWithMessage(
      `baked manifest: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++
      `the local shell serves the file from that package's dist/, so declaring a bake ` ++
      `without the package installed would write nothing and render an empty shell.`,
    )
  | Some(dir) =>
    curated->Array.forEach(((key, manifest)) => {
      let path = NodePath.join([dir, key])
      NodeFs.writeFileSync(path, JSON.stringify(manifest, ~space=2))
      log.info(~comp="BakedManifest", `wrote ${key}: ${path}`)
    })
  }
}

// Delivers a deployment's host-shell keys to local dev, so `config.json` says
// the same things it says on AWS.
//
// On AWS the deploy owns that file outright: `Util_ShellConfig.fields` joins the
// keys the deploy computes with the ones the deployment chose, and the result is
// written as a `BucketObject`. Locally there is no deploy and no bucket — the
// `config.json` a dev's browser fetches is the one `reventless-host-shell`
// shipped in its own `dist/`. That file is therefore the *baseline* here, not
// the output.
//
// Hence the copy. The first write puts the shipped file aside as
// `config.base.json` and every write since is baseline + overlay. Overlaying the
// previous output instead would make removal impossible: drop `bakedManifest`
// from the platform root and yesterday's `manifestUrl` stays, pointing the shell
// at a file nothing writes any more — an empty shop with nothing in the diff to
// explain it. Reading a baseline makes both directions self-healing, and a
// `pnpm install` that replaces the package directory costs one restart, because
// the baseline is re-seeded from whatever the new package ships.
//
// One key is computed (`manifestUrl`, from the bake declaration — local knows
// where it put the file); the rest are the deployment's own `shellConfig`,
// passed through verbatim. A `shellConfig` that names a computed key fails the
// same way it does on AWS: a passthrough cannot redirect a key the platform
// decides, and silently resolving it either way points the shell somewhere
// unintended.

let log = ReventlessCore.Logger.fromEnv()

let fileName = "config.json"

// Not `config.json.base` — the shell's dist is served as a static directory, and
// a name that keeps the `.json` extension is the one a dev can open in a browser
// to see what the overlay started from.
let baselineFileName = "config.base.json"

let manifestUrlOf = (config: ReventlessInfra.Platform.bakedManifest): string =>
  ReventlessCore.Platform_BakedManifest.urlForKey(config.key)

let computedKeys = ["manifestUrl"]

/**
 The overlay this platform puts on top of the shipped `config.json`.

 Separate from the write so the whole key set is reachable from a test, the same
 reason `Util_ShellConfig.fields` exists apart from `deployPlatform`'s
 `Pulumi.Output.apply` on AWS.
 */
let overlay = (
  ~bakedManifest: option<ReventlessInfra.Platform.bakedManifest>,
  ~shellConfig: option<dict<JSON.t>>,
): dict<JSON.t> => {
  let out = Dict.make()

  bakedManifest->Option.forEach(config =>
    out->Dict.set("manifestUrl", JSON.Encode.string(manifestUrlOf(config)))
  )

  shellConfig->Option.forEach(extra => {
    let collisions = extra->Dict.keysToArray->Array.filter(k => computedKeys->Array.includes(k))
    if collisions->Array.length > 0 {
      JsError.throwWithMessage(
        "host UI config.json: shellConfig sets key(s) the platform already computes — " ++
        collisions->Array.join(", ") ++
        ". Remove them from shellConfig; a passthrough cannot redirect a computed key.",
      )
    }
    extra->Dict.forEachWithKey((v, k) => out->Dict.set(k, v))
  })

  out
}

let readObject = (~path: string, ~label: string): dict<JSON.t> =>
  switch NodeFs.readFileSync(path)->JSON.parseOrThrow->JSON.Decode.object {
  | Some(obj) => obj
  | None => JsError.throwWithMessage(`host UI ${label}: ${path} is not a JSON object`)
  | exception _ => JsError.throwWithMessage(`host UI ${label}: cannot read ${path} as JSON`)
  }

/**
 Merge the overlay onto the shipped `config.json` in the host shell's `dist/`.

 A no-op when there is nothing to say and nothing was said before — a platform
 that declares neither a bake nor any `shellConfig` never touches the file, so
 its dev shell is byte-identical to one built before this module existed. Once
 either is declared the write happens or fails loudly, for the reason
 `BakedManifest.emit` gives: both failure modes it can hit are the deployment's
 own mistake, and both produce the same silent symptom if swallowed.
 */
let emit = (
  ~bakedManifest: option<ReventlessInfra.Platform.bakedManifest>,
  ~shellConfig: option<dict<JSON.t>>,
  // Test seam. The baseline dance is the part of this module with state behind
  // it — "boot twice and the second write still starts from the shipped file" is
  // not a property a pure function can carry.
  ~dir: option<string>=?,
) => {
  let overlay = overlay(~bakedManifest, ~shellConfig)

  switch (
    switch dir {
    | Some(_) as given => given
    | None => HostShellDist.dir()
    }
  ) {
  | None =>
    // Nothing declared and no shell installed is the ordinary case for a
    // platform nobody points a browser at; only a declaration makes the missing
    // package an error, and then it is the same error the bake gives.
    if overlay->Dict.keysToArray->Array.length > 0 {
      JsError.throwWithMessage(
        `host UI config.json: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++
        `the local shell reads its config from that package's dist/, so declaring shell ` ++
        `config without the package installed would write nothing and leave the shell ` ++
        `configured as it shipped.`,
      )
    }
  | Some(dir) =>
    let path = NodePath.join([dir, fileName])
    let baselinePath = NodePath.join([dir, baselineFileName])

    // Seeded only when there is an overlay to apply. A platform that declares
    // nothing must not leave a `config.base.json` behind for the next one to
    // read as authoritative.
    if !NodeFs.existsSync(baselinePath) && overlay->Dict.keysToArray->Array.length > 0 {
      if !NodeFs.existsSync(path) {
        JsError.throwWithMessage(
          `host UI config.json: ${HostShellDist.package} ships no ${fileName} at ${dir} — ` ++
          `there is no baseline to overlay, so the shell would boot with only the keys ` ++
          `declared here and none of the ones it expects.`,
        )
      }
      NodeFs.writeFileSync(baselinePath, NodeFs.readFileSync(path))
    }

    if NodeFs.existsSync(baselinePath) {
      let merged = readObject(~path=baselinePath, ~label="config baseline")
      overlay->Dict.forEachWithKey((v, k) => merged->Dict.set(k, v))
      NodeFs.writeFileSync(path, JSON.stringify(merged->JSON.Encode.object, ~space=2))
      let keys = overlay->Dict.keysToArray
      log.info(
        ~comp="ShellConfig",
        keys->Array.length == 0
          ? `restored ${fileName} from ${baselineFileName}: ${path}`
          : `wrote ${fileName} with ${keys->Array.join(", ")}: ${path}`,
      )
    }
  }
}

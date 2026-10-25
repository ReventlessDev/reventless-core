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
// The computed keys are the environment (always `local`), `manifestUrl` and the
// journey map (from the bake declaration — local knows where it put the file),
// `uiSlotsUrl` and `adminGroup`; the rest are the deployment's own `shellConfig`,
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

// Where a caller acting as a given role discovers from. Beside `manifestUrl`
// rather than replacing it: that key stays the default journey, which is what a
// caller matching no declared group gets and what every existing deployment has.
let journeyManifestsKey = "journeyManifestUrls"

let environmentKeys = [Reventless.ShellEnvironment.nameKey, Reventless.ShellEnvironment.purposeKey]

let computedKeys = [
  ...environmentKeys,
  "manifestUrl",
  journeyManifestsKey,
  ReventlessCore.Platform_UiSlots.configKey,
  ReventlessCore.Platform_AdminGroup.configKey,
  ReventlessCore.Platform_SelfRegistration.configKey,
]

/**
 The overlay this platform puts on top of the shipped `config.json`.

 Separate from the write so the whole key set is reachable from a test, the same
 reason `Util_ShellConfig.fields` exists apart from `deployPlatform`'s
 `Pulumi.Output.apply` on AWS.
 */
let overlay = (
  ~bakedManifest: option<ReventlessInfra.Platform.bakedManifest>,
  ~uiSlotsFile: option<string>=?,
  ~shellConfig: option<dict<JSON.t>>,
  // Read off the plugin structures once they have landed, so the first write
  // (from the declaration alone) omits it and the second carries it.
  ~selfRegistration: option<ReventlessCore.Platform_SelfRegistration.config>=?,
): dict<JSON.t> => {
  let out =
    Reventless.ShellEnvironment.local
    ->Reventless.ShellEnvironment.configFields
    ->Dict.fromArray

  // `UiSlots` serves the module; this is what tells the shell to import it. The
  // two are separate writes to separate files, which is exactly why the name
  // they share is stated once in `Platform_UiSlots` — and why withdrawal has to
  // clear both. The baseline does that half: drop the key here and the shipped
  // `config.json` comes back without it.
  uiSlotsFile->Option.forEach(_ =>
    out->Dict.set(
      ReventlessCore.Platform_UiSlots.configKey,
      JSON.Encode.string(ReventlessCore.Platform_UiSlots.url),
    )
  )

  ReventlessCore.Platform_AdminGroup.configEntry()->Option.forEach(((k, v)) => out->Dict.set(k, v))

  selfRegistration->Option.forEach(c => {
    let (k, v) = ReventlessCore.Platform_SelfRegistration.configEntry(c)
    out->Dict.set(k, v)
  })

  bakedManifest->Option.forEach(config => {
    out->Dict.set("manifestUrl", JSON.Encode.string(manifestUrlOf(config)))
    // Omitted entirely when nothing is declared, so a single-audience deployment
    // writes the same key set it always did and a shell that has never heard of
    // journeys sees no new keys.
    switch ReventlessCore.Platform_BakedManifest.journeyUrls(~config) {
    | [] => ()
    | urls =>
      out->Dict.set(
        journeyManifestsKey,
        urls
        ->Array.map(((group, url)) => (group, JSON.Encode.string(url)))
        ->Dict.fromArray
        ->JSON.Encode.object,
      )
    }
  })

  shellConfig->Option.forEach(extra => {
    let collisions = extra->Dict.keysToArray->Array.filter(k => computedKeys->Array.includes(k))
    if collisions->Array.length > 0 {
      JsError.throwWithMessage(
        "host UI config.json: shellConfig sets key(s) the platform already computes — " ++
        collisions->Array.join(
          ", ",
        ) ++ ". Remove them from shellConfig; a passthrough cannot redirect a computed key.",
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

 The environment keys are always written, so the shell can say it is local;
 without the package they are dropped silently, since a platform nobody points a
 browser at has nothing to badge. Anything declared beyond them is written or
 fails loudly, for the reason `BakedManifest.emit` gives: both failure modes it
 can hit are the deployment's own mistake, and both produce the same silent
 symptom if swallowed.
 */
let emit = (
  ~bakedManifest: option<ReventlessInfra.Platform.bakedManifest>,
  ~uiSlotsFile: option<string>=?,
  ~shellConfig: option<dict<JSON.t>>,
  ~selfRegistration: option<ReventlessCore.Platform_SelfRegistration.config>=?,
  // The platform's chosen `assetsDir`; unset, the host-shell package's `dist/`.
  ~dir: option<string>=?,
) => {
  let overlay = overlay(~bakedManifest, ~uiSlotsFile?, ~shellConfig, ~selfRegistration?)
  let declared = overlay->Dict.keysToArray->Array.filter(k => !(environmentKeys->Array.includes(k)))

  switch switch dir {
  | Some(_) as given => given
  | None => HostShellDist.dir()
  } {
  | None =>
    // Nothing declared and no shell installed is the ordinary case for a
    // platform nobody points a browser at; only a declaration makes the missing
    // package an error, and then it is the same error the bake gives.
    if declared->Array.length > 0 {
      JsError.throwWithMessage(
        `host UI config.json: cannot resolve ${HostShellDist.package} from ${NodeProcess.cwd()} — ` ++
        `the local shell reads its config from that package's dist/, so declaring shell ` ++
        `config without the package installed would write nothing and leave the shell ` ++ `configured as it shipped.`,
      )
    }
  | Some(dir) =>
    let path = NodePath.join([dir, fileName])
    let baselinePath = NodePath.join([dir, baselineFileName])

    // The baseline is whatever `config.json` the directory held first: the
    // shell's shipped file, or the app's own in a chosen `assetsDir`.
    if !NodeFs.existsSync(baselinePath) {
      if NodeFs.existsSync(path) {
        NodeFs.writeFileSync(baselinePath, NodeFs.readFileSync(path))
      } else if declared->Array.length > 0 {
        JsError.throwWithMessage(
          `host UI config.json: there is no ${fileName} at ${dir} — ` ++
          `there is no baseline to overlay, so the shell would boot with only the keys ` ++ `declared here and none of the ones it expects.`,
        )
      }
    }

    if NodeFs.existsSync(baselinePath) {
      let merged = readObject(~path=baselinePath, ~label="config baseline")
      overlay->Dict.forEachWithKey((v, k) => merged->Dict.set(k, v))
      NodeFs.writeFileSync(path, JSON.stringify(merged->JSON.Encode.object, ~space=2))
      log.info(
        ~comp="ShellConfig",
        `wrote ${fileName} with ${overlay->Dict.keysToArray->Array.join(", ")}: ${path}`,
      )
    }
  }
}

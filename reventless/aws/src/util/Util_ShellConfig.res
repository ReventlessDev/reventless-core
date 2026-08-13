// Assembly of the `config.json` the deploy writes beside the host shell's
// `index.html`.
//
// The keys split in two: the ones the deploy *computes* (endpoints, region,
// pool ids — resolved Pulumi Outputs by the time they get here) and the ones a
// deployment *chooses*. This module is the pure join of the two, so the whole
// key set is reachable from a test instead of living inside deployPlatform's
// `Pulumi.Output.apply`, where nothing could assert a single key of it.

module Platform = ReventlessInfra.Platform

// A mode's options, flattened to the wire shape. They are payloads of their arm
// on the deploy side (so `mapStyle` with the map off cannot be expressed) and
// flat siblings of `viewModes` on the wire (because that is where the released
// shell reads them). This function is the whole of that translation.
let modeOptions = (mode: Platform.viewMode): array<(string, JSON.t)> =>
  switch mode {
  | Map(opts) =>
    switch opts.style {
    | Some(style) => [("mapStyle", JSON.Encode.string(style))]
    | None => []
    }
  | Graph(opts) =>
    switch opts.layout {
    | Some(layout) => [("graphLayout", JSON.Encode.string(layout))]
    | None => []
    }
  }

/**
The config.json field set.

`computed` arrives in wire order and keeps it. `viewModes` unset ⇒ no
`viewModes` key and no per-mode key, so a deployment that wants no optional mode
gets byte-identical output to before this input existed. `bakedManifest` unset ⇒
no `manifestUrl`, and every caller keeps the admin discovery path. `shellConfig`
merges in last; a key it shares with one already present fails the deploy naming
it, because silently resolving the collision either way produces an app pointed
somewhere unintended with nothing in the diff to say so.
*/
let fields = (
  ~computed: array<(string, JSON.t)>,
  ~viewModes: option<array<Platform.viewMode>>=?,
  ~bakedManifest: option<Platform.bakedManifest>=?,
  ~shellConfig: option<dict<JSON.t>>=?,
): dict<JSON.t> => {
  let out = computed->Dict.fromArray

  // A declared bake is what turns the shell's non-elevated audience on: an
  // operator keeps the admin queries, everyone else discovers from this file.
  // Computed rather than left to `shellConfig` because the deploy is what
  // decides where the file goes — a passthrough could point the shell at a key
  // nothing writes, and a statically-discovered shell has no admin API behind it
  // to notice.
  bakedManifest->Option.forEach(bake =>
    out->Dict.set(
      "manifestUrl",
      JSON.Encode.string(ReventlessCore.Platform_BakedManifest.urlForKey(bake.key)),
    )
  )

  switch viewModes {
  | Some(modes) =>
    out->Dict.set(
      "viewModes",
      modes->Array.map(m => m->Platform.viewModeToString->JSON.Encode.string)->JSON.Encode.array,
    )
    modes->Array.forEach(m => m->modeOptions->Array.forEach(((k, v)) => out->Dict.set(k, v)))
  | None => ()
  }

  switch shellConfig {
  | Some(extra) =>
    let collisions = extra->Dict.keysToArray->Array.filter(k => out->Dict.get(k)->Option.isSome)
    if collisions->Array.length > 0 {
      failwith(
        "host UI config.json: shellConfig sets key(s) the deploy already computes — " ++
        collisions->Array.join(", ") ++
        ". Remove them from shellConfig; a passthrough cannot redirect a computed key.",
      )
    }
    extra->Dict.forEachWithKey((v, k) => out->Dict.set(k, v))
  | None => ()
  }

  out
}

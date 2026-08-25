// Assembly of the `config.json` the deploy writes beside the host shell's
// `index.html`.
//
// The keys split in two: the ones the deploy *computes* (endpoints, region,
// pool ids — resolved Pulumi Outputs by the time they get here) and the ones a
// deployment *chooses*. This module is the pure join of the two, so the whole
// key set is reachable from a test instead of living inside deployPlatform's
// `Pulumi.Output.apply`, where nothing could assert a single key of it.

module Platform = ReventlessInfra.Platform

// Where a caller acting as a given role discovers from — a group→url map. Named
// here as the shell reads it, the same way `manifestUrl` is.
let journeyManifestsKey = "journeyManifestUrls"

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
The identity fields a shell reads, under **both** spellings.

🚨 **Both, and not as a sequenced rename.** `identityProvider*` is what these
become — the concept is not AWS-specific, so a second cloud's adapter should meet
the same names. `cognito*` is what every shipped shell reads today.

A shell reads `config.json` at runtime and CloudFront serves the previous bundle
until someone invalidates it, so switching the keys in one deploy leaves a window
where the served bundle and the served config disagree. `cognitoClientId` is read
into an `option`: a bundle that cannot find its key does not error, it gets
`None`, and login, silent refresh and token refresh all quietly fall through —
the window is a total auth outage that reports nothing.

Writing both removes the ordering dependency rather than managing it: any bundle,
old or new or stale in a CDN, finds one it understands. The `cognito*` pair goes
once the shell that prefers the other is the pinned one.

Here rather than inline at the call site so the pairing is one fact in one place,
and so the property can be asserted without a deploy.
*/
let identityFields = (~providerId: string, ~clientId: string): array<(string, JSON.t)> => [
  ("identityProviderId", JSON.Encode.string(providerId)),
  ("identityProviderClientId", JSON.Encode.string(clientId)),
  ("cognitoUserPoolId", JSON.Encode.string(providerId)),
  ("cognitoClientId", JSON.Encode.string(clientId)),
]

/**
The websocket endpoint graphql-ws subscriptions open against.

AppSync serves realtime on a **different host** from queries — `appsync-realtime-api`
rather than `appsync-api` — so a scheme swap alone produces a URL the service will
not upgrade. The shell derives one when this key is absent, and its derivation is
the generic scheme swap, correct for a same-host server and wrong here. Absent, an
operator's menu therefore stops following Activate / Deactivate: the socket never
opens, and nothing on the page says so.

Written for every deployment rather than left to a passthrough because it is a
function of an endpoint the deploy already resolves, and a shell config that
restated it would be one more copy of a rule with a silent failure mode.
*/
let subscriptionEndpoint = (httpsEndpoint: string): string =>
  httpsEndpoint
  ->String.replace("https://", "wss://")
  ->String.replace(".appsync-api.", ".appsync-realtime-api.")

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
  bakedManifest->Option.forEach(bake => {
    out->Dict.set(
      "manifestUrl",
      JSON.Encode.string(ReventlessCore.Platform_BakedManifest.urlForKey(bake.key)),
    )
    // Where a caller acting as a given role discovers from, beside the default
    // rather than instead of it: `manifestUrl` stays the default journey, which
    // is what a caller matching no declared group gets. Omitted entirely when
    // nothing is declared, so a single-audience deployment writes the key set it
    // always did and a shell that has never heard of journeys sees no new key.
    switch ReventlessCore.Platform_BakedManifest.journeyUrls(~config=bake) {
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

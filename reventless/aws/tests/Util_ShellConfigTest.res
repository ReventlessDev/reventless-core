open JestGlobals

// The host shell reads config.json by key name, and every failure here is a
// silent one: a missing key deletes a feature with nothing in any log, and a
// key overwritten by a passthrough points the app at the wrong API. Both are
// only assertable because `fields` is pure.

let computed = [
  ("apiEndpoint", JSON.Encode.string("https://domain.example/graphql")),
  ("region", JSON.Encode.string("eu-west-1")),
]

let get = (out, key) => out->Dict.get(key)->Option.getOr(JSON.Encode.null)

describe("Util_ShellConfig.fields — viewModes", () => {
  testSync("unset ⇒ no viewModes key and the computed set is untouched", () => {
    let out = Util_ShellConfig.fields(~computed)
    expect(out->Dict.keysToArray)->toEqual(["apiEndpoint", "region"])
    expect(out->Dict.get("viewModes")->Option.isNone)->toBe(true)
  })

  testSync("Map with defaults ⇒ the mode, and no mapStyle key", () => {
    let out = Util_ShellConfig.fields(~computed, ~viewModes=[Map({})])
    expect(out->get("viewModes"))->toEqual(JSON.Encode.array([JSON.Encode.string("map")]))
    expect(out->Dict.get("mapStyle")->Option.isNone)->toBe(true)
  })

  testSync("per-mode options flatten beside the mode", () => {
    let out = Util_ShellConfig.fields(
      ~computed,
      ~viewModes=[Map({style: "https://tiles.example/style.json"}), Graph({layout: "dagre"})],
    )
    expect(out->get("viewModes"))->toEqual(
      JSON.Encode.array([JSON.Encode.string("map"), JSON.Encode.string("graph")]),
    )
    expect(out->get("mapStyle"))->toEqual(
      JSON.Encode.string("https://tiles.example/style.json"),
    )
    expect(out->get("graphLayout"))->toEqual(JSON.Encode.string("dagre"))
  })
})

describe("Util_ShellConfig.fields — bakedManifest", () => {
  let bake = (~key: option<string>=?): ReventlessInfra.Platform.bakedManifest => {
    components: [{plugin: "Catalog", views: ["Products"], commands: []}],
    key: ?key,
  }

  testSync("unset ⇒ no manifestUrl, so every caller keeps the admin path", () => {
    let out = Util_ShellConfig.fields(~computed)
    expect(out->Dict.get("manifestUrl")->Option.isNone)->toBe(true)
  })

  testSync("declared ⇒ the URL the deploy writes the file to", () => {
    let out = Util_ShellConfig.fields(~computed, ~bakedManifest=bake())
    expect(out->get("manifestUrl"))->toEqual(JSON.Encode.string("/component-manifest.json"))
  })

  // The key and the URL are one string; a renamed bake that kept the default
  // URL would 404 on a shell with no admin API to fall back to.
  testSync("follows a renamed bake", () => {
    let out = Util_ShellConfig.fields(~computed, ~bakedManifest=bake(~key="storefront.json"))
    expect(out->get("manifestUrl"))->toEqual(JSON.Encode.string("/storefront.json"))
  })

  testSync("a shellConfig manifestUrl fails the deploy rather than redirecting it", () => {
    let failure = try {
      let _ = Util_ShellConfig.fields(
        ~computed,
        ~bakedManifest=bake(),
        ~shellConfig=Dict.fromArray([("manifestUrl", JSON.Encode.string("/elsewhere.json"))]),
      )
      None
    } catch {
    | Failure(message) => Some(message)
    }
    switch failure {
    | Some(message) => expect(message->String.includes("manifestUrl"))->toBe(true)
    | None => fail("a shellConfig key redirecting the computed manifest must fail the deploy")
    }
  })
})

// ── Journeys ──────────────────────────────────────────────────────────────
//
// One curated surface per audience, beside the default one. The property under
// test throughout is that a deployment declaring none is untouched: every
// deployment that predates journeys has exactly one audience, and its
// config.json must not grow a key for a feature it does not use.
describe("Util_ShellConfig.fields — journeys", () => {
  let withJourneys = (
    ~journeys: array<ReventlessInfra.Platform.bakedJourney>,
  ): ReventlessInfra.Platform.bakedManifest => {
    components: [{plugin: "Catalog", views: ["Products"], commands: []}],
    journeys,
  }

  let shopper: ReventlessInfra.Platform.bakedJourney = {
    group: "Shopper",
    components: [{plugin: "Catalog", views: ["Products"], commands: []}],
  }

  let fulfilment: ReventlessInfra.Platform.bakedJourney = {
    group: "Fulfilment",
    components: [{plugin: "Ordering", views: ["Orders"], commands: ["ShipOrder"]}],
    key: "fulfilment.json",
  }

  testSync("a bake declaring no journeys writes no map", () => {
    let out = Util_ShellConfig.fields(
      ~computed,
      ~bakedManifest={components: [{plugin: "Catalog", views: ["Products"], commands: []}]},
    )
    expect(out->Dict.get("journeyManifestUrls")->Option.isNone)->toBe(true)
  })

  testSync("an empty journeys array is the same as none", () => {
    let out = Util_ShellConfig.fields(~computed, ~bakedManifest=withJourneys(~journeys=[]))
    expect(out->Dict.get("journeyManifestUrls")->Option.isNone)->toBe(true)
  })

  // The default journey keeps `manifestUrl`, so a caller matching no declared
  // group lands where every caller landed before.
  testSync("keeps manifestUrl as the default journey", () => {
    let out = Util_ShellConfig.fields(~computed, ~bakedManifest=withJourneys(~journeys=[shopper]))
    expect(out->get("manifestUrl"))->toEqual(JSON.Encode.string("/component-manifest.json"))
  })

  testSync("maps each declared group to its own file", () => {
    let out = Util_ShellConfig.fields(
      ~computed,
      ~bakedManifest=withJourneys(~journeys=[shopper, fulfilment]),
    )
    expect(out->get("journeyManifestUrls"))->toEqual(
      JSON.Encode.object(
        Dict.fromArray([
          // Derived from the group, lower-cased, because a key is part of a URL.
          ("Shopper", JSON.Encode.string("/component-manifest-shopper.json")),
          // Named explicitly, and the declaration wins.
          ("Fulfilment", JSON.Encode.string("/fulfilment.json")),
        ]),
      ),
    )
  })

  // The URL a shell fetches and the key the bake writes are one string, derived
  // once — a second derivation is a file written where nothing looks for it. So
  // every key the bake writes is published, and the default one is published as
  // `manifestUrl` rather than in the map.
  testSync("publishes the URL of every key the bake writes, exactly once", () => {
    let bake = withJourneys(~journeys=[shopper, fulfilment])
    let out = Util_ShellConfig.fields(~computed, ~bakedManifest=bake)
    let published = Array.concat(
      out->get("manifestUrl")->JSON.Decode.string->Option.mapOr([], url => [url]),
      out
      ->get("journeyManifestUrls")
      ->JSON.Decode.object
      ->Option.getOr(Dict.make())
      ->Dict.valuesToArray
      ->Array.filterMap(JSON.Decode.string),
    )
    expect(published)->toEqual(
      ReventlessCore.Platform_BakedManifest.files(~config=bake)->Array.map(((key, _)) =>
        "/" ++ key
      ),
    )
  })

  // A passthrough cannot redirect a key the deploy computes — the same rule
  // `manifestUrl` already carries, extended to the map beside it.
  testSync("a shellConfig journey map fails the deploy rather than redirecting it", () => {
    let failure = try {
      let _ = Util_ShellConfig.fields(
        ~computed,
        ~bakedManifest=withJourneys(~journeys=[shopper]),
        ~shellConfig=Dict.fromArray([
          ("journeyManifestUrls", JSON.Encode.object(Dict.make())),
        ]),
      )
      None
    } catch {
    | Failure(message) => Some(message)
    }
    switch failure {
    | Some(message) => expect(message->String.includes("journeyManifestUrls"))->toBe(true)
    | None => fail("a shellConfig key redirecting the computed journey map must fail the deploy")
    }
  })
})

describe("Util_ShellConfig.fields — shellConfig passthrough", () => {
  testSync("shell-owned keys land verbatim, under the computed ones", () => {
    let out = Util_ShellConfig.fields(
      ~computed,
      ~shellConfig=Dict.fromArray([
        ("platformName", JSON.Encode.string("Online Shop")),
        ("accessTiers", JSON.Encode.array([JSON.Encode.string("public")])),
      ]),
    )
    expect(out->Dict.keysToArray)->toEqual([
      "apiEndpoint",
      "region",
      "platformName",
      "accessTiers",
    ])
    expect(out->get("platformName"))->toEqual(JSON.Encode.string("Online Shop"))
  })

  testSync("a key the deploy computes fails the deploy, naming it", () => {
    let failure = try {
      let _ = Util_ShellConfig.fields(
        ~computed,
        ~shellConfig=Dict.fromArray([
          ("apiEndpoint", JSON.Encode.string("https://wrong.example/graphql")),
        ]),
      )
      None
    } catch {
    | Failure(message) => Some(message)
    }
    switch failure {
    | Some(message) => expect(message->String.includes("apiEndpoint"))->toBe(true)
    | None => fail("a shellConfig key colliding with a computed one must fail the deploy")
    }
  })
})

// 🚨 The identity keys travel under both spellings through the rename. A shell
// reads config.json at runtime and CloudFront serves the previous bundle until
// someone invalidates it, so switching them in one deploy leaves a window where
// the served bundle and the served config disagree — and `cognitoClientId` is
// read into an option, so a bundle that cannot find its key does not error, it
// gets `None` and login silently stops working.
//
// These assert the property that removes that window, not the spelling.
describe("Util_ShellConfig.identityFields", () => {
  let fields = Util_ShellConfig.identityFields(~providerId="eu-west-1_x", ~clientId="7cl13nt")
  let get = key =>
    fields->Array.find(((k, _)) => k == key)->Option.map(((_, v)) => v)

  testSync("the new spelling is present", () =>
    expect((get("identityProviderId"), get("identityProviderClientId")))->toEqual((
      Some(JSON.Encode.string("eu-west-1_x")),
      Some(JSON.Encode.string("7cl13nt")),
    ))
  )

  // Not "still" — deliberately. Every shipped shell reads these, and dropping
  // them is a later release gated on the pinned bundle, not on this one.
  testSync("the deprecated spelling is present too", () =>
    expect((get("cognitoUserPoolId"), get("cognitoClientId")))->toEqual((
      Some(JSON.Encode.string("eu-west-1_x")),
      Some(JSON.Encode.string("7cl13nt")),
    ))
  )

  // The whole point: a bundle reading either name gets the same answer. Two keys
  // carrying different values would be worse than one key, not better.
  testSync("both spellings carry identical values", () =>
    expect((
      get("identityProviderId") == get("cognitoUserPoolId"),
      get("identityProviderClientId") == get("cognitoClientId"),
    ))->toEqual((true, true))
  )

  // The client id is the load-bearing one — it is what the shell's auth provider
  // branches on. The pool id is currently discarded by the shell, which is
  // exactly why a `cognito*` sweep is dangerous: the safe one gives no warning.
  testSync("nothing else sneaks into the identity field set", () =>
    expect(fields->Array.map(((k, _)) => k)->Array.toSorted(String.compare))->toEqual([
      "cognitoClientId",
      "cognitoUserPoolId",
      "identityProviderClientId",
      "identityProviderId",
    ])
  )
})

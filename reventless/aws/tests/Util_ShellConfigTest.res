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

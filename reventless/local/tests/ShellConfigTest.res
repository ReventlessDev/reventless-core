open JestGlobals

// The `config.json` overlay the local platform puts on the host shell's shipped
// file. Two things are under test and they fail differently: the key set (what a
// deployment's declaration turns into) and the baseline (what makes a second
// boot, and a *withdrawn* declaration, land where they should). Every failure
// here is silent at the point it happens and loud a long way away — a shell that
// boots with the wrong surface, or none.

let _ = TestRunner.setup()

let manifest = (~key: option<string>=?): ReventlessInfra.Platform.bakedManifest => {
  components: [{plugin: "Catalog", views: ["Products"], commands: []}],
  key: ?key,
}

let str = (d: dict<JSON.t>, k: string): option<string> =>
  d->Dict.get(k)->Option.flatMap(JSON.Decode.string)

let threw = (f: unit => unit): bool =>
  try {
    f()
    false
  } catch {
  | _ => true
  }

describe("ShellConfig.overlay", () => {
  testSync("is empty when the deployment declares nothing", () => {
    let out = ShellConfig.overlay(~bakedManifest=None, ~shellConfig=None)
    expect(out->Dict.keysToArray)->toEqual([])
  })

  testSync("points manifestUrl at the bake's default key", () => {
    let out = ShellConfig.overlay(~bakedManifest=Some(manifest()), ~shellConfig=None)
    expect(out->str("manifestUrl"))->toEqual(Some("/component-manifest.json"))
  })

  // The key and the URL are one string: the bake writes to the dist root, which
  // is also the shell's URL root. A renamed file that kept the default URL would
  // 404 on a shell that has no admin API to fall back to.
  testSync("follows a renamed bake", () => {
    let out = ShellConfig.overlay(
      ~bakedManifest=Some(manifest(~key="storefront.json")),
      ~shellConfig=None,
    )
    expect(out->str("manifestUrl"))->toEqual(Some("/storefront.json"))
  })

  testSync("passes the deployment's own keys through verbatim", () => {
    let out = ShellConfig.overlay(
      ~bakedManifest=None,
      ~shellConfig=Some(
        Dict.fromArray([
          ("appName", JSON.Encode.string("Online Shop")),
          ("elevatedGroups", ["Admin"]->Array.map(JSON.Encode.string)->JSON.Encode.array),
        ]),
      ),
    )
    expect(out->str("appName"))->toEqual(Some("Online Shop"))
    expect(out->Dict.get("elevatedGroups")->Option.isSome)->toBe(true)
  })

  // Silently resolving it either way points the shell at a manifest the platform
  // did not write, with nothing in the diff to say so.
  testSync("refuses a shellConfig key the platform computes", () =>
    expect(
      threw(() =>
        ShellConfig.overlay(
          ~bakedManifest=Some(manifest()),
          ~shellConfig=Some(
            Dict.fromArray([("manifestUrl", JSON.Encode.string("/elsewhere.json"))]),
          ),
        )->ignore
      ),
    )->toBe(true)
  )
})

describe("ShellConfig.emit", () => {
  let shipped = `{\n  "apiEndpoint": "/graphql",\n  "appName": "Shipped"\n}`

  let distWithConfig = () => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-shellconfig-"]))
    NodeFs.writeFileSync(NodePath.join([dir, "config.json"]), shipped)
    dir
  }

  let readJson = (path: string): dict<JSON.t> =>
    NodeFs.readFileSync(path)->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow

  let readConfig = (dir: string) => readJson(NodePath.join([dir, "config.json"]))
  let readBaseline = (dir: string) => readJson(NodePath.join([dir, "config.base.json"]))

  let named = name => Some(Dict.fromArray([("appName", JSON.Encode.string(name))]))

  testSync("merges the overlay onto the shipped file and keeps its other keys", () => {
    let dir = distWithConfig()
    ShellConfig.emit(~bakedManifest=Some(manifest()), ~shellConfig=None, ~dir)
    let out = readConfig(dir)
    expect(out->str("manifestUrl"))->toEqual(Some("/component-manifest.json"))
    expect(out->str("apiEndpoint"))->toEqual(Some("/graphql"))
  })

  testSync("leaves a platform that declares nothing entirely alone", () => {
    let dir = distWithConfig()
    ShellConfig.emit(~bakedManifest=None, ~shellConfig=None, ~dir)
    expect(NodeFs.readFileSync(NodePath.join([dir, "config.json"])))->toEqual(shipped)
    expect(NodeFs.existsSync(NodePath.join([dir, "config.base.json"])))->toBe(false)
  })

  // The whole reason a baseline is kept: boot 2 overlaying boot 1's output would
  // read `appName: "First"` as shipped and carry it forever.
  testSync("starts every boot from the shipped file, not the last output", () => {
    let dir = distWithConfig()
    ShellConfig.emit(~bakedManifest=None, ~shellConfig=named("First"), ~dir)
    ShellConfig.emit(~bakedManifest=None, ~shellConfig=named("Second"), ~dir)
    expect(readConfig(dir)->str("appName"))->toEqual(Some("Second"))
    expect(readBaseline(dir)->str("appName"))->toEqual(Some("Shipped"))
  })

  // Withdrawing a declaration has to be as reachable as making it: a lingering
  // manifestUrl points the shell at a file nothing writes any more, and the
  // symptom is an empty shop.
  testSync("restores the shipped file once the declaration is withdrawn", () => {
    let dir = distWithConfig()
    ShellConfig.emit(~bakedManifest=Some(manifest()), ~shellConfig=None, ~dir)
    ShellConfig.emit(~bakedManifest=None, ~shellConfig=None, ~dir)
    let out = readConfig(dir)
    expect(out->Dict.get("manifestUrl"))->toEqual(None)
    expect(out->str("appName"))->toEqual(Some("Shipped"))
  })

  // Writing only the declared keys would boot a shell with no apiEndpoint, and
  // that failure surfaces nowhere near here.
  testSync("refuses to overlay a dist that ships no config.json", () => {
    let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-shellconfig-"]))
    expect(
      threw(() => ShellConfig.emit(~bakedManifest=Some(manifest()), ~shellConfig=None, ~dir)),
    )->toBe(true)
  })
})

// ── Journeys ──────────────────────────────────────────────────────────────
//
// One curated surface per audience, beside the default one. The property under
// test throughout is that a deployment declaring none is untouched: journeys are
// what a shop with several audiences opts into, and every existing deployment
// has exactly one.

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

describe("ShellConfig.overlay — journeys", () => {

  // The regression line. A shell that has never heard of journeys must not
  // suddenly find a key it does not know.
  testSync("a bake declaring no journeys writes no map", () => {
    let out = ShellConfig.overlay(~bakedManifest=Some(manifest()), ~shellConfig=None)
    expect(out->Dict.get("journeyManifestUrls"))->toEqual(None)
  })

  testSync("an empty journeys array is the same as none", () => {
    let out = ShellConfig.overlay(~bakedManifest=Some(withJourneys(~journeys=[])), ~shellConfig=None)
    expect(out->Dict.get("journeyManifestUrls"))->toEqual(None)
  })

  // The default journey keeps `manifestUrl`, so a caller matching no declared
  // group lands where every caller landed before.
  testSync("keeps manifestUrl as the default journey", () => {
    let out = ShellConfig.overlay(
      ~bakedManifest=Some(withJourneys(~journeys=[shopper])),
      ~shellConfig=None,
    )
    expect(out->str("manifestUrl"))->toEqual(Some("/component-manifest.json"))
  })

  testSync("maps each declared group to its own file", () => {
    let out = ShellConfig.overlay(
      ~bakedManifest=Some(withJourneys(~journeys=[shopper, fulfilment])),
      ~shellConfig=None,
    )
    let map =
      out->Dict.get("journeyManifestUrls")->Option.flatMap(JSON.Decode.object)->Option.getOrThrow
    expect((map->str("Shopper"), map->str("Fulfilment")))->toEqual((
      // Derived from the group, lower-cased, because a key is part of a URL.
      Some("/component-manifest-shopper.json"),
      // Named explicitly, and the declaration wins.
      Some("/fulfilment.json"),
    ))
  })

  // A passthrough cannot redirect a key the platform computes — the same rule
  // `manifestUrl` already carries, extended to the map it now writes beside it.
  testSync("refuses a shellConfig that sets the journey map itself", () =>
    expect(
      threw(() =>
        ShellConfig.overlay(
          ~bakedManifest=Some(withJourneys(~journeys=[shopper])),
          ~shellConfig=Some(Dict.fromArray([("journeyManifestUrls", JSON.Encode.object(Dict.make()))])),
        )->ignore
      ),
    )->toBe(true)
  )
})

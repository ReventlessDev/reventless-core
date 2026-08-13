open JestGlobals

// Which files a bake declaration produces, and under which names. The write
// itself needs a host-shell package on disk; this is the part that decides what
// gets written, so it is worth pinning without one.

let _ = TestRunner.setup()

let sel = (plugin): ReventlessInfra.Platform.bakedManifestSelection => {
  plugin,
  views: [],
  commands: [],
}

let keysOf = (config: ReventlessInfra.Platform.bakedManifest) =>
  BakedManifest.files(~config)->Array.map(((key, _)) => key)

describe("BakedManifest.files", () => {
  open Expect

  // The regression line: one declaration, one file, under the name every
  // existing deployment's config.json already points at.
  testSync("a declaration with no journeys produces exactly one file", () => {
    expect(keysOf({components: [sel("Catalog")]}))->toEqual(["component-manifest.json"])
  })

  testSync("a renamed default is honoured", () => {
    expect(keysOf({components: [sel("Catalog")], key: "shop.json"}))->toEqual(["shop.json"])
  })

  // The default comes first and stays: it is what a caller matching no declared
  // group gets, which locally includes the no-bearer identity every dev session
  // starts from.
  testSync("journeys are written beside the default, not instead of it", () => {
    expect(
      keysOf({
        components: [sel("Catalog")],
        journeys: [
          {group: "Shopper", components: [sel("Catalog")]},
          {group: "Fulfilment", components: [sel("Ordering")], key: "fulfil.json"},
        ],
      }),
    )->toEqual([
      "component-manifest.json",
      "component-manifest-shopper.json",
      "fulfil.json",
    ])
  })

  // A group name is a Cognito identifier and a key is part of a URL, so the
  // derivation folds anything that is neither a letter nor a digit.
  testSync("derives a URL-safe key from an awkward group name", () => {
    expect(
      keysOf({components: [sel("Catalog")], journeys: [{group: "Ops Team/EU", components: []}]}),
    )->toEqual(["component-manifest.json", "component-manifest-ops-team-eu.json"])
  })

  testSync("carries each journey's own selections", () => {
    let files = BakedManifest.files(~config={
      components: [sel("Catalog")],
      journeys: [{group: "Fulfilment", components: [sel("Ordering")]}],
    })
    expect(files->Array.map(((_, sels)) => sels->Array.map(s => s.plugin)))->toEqual([
      ["Catalog"],
      ["Ordering"],
    ])
  })
})

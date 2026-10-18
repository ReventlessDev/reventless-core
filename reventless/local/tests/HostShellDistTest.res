open JestGlobals

// The one directory every local host-UI writer writes into. An app that composes
// its own UI bundle names it as `assetsDir`, as on AWS; a writer that took a
// second opinion would put its file where nothing serves it.

let _ = TestRunner.setup()

let tmpdir = prefix => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix]))

// What the package's dist/ holds, so a test can say it was not touched. Empty
// when the package is not installed where the test runs.
let snapshot = () =>
  HostShellDist.dir()
  ->Option.filter(NodeFs.existsSync)
  ->Option.mapOr([], dir =>
    NodeFs.readdirSyncNames(dir, {})
    ->Array.toSorted(String.compare)
    ->Array.map(name => {
      let path = NodePath.join([dir, name])
      (name, NodeFs.statSync(path)->NodeFs.mtimeMs)
    })
  )

describe("HostShellDist.resolve", () => {
  testSync("is the package's dist/ when no directory is chosen", () =>
    expect(HostShellDist.resolve(~assetsDir=None))->toEqual(HostShellDist.dir())
  )

  testSync("is the chosen directory, created when missing", () => {
    let chosen = NodePath.join([tmpdir("reventless-assetsdir-"), "app", "dist"])
    expect(HostShellDist.resolve(~assetsDir=Some(chosen)))->toEqual(Some(chosen))
    expect(NodeFs.existsSync(chosen))->toBe(true)
  })
})

describe("the local writers in a chosen assetsDir", () => {
  testSync("all four write there and leave the package's dist/ alone", () => {
    let before = snapshot()
    let dir =
      HostShellDist.resolve(
        ~assetsDir=Some(NodePath.join([tmpdir("reventless-assetsdir-"), "ui"])),
      )->Option.getOrThrow
    // The app's own config.json is the baseline the overlay goes on.
    NodeFs.writeFileSync(NodePath.join([dir, "config.json"]), `{"appName": "App"}`)
    let source = name => {
      let path = NodePath.join([tmpdir("reventless-assetsdir-src-"), name])
      NodeFs.writeFileSync(
        path,
        name->String.endsWith(".json") ? "{}" : "export function register() {}",
      )
      path
    }
    let bake: ReventlessInfra.Platform.bakedManifest = {components: []}

    ShellConfig.emit(~bakedManifest=Some(bake), ~shellConfig=None, ~dir)
    UiHints.emit(~uiHintsFile=Some(source("ui-hints.json")), ~dir)
    UiSlots.emit(~uiSlotsFile=Some(source("slots.js")), ~dir)
    BakedManifest.emit(~structures=[], ~config=bake, ~dir)

    expect(NodeFs.readdirSyncNames(dir, {})->Array.toSorted(String.compare))->toEqual([
      "component-manifest.json",
      "config.base.json",
      "config.json",
      "ui-hints.json",
      "ui-slots.js",
    ])
    expect(snapshot())->toEqual(before)
  })
})

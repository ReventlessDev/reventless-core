open JestGlobals

// The companion half of the runtime-extension seam: an extension declares the
// packages its runtime import graph reaches (`companionModuleUrls`), the
// bundler carries them into the archive, and the archive build fails loudly on
// any statically imported package that would not resolve at cold start. See
// docs/plans/done/runtime-extension-companion-packages.md.

// realpath because macOS hands out /var/... symlinks for tmpdir while the
// package-root walk reports paths as given.
let makePkg = (name: string, files: array<(string, string)>): string => {
  let root = NodeFs.realpathSync(NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "rt-ext-"])))
  NodeFs.writeFileSync(
    NodePath.join([root, "package.json"]),
    `{"name":"${name}","version":"1.0.0"}`,
  )
  files->Array.forEach(((relPath, content)) => {
    let abs = NodePath.join([root, relPath])
    NodeFs.mkdirSync(NodePath.dirname(abs), {recursive: true})
    NodeFs.writeFileSync(abs, content)
  })
  root
}

let fileUrl = (absPath: string) => "file://" ++ absPath

let extensionModule = (~companions: array<string>=[], url: string): module(
  ReventlessCore.RuntimeExtension.Extension
) => {
  module E = {
    let moduleUrl = url
    let companionModuleUrls = companions
    let onColdStart = (~runtimeKind as _, ~component as _, ~plugin as _, ~platform as _) => ()
  }
  module(E: ReventlessCore.RuntimeExtension.Extension)
}

let caughtMessage = (run: unit => unit): option<string> =>
  try {
    run()
    None
  } catch {
  | exn => Some(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(""))
  }

// One extension package whose artifact imports its companion plus one specifier
// from every runtime-provided class the guard must wave through: a node:
// builtin, a bare builtin, a framework dependency (the layer approximation),
// and the @aws-sdk scope (runtime SDK dir).
let extPkgName = "@fixture/runtime-ext"
let companionPkgName = "@fixture/runtime-ext-companion"
let extRoot = makePkg(
  extPkgName,
  [
    (
      "src/Ext_Extension.res.mjs",
      `import * as Companion from "${companionPkgName}";
import * as Fs from "node:fs";
import * as Path from "path";
import * as Effect from "effect";
import * as Ddb from "@aws-sdk/client-dynamodb";
export const moduleUrl = import.meta.url;
export const onColdStart = () => Companion.mark(Fs, Path, Effect, Ddb);
`,
    ),
  ],
)
let companionRoot = makePkg(
  companionPkgName,
  [
    (
      "src/Companion.res.mjs",
      `export const moduleUrl = import.meta.url;
export const mark = (x) => x;
`,
    ),
  ],
)
let extUrl = fileUrl(NodePath.join([extRoot, "src/Ext_Extension.res.mjs"]))
let companionUrl = fileUrl(NodePath.join([companionRoot, "src/Companion.res.mjs"]))

let badPkgName = "@fixture/runtime-ext-bad"
let badRoot = makePkg(
  badPkgName,
  [
    (
      "src/Bad_Extension.res.mjs",
      `import * as Missing from "@fixture/never-declared";
export const moduleUrl = import.meta.url;
export const onColdStart = () => Missing.x;
`,
    ),
  ],
)
let badUrl = fileUrl(NodePath.join([badRoot, "src/Bad_Extension.res.mjs"]))

let build = () =>
  Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/Entry.res.mjs",
    ~packageDirs=Dict.make(),
  )

describe("Util_Bundle — runtime-extension companion packages", () => {
  beforeEach(() => ReventlessCore.RuntimeExtension.reset())
  afterAll(() => {
    ReventlessCore.RuntimeExtension.reset()
    [extRoot, companionRoot, badRoot]->Array.forEach(root =>
      NodeFs.rmSync(root, {recursive: true, force: true})
    )
  })

  testSync("a declared companion package is added to the archive's package set", () => {
    ReventlessCore.RuntimeExtension.use(extensionModule(~companions=[companionUrl], extUrl))

    let packageDirs: dict<string> = Dict.make()
    let added = Util_Bundle.addRuntimeExtensionPackages(packageDirs)

    expect(packageDirs->Dict.get(extPkgName))->toEqual(Some(extRoot))
    expect(packageDirs->Dict.get(companionPkgName))->toEqual(Some(companionRoot))
    // The returned set — what the import guard scans — matches what was added.
    expect(added->Dict.keysToArray->Array.toSorted(String.compare))->toEqual([
      extPkgName,
      companionPkgName,
    ])
  })

  testSync("the archive builds when every import is declared or runtime-provided", () => {
    ReventlessCore.RuntimeExtension.use(extensionModule(~companions=[companionUrl], extUrl))
    expect(build().sourceCodeHash->String.length > 0)->toBe(true)
  })

  testSync("sourceCodeHash shifts when the companion's content shifts", () => {
    ReventlessCore.RuntimeExtension.use(extensionModule(~companions=[companionUrl], extUrl))
    let before = build().sourceCodeHash

    let companionFile = NodePath.join([companionRoot, "src/Companion.res.mjs"])
    let original = NodeFs.readFileSync(companionFile)
    NodeFs.writeFileSync(
      companionFile,
      original ++ "export const changed = true;\n",
    )
    let after = build().sourceCodeHash
    NodeFs.writeFileSync(companionFile, original)

    expect(before == after)->toBe(false)
  })

  testSync("an empty registry leaves the archive byte-identical", () => {
    let withSeam = build().sourceCodeHash
    let withoutSeam =
      Util_Bundle.buildCodeArchive(
        ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/Entry.res.mjs",
        ~packageDirs=Dict.make(),
        ~bundleRuntimeExtensions=false,
      ).sourceCodeHash
    expect(withSeam)->toBe(withoutSeam)
  })

  testSync("an undeclared, un-bundled import fails the archive build, naming the remedy", () => {
    ReventlessCore.RuntimeExtension.use(extensionModule(badUrl))

    switch caughtMessage(() => {
      let _ = build()
    }) {
    | None => JsError.throwWithMessage("expected buildCodeArchive to throw")
    | Some(message) =>
      expect(message->String.includes(badPkgName))->toBe(true)
      expect(message->String.includes("@fixture/never-declared"))->toBe(true)
      expect(message->String.includes("companionModuleUrls"))->toBe(true)
    }
  })
})

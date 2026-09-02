open JestGlobals

// A plugin package rides in the code archive, but its own dependencies used to
// stay behind: the layer carries reventless-aws's closure, and a domain trait
// (or any other plugin-level library) is outside it. The archive build now
// walks what a bundled user package actually imports.

let mkTmpRoot = (prefix: string) =>
  NodeFs.realpathSync(NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), prefix])))

let writePkg = (~root: string, ~name: string, files: array<(string, string)>): string => {
  NodeFs.mkdirSync(root, {recursive: true})
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

// A user package whose slice imports a trait, the trait imports a rules
// package, and both are installed only under the user package — the pnpm shape,
// where nothing but the importer can resolve them.
let hostName = "@fixture/closure-host"
let traitName = "@fixture/closure-trait"
let rulesName = "@fixture/closure-rules"

let hostRoot = mkTmpRoot("bundle-closure-")
let traitRoot = NodePath.join([hostRoot, "node_modules", traitName])
let rulesRoot = NodePath.join([hostRoot, "node_modules", rulesName])

let _ = writePkg(
  ~root=hostRoot,
  ~name=hostName,
  [
    (
      "src/Slice.res.mjs",
      `import * as Trait from "${traitName}";
import * as Sury from "sury";
import * as Fs from "node:fs";
import * as Path from "path";
import * as Ddb from "@aws-sdk/client-dynamodb";
import * as Missing from "@fixture/never-installed";
export const handle = () => Trait.rule(Sury, Fs, Path, Ddb, Missing);
`,
    ),
  ],
)
let _ = writePkg(
  ~root=traitRoot,
  ~name=traitName,
  [
    (
      "src/Trait.res.mjs",
      `import * as Rules from "${rulesName}";
export const rule = () => Rules.check();
`,
    ),
  ],
)
let _ = writePkg(~root=rulesRoot, ~name=rulesName, [("src/Rules.res.mjs", `export const check = () => true;
`)])

let closureOf = (packageDirs: dict<string>) => {
  Util_Bundle.addImportedPackageClosure(packageDirs)
  packageDirs
}

describe("Util_Bundle — bundled user packages carry their imports", () => {
  afterAll(() => NodeFs.rmSync(hostRoot, {recursive: true, force: true}))

  testSync("a dependency only the importing package can resolve is added", () => {
    let packageDirs = Dict.fromArray([(hostName, hostRoot)])
    expect(closureOf(packageDirs)->Dict.get(traitName))->toEqual(Some(traitRoot))
  })

  testSync("the walk is transitive — the dependency's own imports come too", () => {
    let packageDirs = Dict.fromArray([(hostName, hostRoot)])
    expect(closureOf(packageDirs)->Dict.get(rulesName))->toEqual(Some(rulesRoot))
  })

  testSync("packages the deployed runtime provides are left out", () => {
    let packageDirs = Dict.fromArray([(hostName, hostRoot)])
    let bundled = closureOf(packageDirs)->Dict.keysToArray
    // sury rides in the layer (framework-resolvable); node builtins and the
    // @aws-sdk scope resolve from the runtime's own dirs.
    expect(bundled->Array.includes("sury"))->toBe(false)
    expect(bundled->Array.includes("fs"))->toBe(false)
    expect(bundled->Array.includes("path"))->toBe(false)
    expect(bundled->Array.includes("@aws-sdk/client-dynamodb"))->toBe(false)
  })

  testSync("an import that resolves nowhere is skipped, not thrown on", () => {
    let packageDirs = Dict.fromArray([(hostName, hostRoot)])
    let bundled = closureOf(packageDirs)->Dict.keysToArray
    expect(bundled->Array.includes("@fixture/never-installed"))->toBe(false)
  })

  testSync("framework packages are starting points, not walked", () => {
    // Walking reventless-aws would reach its deploy-time-only imports (the
    // @pulumi bindings) and add tens of megabytes to every archive.
    let packageDirs = Dict.fromArray([
      ("@reventlessdev/reventless-aws", Util_Bundle.resolvePackageRoot("@reventlessdev/reventless-aws")),
    ])
    expect(closureOf(packageDirs)->Dict.keysToArray->Array.length)->toBe(1)
  })
})

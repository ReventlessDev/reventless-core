// Node.js path bindings
@module("path") external dirname: string => string = "dirname"
@module("path") external join2: (string, string) => string = "join"
@module("path") external relative: (string, string) => string = "relative"

// Node.js fs bindings
@module("fs") external existsSync: string => bool = "existsSync"
@module("fs") external readFileSync: (string, string) => string = "readFileSync"
type dirent
@module("fs") external readdirSync: (string, {"withFileTypes": bool}) => array<dirent> = "readdirSync"
@send external isDirectory: dirent => bool = "isDirectory"
@get external direntName: dirent => string = "name"

// Node.js crypto bindings
type hashObj
@module("crypto") external createHash: string => hashObj = "createHash"
@send external update: (hashObj, string) => hashObj = "update"
@send external digest: (hashObj, string) => string = "digest"

// URL global
type urlObj
@new external newURL: string => urlObj = "URL"
@get external pathname: urlObj => string = "pathname"

// module.createRequire
type requireFn
@module("module") external createRequire: string => requireFn = "createRequire"
@send external requireResolve: (requireFn, string) => string = "resolve"

// process.cwd
@val @scope("process") external cwd: unit => string = "cwd"

// Module-level state: cache populated by getModuleSpecifier
let packageRootCache: dict<string> = Dict.make()
let localRequire: requireFn = createRequire(%raw("import.meta.url"))

/**
 * Convert an import.meta.url file URL to an npm module specifier.
 * Walks up from the file to find the nearest package.json, reads the package name,
 * and constructs the npm specifier from packageName + relative path.
 */
let getModuleSpecifier = (importMetaUrl: string): string => {
  if !(importMetaUrl->String.startsWith("file://")) {
    importMetaUrl
  } else {
    let filePath = newURL(importMetaUrl)->pathname
    let dirRef = ref(dirname(filePath))
    let resultRef: ref<option<string>> = ref(None)
    while dirRef.contents != "/" && resultRef.contents->Option.isNone {
      let dir = dirRef.contents
      let pkgPath = join2(dir, "package.json")
      if existsSync(pkgPath) {
        let pkgText = readFileSync(pkgPath, "utf-8")
        switch pkgText->JSON.parseOrThrow->JSON.Decode.object {
        | Some(obj) =>
          switch obj->Dict.get("name")->Option.flatMap(JSON.Decode.string) {
          | Some(pkgName) =>
            packageRootCache->Dict.set(pkgName, dir)
            let relPath = relative(dir, filePath)
            resultRef := Some(pkgName ++ "/" ++ relPath)
          | None => dirRef := dirname(dir)
          }
        | None => dirRef := dirname(dir)
        }
      } else {
        dirRef := dirname(dir)
      }
    }
    switch resultRef.contents {
    | Some(specifier) => specifier
    | None => JsError.throwWithMessage(`No package.json found for ${filePath}`)
    }
  }
}

/**
 * Extract the npm package name from a module specifier.
 * Handles scoped packages (@scope/pkg/path) and unscoped (pkg/path).
 */
let extractPackageName = (specifier: string): string => {
  let parts = specifier->String.split("/")
  if specifier->String.startsWith("@") {
    parts->Array.getUnsafe(0) ++ "/" ++ parts->Array.getUnsafe(1)
  } else {
    parts->Array.getUnsafe(0)
  }
}

/**
 * Resolve the root directory of an npm package.
 * Fast path: populated by getModuleSpecifier when it walks the package tree.
 */
let resolvePackageRoot = (packageName: string): string => {
  switch packageRootCache->Dict.get(packageName) {
  | Some(cachedRoot) => cachedRoot
  | None =>
    try {
      let pkgJsonPath = localRequire->requireResolve(packageName ++ "/package.json")
      dirname(pkgJsonPath)
    } catch {
    | _ =>
      let cwdRequire = createRequire(cwd() ++ "/index.js")
      let pkgJsonPath = cwdRequire->requireResolve(packageName ++ "/package.json")
      dirname(pkgJsonPath)
    }
  }
}

/**
 * Compute a SHA256 hash of a string, returned as base64.
 */
let hashString = (str: string): string =>
  createHash("sha256")->update(str)->digest("base64")

let isSkippedDir = (n: string) =>
  n == "node_modules" ||
  n == "lib" ||
  n == "tests" ||
  n == "test" ||
  n == "__mocks__" ||
  n == "__tests__" ||
  n == ".git" ||
  n == "coverage"

let rec walkDir = (dir: string, prefix: string, assets: dict<Pulumi.Archive.assetOrArchive>) => {
  let entries = readdirSync(dir, {"withFileTypes": true})
  entries->Array.forEach(entry => {
    let entryName = entry->direntName
    if entry->isDirectory {
      if !isSkippedDir(entryName) {
        let newPrefix = prefix == "" ? entryName : prefix ++ "/" ++ entryName
        walkDir(join2(dir, entryName), newPrefix, assets)
      }
    } else if entryName == "package.json" || entryName->String.endsWith(".mjs") {
      let relPath = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      assets->Dict.set(
        relPath,
        Pulumi.Asset.fileAsset(join2(dir, entryName))->Pulumi.Archive.assetToAssetOrArchive,
      )
    }
  })
}

/**
 * Create a filtered AssetArchive from a package directory.
 * Only includes *.mjs and package.json; excludes node_modules/, lib/, tests/, etc.
 */
let createFilteredPackageArchive = (packageRoot: string): Pulumi.Archive.t => {
  let assets: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  walkDir(packageRoot, "", assets)
  Pulumi.Archive.assetArchive(assets)
}

type codeArchive = {
  code: Pulumi.Archive.t,
  sourceCodeHash: string,
}

/**
 * Build a Lambda code AssetArchive with a static re-export entry point and optional user packages.
 * Centralises the archive-building pattern used by every runtime builder.
 */
let buildCodeArchive = (~entryPointModule: string, ~packageDirs: dict<string>): codeArchive => {
  let reExportCode = `export { handler } from "${entryPointModule}";`
  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  archiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
  )
  packageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
    archiveContents->Dict.set(
      `node_modules/${pkgName}`,
      createFilteredPackageArchive(pkgRoot)->Pulumi.Archive.archiveToAssetOrArchive,
    )
  })
  let code = Pulumi.Archive.assetArchive(archiveContents)
  let sourceCodeHash = hashString(reExportCode ++ packageDirs->Dict.keysToArray->Array.join(","))
  {code, sourceCodeHash}
}

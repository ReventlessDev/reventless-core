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
  n == "cjs" ||
  n == "dts" ||
  n == "tests" ||
  n == "test" ||
  n == "__mocks__" ||
  n == "__tests__" ||
  n == ".git" ||
  n == "coverage"

// Reads file as a string for content hashing; Buffer would be slightly more
// efficient but utf-8 keeps the hash stable across platforms and matches what
// Lambda will execute.
@module("fs") external readFileAsString: (string, string) => string = "readFileSync"

let rec walkDir = (
  ~dir: string,
  ~prefix: string,
  ~assets: dict<Pulumi.Archive.assetOrArchive>,
  ~paths: array<(string, string)>,
) => {
  let entries = readdirSync(dir, {"withFileTypes": true})
  entries->Array.forEach(entry => {
    let entryName = entry->direntName
    if entry->isDirectory {
      if !isSkippedDir(entryName) {
        let newPrefix = prefix == "" ? entryName : prefix ++ "/" ++ entryName
        walkDir(~dir=join2(dir, entryName), ~prefix=newPrefix, ~assets, ~paths)
      }
    } else if entryName == "package.json" || entryName->String.endsWith(".mjs") || entryName->String.endsWith(".js") {
      let relPath = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      let absPath = join2(dir, entryName)
      assets->Dict.set(
        relPath,
        Pulumi.Asset.fileAsset(absPath)->Pulumi.Archive.assetToAssetOrArchive,
      )
      paths->Array.push((relPath, absPath))
    }
  })
}

/**
 * Create a filtered AssetArchive from a package directory.
 * Only includes *.mjs and package.json; excludes node_modules/, lib/, tests/, etc.
 * Returns both the archive and a content hash covering every bundled file so
 * callers can produce a sourceCodeHash that changes when any source changes.
 */
let createFilteredPackageArchive = (packageRoot: string): (Pulumi.Archive.t, string) => {
  let assets: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  let paths: array<(string, string)> = []
  walkDir(~dir=packageRoot, ~prefix="", ~assets, ~paths)
  // Sort so the hash is stable across filesystem traversal order.
  paths->Array.sort(((a, _), (b, _)) => String.compare(a, b))
  let combined =
    paths
    ->Array.map(((relPath, absPath)) => `${relPath}:${readFileAsString(absPath, "utf-8")}`)
    ->Array.join("\n---\n")
  (Pulumi.Archive.assetArchive(assets), hashString(combined))
}

type codeArchive = {
  code: Pulumi.Archive.t,
  sourceCodeHash: string,
}

/**
 * Build a Lambda code AssetArchive with a static re-export entry point and optional user packages.
 * Centralises the archive-building pattern used by every runtime builder.
 *
 * When @reventlessdev/reventless-aws is bundled, effect is automatically co-bundled.
 * The entry points in reventless-aws import effect statically, and ESM resolution
 * walks up from /var/task/node_modules/reventless-aws/... — it never reaches the
 * Lambda layer at /opt/nodejs/node_modules. Bundling effect alongside ensures it
 * is found at /var/task/node_modules/effect.
 */
let buildCodeArchive = (
  ~entryPointModule: string,
  ~packageDirs: dict<string>,
  // Extra string-typed assets to drop at the root of the asset zip. Keys are
  // filenames (e.g. "pluginDefinition.json"); values are the file contents.
  // The Lambda runtime extracts the zip to /var/task, so entry-point code can
  // read each file via `readFileSync("/var/task/<filename>", "utf-8")` or
  // (preferred) `readFileSync(new URL("./<filename>", import.meta.url))`.
  // Used to ship payloads that would otherwise blow the 5120-byte
  // UpdateFunctionConfiguration limit when packed into HANDLER_CONFIG.
  ~extraStringAssets: dict<string>=Dict.make(),
): codeArchive => {
  let reExportCode = `export { handler } from "${entryPointModule}";`
  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  archiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
  )
  extraStringAssets->Dict.forEachWithKey((content, fileName) => {
    archiveContents->Dict.set(
      fileName,
      Pulumi.Asset.stringAsset(content)->Pulumi.Archive.assetToAssetOrArchive,
    )
  })
  // Co-bundle effect whenever reventless-aws is bundled (see comment above).
  let allPackageDirs =
    if packageDirs->Dict.has("@reventlessdev/reventless-aws") &&
      !(packageDirs->Dict.has("effect")) {
      let dirs = packageDirs->Dict.copy
      dirs->Dict.set("effect", resolvePackageRoot("effect"))
      dirs
    } else {
      packageDirs
    }
  let packageContentHashes: ref<array<string>> = ref([])
  allPackageDirs->Dict.forEachWithKey((pkgRoot, pkgName) => {
    let (archive, contentHash) = createFilteredPackageArchive(pkgRoot)
    archiveContents->Dict.set(
      `node_modules/${pkgName}`,
      archive->Pulumi.Archive.archiveToAssetOrArchive,
    )
    packageContentHashes.contents->Array.push(`${pkgName}:${contentHash}`)
  })
  // Extra-asset content participates in the source hash so a change to
  // pluginDefinition.json triggers a Lambda code update.
  let extraHashEntries: array<string> = []
  let extraKeys = extraStringAssets->Dict.keysToArray
  extraKeys->Array.sort(String.compare)
  extraKeys->Array.forEach(k => {
    let v = extraStringAssets->Dict.get(k)->Option.getOr("")
    extraHashEntries->Array.push(`${k}:${v}`)
  })
  let code = Pulumi.Archive.assetArchive(archiveContents)
  packageContentHashes.contents->Array.sort(String.compare)
  let sourceCodeHash =
    hashString(
      reExportCode ++
      "\n---\n" ++
      packageContentHashes.contents->Array.join(",") ++
      "\n---\n" ++
      extraHashEntries->Array.join("\n"),
    )
  {code, sourceCodeHash}
}

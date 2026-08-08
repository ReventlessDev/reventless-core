// URL global
type urlObj
@new external newURL: string => urlObj = "URL"
@get external pathname: urlObj => string = "pathname"

// Module-level state: cache populated by getModuleSpecifier
let packageRootCache: dict<string> = Dict.make()
let localRequire: NodeModule.require = NodeModule.createRequire(%raw("import.meta.url"))

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
    let dirRef = ref(NodePath.dirname(filePath))
    let resultRef: ref<option<string>> = ref(None)
    while dirRef.contents != "/" && resultRef.contents->Option.isNone {
      let dir = dirRef.contents
      let pkgPath = NodePath.join([dir, "package.json"])
      if NodeFs.existsSync(pkgPath) {
        let pkgText = NodeFs.readFileSync(pkgPath)
        switch pkgText->JSON.parseOrThrow->JSON.Decode.object {
        | Some(obj) =>
          switch obj->Dict.get("name")->Option.flatMap(JSON.Decode.string) {
          | Some(pkgName) =>
            packageRootCache->Dict.set(pkgName, dir)
            let relPath = NodePath.relative(dir, filePath)
            resultRef := Some(pkgName ++ "/" ++ relPath)
          | None => dirRef := NodePath.dirname(dir)
          }
        | None => dirRef := NodePath.dirname(dir)
        }
      } else {
        dirRef := NodePath.dirname(dir)
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
 *
 * Two rootings, because two different questions are being asked.
 *
 * The default resolves from this framework module. That is right for anything
 * the framework itself depends on and then packages — a Lambda's runtime deps
 * are reventless-aws's own, and the version reventless-aws was built against is
 * the version that must ship.
 *
 * `~fromPulumiProject=true` resolves from the Pulumi project's directory
 * instead (`pulumi up --cwd <project>` runs the program there), which is what a
 * *deploy input* needs: an asset the project names in its own package.json and
 * the framework merely uploads. The framework has no dependency on it, so a
 * framework-rooted lookup skips the project's pin entirely and walks up to
 * whatever the workspace hoisted — which is how a platform pinning
 * host-shell 3.0.0-alpha.49 deployed 3.0.0-alpha.48 while four sibling examples
 * pinned the older one. Node still walks up from the project, so a project that
 * declares nothing keeps resolving exactly as before.
 *
 * The two are cached under separate keys: they are allowed to disagree, and
 * that disagreement is the whole point.
 */
let resolvePackageRoot = (~fromPulumiProject: bool=false, packageName: string): string => {
  let cacheKey = fromPulumiProject ? "pulumi-project:" ++ packageName : packageName
  switch packageRootCache->Dict.get(cacheKey) {
  | Some(cachedRoot) => cachedRoot
  | None =>
    let request = packageName ++ "/package.json"
    let viaFramework = () => NodePath.dirname(localRequire->NodeModule.requireResolve(request))
    let viaPulumiProject = () =>
      NodePath.dirname(
        NodeModule.createRequire(NodeProcess.cwd() ++ "/index.js")
        ->NodeModule.requireResolve(request),
      )
    let (preferred, fallback) = fromPulumiProject
      ? (viaPulumiProject, viaFramework)
      : (viaFramework, viaPulumiProject)
    let root = try preferred() catch {
    | _ => fallback()
    }
    packageRootCache->Dict.set(cacheKey, root)
    root
  }
}

/**
 * Compute a SHA256 hash of a string, returned as base64.
 */
let hashString = (str: string): string =>
  NodeCrypto.createHash("sha256")->NodeCrypto.hashUpdate(str)->NodeCrypto.hashDigest("base64")

// ── ESM self-containment loader (Option C) ──────────────────────────────────
// Deployed Lambda entry points are ESM (`.mjs`) and statically/dynamically import
// bare specifiers (`@reventlessdev/*`, `effect`, `sury`, `@aws-sdk/*`) that live in
// the attached layer at /opt/nodejs/node_modules or the runtime SDK dir. ESM
// `import` ignores NODE_PATH and /opt, so those imports fail from /var/task with
// ERR_MODULE_NOT_FOUND. These two files install a `resolve` hook that, on an
// unresolved bare specifier, retries against each dir named in ESM_FALLBACK_DIRS
// (set on the Lambda env by RuntimeEnvironment_Lambda.makeFromCodeAsset). Shipped
// at the root of every code archive; NODE_OPTIONS=--import points Node at
// register-hook.mjs. Validated on a Node 22.17.1 rig; see
// docs/plans/deployed-lambda-esm-self-containment.md.
let registerHookFileName = "register-hook.mjs"
let layerResolverFileName = "layer-resolver.mjs"

let registerHookSource = `import { register } from "node:module";
register("./${layerResolverFileName}", import.meta.url);
`

let layerResolverSource = `// Fallback dirs (real Lambda: /opt/nodejs for the layer, /var/runtime for the SDK).
// Passed via env so the same hook is testable locally.
const FALLBACKS = (process.env.ESM_FALLBACK_DIRS || "").split(":").filter(Boolean);
export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (err) {
    const bare = !/^[./]|^file:|^node:/.test(specifier);
    if (err?.code !== "ERR_MODULE_NOT_FOUND" || !bare) throw err;
    for (const dir of FALLBACKS) {
      try {
        // Re-resolve as if imported from a virtual file inside the fallback dir,
        // so Node's own node_modules walk finds it (honours package.json exports).
        const parentURL = new URL("file://" + dir + "/__resolver__.mjs").href;
        return await nextResolve(specifier, { ...context, parentURL });
      } catch { /* try next fallback */ }
    }
    throw err;
  }
}
`

// Env vars that activate the loader. Any Lambda whose archive includes the loader
// files (via addEsmLoaderAssets / buildCodeArchive) MUST also set these two; any
// that does NOT ship the loader MUST NOT set NODE_OPTIONS (it would --import a
// missing file and fail cold start). --import registers the resolve hook;
// ESM_FALLBACK_DIRS names the layer (/opt/nodejs) and runtime-SDK (/var/runtime)
// node_modules dirs the hook retries against for @aws-sdk/*.
let esmLoaderNodeOptions = `--import file:///var/task/${registerHookFileName}`
let esmFallbackDirs = "/opt/nodejs/node_modules:/var/runtime/node_modules"

/**
 * Add the ESM self-containment loader files to an archive-contents dict and return
 * a hash fragment so callers can fold them into their sourceCodeHash. Every code
 * archive whose Lambda sets the esmLoader env vars MUST include these files.
 */
let addEsmLoaderAssets = (archiveContents: dict<Pulumi.Archive.assetOrArchive>): string => {
  archiveContents->Dict.set(
    registerHookFileName,
    Pulumi.Asset.stringAsset(registerHookSource)->Pulumi.Archive.assetToAssetOrArchive,
  )
  archiveContents->Dict.set(
    layerResolverFileName,
    Pulumi.Asset.stringAsset(layerResolverSource)->Pulumi.Archive.assetToAssetOrArchive,
  )
  hashString(registerHookSource ++ "\n---\n" ++ layerResolverSource)
}

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

let rec walkDir = (
  ~dir: string,
  ~prefix: string,
  ~assets: dict<Pulumi.Archive.assetOrArchive>,
  ~paths: array<(string, string)>,
) => {
  let entries = NodeFs.readdirSync(dir, {withFileTypes: true})
  entries->Array.forEach(entry => {
    let entryName = entry->NodeFs.direntName
    if entry->NodeFs.isDirectory {
      if !isSkippedDir(entryName) {
        let newPrefix = prefix == "" ? entryName : prefix ++ "/" ++ entryName
        walkDir(~dir=NodePath.join([dir, entryName]), ~prefix=newPrefix, ~assets, ~paths)
      }
    } else if entryName == "package.json" || entryName->String.endsWith(".mjs") || entryName->String.endsWith(".js") {
      let relPath = prefix == "" ? entryName : prefix ++ "/" ++ entryName
      let absPath = NodePath.join([dir, entryName])
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
  // Read as a string rather than a Buffer: slightly less efficient, but utf-8
  // keeps the hash stable across platforms and matches what Lambda executes.
  let combined =
    paths
    ->Array.map(((relPath, absPath)) => `${relPath}:${NodeFs.readFileSync(absPath)}`)
    ->Array.join("\n---\n")
  (Pulumi.Archive.assetArchive(assets), hashString(combined))
}

type codeArchive = {
  code: Pulumi.Archive.t,
  sourceCodeHash: string,
}

/**
 * The module specifier of each registered runtime extension, in registration
 * order — what a deployed runtime imports at cold start. `[]` when nothing is
 * registered, which is what keeps an extension-free archive byte-identical.
 *
 * `ReventlessCore.RuntimeExtension` carries `import.meta.url`s because that is
 * what an extension module can state about itself; the npm specifier a Lambda
 * resolves is derived here, the same conversion spec and behavior modules go
 * through.
 */
let runtimeExtensionSpecifiers = (): array<string> =>
  ReventlessCore.RuntimeExtension.moduleUrls()->Array.map(getModuleSpecifier)

/**
 * Add every registered runtime extension's package to `packageDirs`, so the
 * archive carries the modules the entry shell imports at cold start.
 *
 * Rooted through `getModuleSpecifier`, which caches the package root it walked
 * to. That matters: an extension is an out-of-tree package the framework has no
 * dependency on, so a framework-rooted `require.resolve` would not find it.
 */
let addRuntimeExtensionPackages = (packageDirs: dict<string>) =>
  runtimeExtensionSpecifiers()->Array.forEach(specifier => {
    let pkgName = extractPackageName(specifier)
    packageDirs->Dict.set(pkgName, resolvePackageRoot(pkgName))
  })

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
  // Whether this archive carries the registered runtime extensions
  // (`ReventlessCore.RuntimeExtension`). Default-on, so a runtime builder added
  // later gets the seam by construction rather than by remembering — the same
  // reason `EventLogProvisioning` fires from the builders and not from each
  // storage adapter. Support Lambdas that never fire the seam pass `false`
  // rather than carry modules they will not import.
  ~bundleRuntimeExtensions: bool=true,
): codeArchive => {
  let reExportCode = `export { handler } from "${entryPointModule}";`
  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  archiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(reExportCode)->Pulumi.Archive.assetToAssetOrArchive,
  )
  // ESM self-containment loader — shipped in every archive (see addEsmLoaderAssets).
  let loaderHash = addEsmLoaderAssets(archiveContents)
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
  // Registered runtime extensions ride along, so the entry shell can import them
  // at cold start. No-op when nothing is registered — the archive, and therefore
  // `sourceCodeHash`, is unchanged.
  if bundleRuntimeExtensions {
    allPackageDirs->addRuntimeExtensionPackages
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
      extraHashEntries->Array.join("\n") ++
      "\n---\n" ++
      loaderHash,
    )
  {code, sourceCodeHash}
}

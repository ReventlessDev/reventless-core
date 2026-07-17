open JestGlobals

// Guards the ESM self-containment loader (Option C) against silent drift. The
// load-bearing contract: every code archive that ships the loader files MUST set
// NODE_OPTIONS=--import pointing at the shipped register-hook.mjs, and the two
// files must keep cross-referencing each other by the exact filenames used here.
// See docs/plans/deployed-lambda-esm-self-containment.md.

describe("Util_Bundle ESM loader — env-var contract", () => {
  testSync("NODE_OPTIONS --imports the shipped register-hook file by name", () => {
    expect(Util_Bundle.esmLoaderNodeOptions)->toBe(
      `--import file:///var/task/${Util_Bundle.registerHookFileName}`,
    )
  })

  testSync("fallback dirs cover both the layer and the runtime SDK dir", () => {
    // @aws-sdk/* lives in the runtime dir; @reventlessdev/*, effect, sury in the layer.
    expect(Util_Bundle.esmFallbackDirs->String.includes("/opt/nodejs/node_modules"))->toBe(true)
    expect(Util_Bundle.esmFallbackDirs->String.includes("/var/runtime/node_modules"))->toBe(true)
  })
})

describe("Util_Bundle ESM loader — file cross-references", () => {
  testSync("register-hook registers exactly the layer-resolver filename", () => {
    expect(Util_Bundle.registerHookSource->String.includes(Util_Bundle.layerResolverFileName))->toBe(
      true,
    )
    expect(Util_Bundle.registerHookSource->String.includes("register("))->toBe(true)
  })

  testSync("layer-resolver retries only bare specifiers on ERR_MODULE_NOT_FOUND", () => {
    expect(Util_Bundle.layerResolverSource->String.includes("ESM_FALLBACK_DIRS"))->toBe(true)
    expect(Util_Bundle.layerResolverSource->String.includes("ERR_MODULE_NOT_FOUND"))->toBe(true)
    // The resolve hook is the exported entry point Node's loader calls.
    expect(Util_Bundle.layerResolverSource->String.includes("export async function resolve"))->toBe(
      true,
    )
  })
})

describe("Util_Bundle.addEsmLoaderAssets", () => {
  testSync("injects both loader files at the archive root", () => {
    let contents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    let _ = Util_Bundle.addEsmLoaderAssets(contents)
    expect(contents->Dict.has(Util_Bundle.registerHookFileName))->toBe(true)
    expect(contents->Dict.has(Util_Bundle.layerResolverFileName))->toBe(true)
  })

  testSync("returns a stable, non-empty hash fragment", () => {
    let a: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    let b: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
    let hashA = Util_Bundle.addEsmLoaderAssets(a)
    let hashB = Util_Bundle.addEsmLoaderAssets(b)
    expect(hashA->String.length > 0)->toBe(true)
    expect(hashA)->toBe(hashB)
  })
})

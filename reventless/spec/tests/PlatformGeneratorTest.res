open JestGlobals

// `generate-platform <deploy-manifest.yaml>` runs in every AWS platform's build.

describe("PlatformGenerator.parseArgs", () => {
  testSync("a platform's build: generate-platform ../deploy-manifest.yaml", () =>
    expect(PlatformGenerator.parseArgs(["../deploy-manifest.yaml"]))->toEqual(
      Ok({PlatformGenerator.manifest: "../deploy-manifest.yaml"}),
    )
  )

  testSync("no manifest is refused", () =>
    expect(PlatformGenerator.parseArgs([])->Result.isError)->toBe(true)
  )
})

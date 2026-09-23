open JestGlobals

// `emit-capabilities <srcDir> [<compositionModule>]` runs in the `postbuild` of
// every plugin package.

describe("EmitCapabilities.parseArgs", () => {
  testSync("a plugin's postbuild: emit-capabilities src/", () =>
    expect(EmitCapabilities.parseArgs(["src/"]))->toEqual(
      Ok({EmitCapabilities.srcDir: "src/", compositionModule: None}),
    )
  )

  testSync("a hand-written composition root is named after the source directory", () =>
    expect(EmitCapabilities.parseArgs(["src", "Catalog"]))->toEqual(
      Ok({EmitCapabilities.srcDir: "src", compositionModule: Some("Catalog")}),
    )
  )

  testSync("no source directory is refused", () =>
    expect(EmitCapabilities.parseArgs([])->Result.isError)->toBe(true)
  )
})

describe("emit-capabilities on the command line", () => {
  module CliArgs = Reventless.CliArgs
  let usage = EmitCapabilities.usage->String.trim

  test("--help anywhere prints the usage to stdout and exits 0", async () =>
    expect(await CliArgs.observe(EmitCapabilities.cli, ["src/", "--help"]))->toEqual({
      CliArgs.stdout: [usage],
      stderr: [],
      exitCode: Some(0),
      reachedMain: false,
    })
  )

  test("a usage mistake names itself, shows the usage on stderr and exits 2", async () =>
    expect(await CliArgs.observe(EmitCapabilities.cli, ["src", "Catalog", "extra"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [`emit-capabilities: unknown argument "extra"\n\n${usage}`],
      exitCode: Some(2),
      reachedMain: false,
    })
  )
})

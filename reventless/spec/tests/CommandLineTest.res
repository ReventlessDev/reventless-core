open JestGlobals

// How this package's bins behave on the command line, as a person or a script
// meets them: help anywhere answers with the usage and exit 0, a usage mistake
// names itself and shows the usage on stderr with exit 2. Exit 1 is left to a
// run that failed, so a caller can tell the two apart.

let answersLikeEveryTool = (cli: CliArgs.cli<'args>, ~mistake, ~message) =>
  test(`${cli.bin}: --help and a usage mistake`, async () => {
    let usage = cli.usage->String.trim
    expect(usage->String.startsWith(`Usage: ${cli.bin} `))->toBe(true)
    let help = {CliArgs.stdout: [usage], stderr: [], exitCode: Some(0), reachedMain: false}
    expect(await CliArgs.observe(cli, ["-h"]))->toEqual(help)
    // Help wins, and not only as the first argument.
    expect(await CliArgs.observe(cli, mistake->Array.concat(["--help"])))->toEqual(help)
    expect(await CliArgs.observe(cli, mistake))->toEqual({
      CliArgs.stdout: [],
      stderr: [`${cli.bin}: ${message}\n\n${usage}`],
      exitCode: Some(2),
      reachedMain: false,
    })
  })

let firstLineOfError = async (cli, argv) => {
  let observed = await CliArgs.observe(cli, argv)
  (
    observed.exitCode,
    observed.stderr->Array.get(0)->Option.map(e => e->String.split("\n")->Array.getUnsafe(0)),
  )
}

describe("every bin", () => {
  answersLikeEveryTool(
    PrepareAccounts.cli,
    ~mistake=["--prepare-only"],
    ~message=`unknown argument "--prepare-only"`,
  )
  // Once ignored: a typo in a flag it did not ask for ran silently.
  answersLikeEveryTool(
    TraitManifestCli.cli,
    ~mistake=["t", "--out", "m.yaml", "--verbose"],
    ~message=`unknown argument "--verbose"`,
  )
  // Once reported as "--host, --report and --out are all required", never
  // naming the typo.
  answersLikeEveryTool(
    CertifyTrait.cli,
    ~mistake=["t", "--hots", "api", "--report", "r.json", "--out", "o"],
    ~message=`unknown argument "--hots"`,
  )
  // Every undeclared long flag is a config field here, so the mistake is a
  // short one.
  answersLikeEveryTool(
    GraftTrait.cli,
    ~mistake=["t", "--into", "src", "--tests", "tests", "-x"],
    ~message=`unknown argument "-x"`,
  )
  // Once took `-h` as its source directory.
  answersLikeEveryTool(
    PluginGenerator.cli,
    ~mistake=["src/", "extra"],
    ~message=`unknown argument "extra"`,
  )
  answersLikeEveryTool(
    PlatformGenerator.cli,
    ~mistake=["../deploy-manifest.yaml", "--aws"],
    ~message=`unknown argument "--aws"`,
  )
  answersLikeEveryTool(
    CheckLifecycleModel.cli,
    ~mistake=["--reuse-sidecar"],
    ~message=`unknown argument "--reuse-sidecar"`,
  )
})

describe("a bare invocation", () => {
  test("a tool that needs something reports the first thing missing", async () => {
    expect(await firstLineOfError(TraitManifestCli.cli, []))->toEqual((
      Some(2),
      Some("trait-manifest: <trait-package> is required."),
    ))
    expect(await firstLineOfError(CertifyTrait.cli, []))->toEqual((
      Some(2),
      Some("certify-trait: <trait-package> is required."),
    ))
    expect(await firstLineOfError(GraftTrait.cli, []))->toEqual((
      Some(2),
      Some("graft-trait: <trait-package> is required."),
    ))
    expect(await firstLineOfError(PluginGenerator.cli, []))->toEqual((
      Some(2),
      Some("generate-plugin: <srcDir> is required."),
    ))
    expect(await firstLineOfError(PlatformGenerator.cli, []))->toEqual((
      Some(2),
      Some("generate-platform: <deploy-manifest.yaml> is required."),
    ))
  })

  test("a tool that needs nothing runs", async () => {
    expect((await CliArgs.observe(PrepareAccounts.cli, [])).reachedMain)->toBe(true)
    expect((await CliArgs.observe(CheckLifecycleModel.cli, [])).reachedMain)->toBe(true)
  })
})

describe("the trait tools", () => {
  testSync("a required flag's value is never the next flag", () =>
    expect(CertifyTrait.parseArgs(["t", "--host", "--report", "r.json", "--out", "o"]))->toEqual(
      Error("--host needs a value"),
    )
  )

  testSync("flags may be given inline", () =>
    expect(TraitManifestCli.parseArgs(["t", "--out=m.yaml"]))->toEqual(
      Ok({TraitManifestCli.traitPackage: "t", out: "m.yaml"}),
    )
  )

  testSync("the trait package need not come first", () =>
    expect(TraitManifestCli.parseArgs(["--out", "m.yaml", "t"]))->toEqual(
      Ok({TraitManifestCli.traitPackage: "t", out: "m.yaml"}),
    )
  )

  testSync("a second trait package is refused", () =>
    expect(
      GraftTrait.parseArgs(["t", "u", "--into", "src", "--tests", "tests"])->Result.map(_ => ()),
    )->toEqual(Error(`unknown argument "u"`))
  )
})

describe("generate-plugin", () => {
  // Once silently ignored when it followed the source directory.
  testSync("--aws may follow the source directory", () =>
    expect(PluginGenerator.parseArgs(["../catalog/src/", "--aws", "CatalogPlugin"]))->toEqual(
      Ok({
        PluginGenerator.variant: Config.Aws({compositionNamespace: "CatalogPlugin"}),
        srcDir: "../catalog/src/",
      }),
    )
  )

  testSync("--aws needs a namespace, not the next argument's flag", () =>
    expect(PluginGenerator.parseArgs(["--aws", "--x", "src/"]))->toEqual(
      Error("--aws needs a value"),
    )
  )
})

describe("check-lifecycle", () => {
  // `--json` writes a document to stdout, so a usage mistake must stay off it.
  test("a usage mistake under --json writes nothing to stdout", async () => {
    let observed = await CliArgs.observe(CheckLifecycleModel.cli, ["--json", "--nope"])
    expect((observed.stdout, observed.exitCode))->toEqual(([], Some(2)))
  })

  testSync("--root=<dir> is accepted", () =>
    expect(CheckLifecycleModel.parseArgs(["--root=/app"])->Result.map(a => a.roots))->toEqual(
      Ok(["/app"]),
    )
  )
})

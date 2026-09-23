open JestGlobals

// How this package's five bins behave on the command line, as a person or a
// script meets them: help anywhere answers with the usage and exit 0, a usage
// mistake names itself and shows the usage on stderr with exit 2. Exit 1 is
// left to a run that failed, so a caller can tell the two apart.

module CliArgs = Reventless.CliArgs

let answersLikeEveryTool = (cli: CliArgs.cli<'args>, ~mistake, ~message) =>
  test(`${cli.bin}: --help and a usage mistake`, async () => {
    let usage = cli.usage->String.trim
    expect(usage->String.startsWith(`Usage: ${cli.bin} `))->toBe(true)
    let help = {CliArgs.stdout: [usage], stderr: [], exitCode: Some(0), reachedMain: false}
    expect(await CliArgs.observe(cli, ["-h"]))->toEqual(help)
    // Help wins: whoever asks what a tool takes is least sure of their arguments.
    expect(await CliArgs.observe(cli, mistake->Array.concat(["--help"])))->toEqual(help)
    expect(await CliArgs.observe(cli, mistake))->toEqual({
      CliArgs.stdout: [],
      stderr: [`${cli.bin}: ${message}\n\n${usage}`],
      exitCode: Some(2),
      reachedMain: false,
    })
  })

describe("every bin", () => {
  answersLikeEveryTool(
    DeployApp.cli,
    ~mistake=["up", "--stak", "x"],
    ~message=`unknown argument "--stak"`,
  )
  answersLikeEveryTool(
    BakeManifest.cli,
    ~mistake=["--stak", "x"],
    ~message=`unknown argument "--stak"`,
  )
  answersLikeEveryTool(
    ProvisionAccounts.cli,
    ~mistake=["--pool", "x"],
    ~message=`unknown argument "--pool"`,
  )
  answersLikeEveryTool(
    ProvisionAdmin.cli,
    ~mistake=["--email", "me@example.com", "stray"],
    ~message=`unknown argument "stray"`,
  )
  answersLikeEveryTool(
    ProvisionIdentity.cli,
    ~mistake=["--provider_id", "x"],
    ~message=`unknown argument "--provider_id"`,
  )
})

describe("a string flag's value", () => {
  // Read literally, `--manifest --stack try` deploys with the manifest
  // "--stack". Nobody who typed it meant that.
  testSync("is never the next flag", () =>
    expect(DeployApp.parseArgs(["up", "--manifest", "--stack", "try"]))->toEqual(
      Error("--manifest needs a value"),
    )
  )

  testSync("may be given inline", () =>
    expect(DeployApp.parseArgs(["down", "--manifest=../m.yaml", "--stack=try"]))->toEqual(
      Ok({DeployApp.command: Some(Down), manifest: Some("../m.yaml"), stack: "try", help: false}),
    )
  )

  testSync("--since may be empty inline, as CI can pass it", () =>
    expect(BakeManifest.parseArgs(["--since="])->Result.map(a => a.since))->toEqual(Ok(None))
  )
})

describe("a bare invocation", () => {
  test("deploy-app has to be told up or down", async () => {
    let observed = await CliArgs.observe(DeployApp.cli, [])
    expect((
      observed.exitCode,
      observed.stderr->Array.get(0)->Option.map(e => e->String.split("\n")->Array.getUnsafe(0)),
    ))->toEqual((Some(2), Some("deploy-app: say `up` or `down`")))
  })

  test("provision-admin has to be told whom to make", async () => {
    let observed = await CliArgs.observe(ProvisionAdmin.cli, [])
    expect(observed.exitCode)->toEqual(Some(2))
    expect(observed.stderr->Array.join("")->String.includes("--email is required"))->toBe(true)
  })

  test("the tools that need nothing run", async () => {
    expect((await CliArgs.observe(BakeManifest.cli, [])).reachedMain)->toBe(true)
    expect((await CliArgs.observe(ProvisionAccounts.cli, [])).reachedMain)->toBe(true)
    expect((await CliArgs.observe(ProvisionIdentity.cli, [])).reachedMain)->toBe(true)
  })
})

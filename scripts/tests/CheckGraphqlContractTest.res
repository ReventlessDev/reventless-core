open JestGlobals

describe("CheckGraphqlContract.parseArgs", () => {
  testSync("no arguments checks for drift", () =>
    expect(CheckGraphqlContract.parseArgs([]))->toEqual(Ok({CheckGraphqlContract.update: false}))
  )

  testSync("--update rewrites the goldens", () =>
    expect(CheckGraphqlContract.parseArgs(["--update"]))->toEqual(
      Ok({CheckGraphqlContract.update: true}),
    )
  )
})

describe("check:graphql on the command line", () => {
  module CliArgs = Reventless.CliArgs
  let usage = CheckGraphqlContract.usage->String.trim

  test("--help prints the usage to stdout and exits 0, before booting anything", async () =>
    expect(await CliArgs.observe(CheckGraphqlContract.cli, ["--update", "-h"]))->toEqual({
      CliArgs.stdout: [usage],
      stderr: [],
      exitCode: Some(0),
      reachedMain: false,
    })
  )

  // Once ignored: `--updtae` ran a check and reported drift instead of writing.
  test("a usage mistake names itself, shows the usage on stderr and exits 2", async () =>
    expect(await CliArgs.observe(CheckGraphqlContract.cli, ["--updtae"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [`check:graphql: unknown argument "--updtae"\n\n${usage}`],
      exitCode: Some(2),
      reachedMain: false,
    })
  )
})

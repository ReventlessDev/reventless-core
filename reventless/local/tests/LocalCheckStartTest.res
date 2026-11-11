open JestGlobals

// `check-start [<mainModule>]` runs an app's start in check mode: everything is built the way a
// start builds it, and nothing is served.

/** Runs `f` with `key` set to `value` (or unset), and puts the environment back. */
let withEnv = (key: string, value: option<string>, f: unit => 'a): 'a => {
  let previous = NodeProcess.env->Dict.get(key)
  switch value {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
  let restore = () =>
    switch previous {
    | Some(v) => NodeProcess.env->Dict.set(key, v)
    | None => NodeProcess.env->Dict.delete(key)
    }
  switch f() {
  | result =>
    restore()
    result
  | exception e =>
    restore()
    throw(e)
  }
}

describe("LocalCheckStart.active", () => {
  testSync("is off unless the variable says otherwise", () => {
    expect(LocalCheckStart.active(~env=Dict.make(), ()))->toBe(false)
    expect(LocalCheckStart.active(~env=Dict.fromArray([(LocalCheckStart.envVar, " ")]), ()))->toBe(
      false,
    )
    expect(LocalCheckStart.active(~env=Dict.fromArray([(LocalCheckStart.envVar, "1")]), ()))->toBe(
      true,
    )
  })
})

describe("LocalCheckStart.enterCheckMode", () => {
  testSync("checks in memory and quietly, keeping a log level the caller chose", () => {
    let env = Dict.fromArray([
      ("REVENTLESS_LOCAL_BACKEND", "sqlite:./local.db"),
      ("LOG_LEVEL", "debug"),
    ])
    LocalCheckStart.enterCheckMode(~env, ())
    expect(env->Dict.get(LocalCheckStart.envVar))->toEqual(Some("1"))
    expect(env->Dict.get("REVENTLESS_LOCAL_BACKEND"))->toEqual(Some("memory"))
    expect(env->Dict.get("LOG_LEVEL"))->toEqual(Some("debug"))

    let quiet = Dict.make()
    LocalCheckStart.enterCheckMode(~env=quiet, ())
    expect(quiet->Dict.get("LOG_LEVEL"))->toEqual(Some("warn"))
  })
})

describe("LocalCheckStart.mainModulePath", () => {
  testSync("is the conventional start module unless one is named", () => {
    expect(LocalCheckStart.mainModulePath(~mainModule=None))->toBe(
      NodePath.resolve(["src", "Main.res.mjs"]),
    )
    expect(LocalCheckStart.mainModulePath(~mainModule=Some("lib/Start.res.mjs")))->toBe(
      NodePath.resolve(["lib/Start.res.mjs"]),
    )
  })
})

describe("LocalPlatformStart.orAddressRunning in check mode", () => {
  // Addressing a running platform exits 0, which would report a start nobody checked.
  testSync("goes on although a platform is running in the directory", () => {
    let cwd = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-check-"]))
    let _ = LocalPlatformRegistry.write(
      ~port=4000,
      ~endpoint="http://localhost:4000/graphql",
      ~loginEndpoint="http://localhost:4000/__inmemory/login",
      ~store={kind: "memory"},
      ~pid=NodeProcess.pid,
      ~cwd,
    )
    let returned = withEnv(
      LocalPlatformStart.bypassEnv,
      None,
      () =>
        withEnv(
          LocalCheckStart.envVar,
          Some("1"),
          () => {
            LocalPlatformStart.orAddressRunning(~cwd, ())
            true
          },
        ),
    )
    expect(returned)->toBe(true)
  })
})

describe("check-start on the command line", () => {
  module CliArgs = Reventless.CliArgs
  let usage = LocalCheckStart.usage->String.trim

  testSync("names the start module, or takes the conventional one", () => {
    expect(LocalCheckStart.parseArgs([]))->toEqual(Ok(({}: LocalCheckStart.args)))
    expect(LocalCheckStart.parseArgs(["lib/Start.res.mjs"]))->toEqual(
      Ok({LocalCheckStart.mainModule: "lib/Start.res.mjs"}),
    )
  })

  test("a second argument is a usage mistake, exit 2", async () =>
    expect(await CliArgs.observe(LocalCheckStart.cli, ["a", "b"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [`check-start: unknown argument "b"\n\n${usage}`],
      exitCode: 2,
      reachedMain: false,
    })
  )
})

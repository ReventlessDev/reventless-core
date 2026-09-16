open JestGlobals

// What `deploy-app` decides without AWS or Pulumi: its arguments, the checks
// that stop it before anything is created, and what a new stack starts with.

describe("DeployApp.parseArgs", () => {
  testSync("up with the defaults", () =>
    expect(DeployApp.parseArgs(["up"]))->toEqual(
      Ok({DeployApp.command: Some(Up), manifest: None, stack: "dev", help: false}),
    )
  )

  testSync("down with a manifest and a stack", () =>
    expect(DeployApp.parseArgs(["down", "--manifest", "../m.yaml", "--stack", "try"]))->toEqual(
      Ok({DeployApp.command: Some(Down), manifest: Some("../m.yaml"), stack: "try", help: false}),
    )
  )

  testSync("a second command is refused", () =>
    expect(DeployApp.parseArgs(["up", "down"]))->toEqual(Error(`unknown argument "down"`))
  )
})

describe("DeployApp checks", () => {
  testSync("Node 22 and later pass", () => {
    expect(DeployApp.checkNode("22.17.1"))->toEqual(None)
    expect(DeployApp.checkNode("24.0.0"))->toEqual(None)
  })

  testSync("an older Node says which version is needed", () =>
    expect(DeployApp.checkNode("20.11.0")->Option.getOr(""))->toContain("Node 22 or later")
  )

  testSync("Pulumi Cloud needs no passphrase", () =>
    expect(
      DeployApp.backendNeedsPassphrase(~url=Some("https://app.pulumi.com/me"), ~env=Dict.make()),
    )->toBe(false)
  )

  testSync("a local backend needs one, unless it is set", () => {
    expect(DeployApp.backendNeedsPassphrase(~url=Some("file://~"), ~env=Dict.make()))->toBe(true)
    expect(
      DeployApp.backendNeedsPassphrase(
        ~url=Some("s3://bucket"),
        ~env=Dict.fromArray([("PULUMI_CONFIG_PASSPHRASE", "")]),
      ),
    )->toBe(false)
  })
})

describe("DeployApp stacks and layer", () => {
  let project = {
    DeployApp.label: "platform",
    dir: "/app/platform-aws",
    projectName: "shop-platform-aws",
    program: "/app/platform-aws/src/Main.res.mjs",
    stackDefaults: Dict.fromArray([("aws:region", "us-east-1"), ("platform:x", "y")]),
  }

  // The region and the try-out flag come last, so an app default cannot turn a
  // try-out into a stack `down` refuses to remove.
  testSync("a new stack gets the app's defaults, then the region and the try-out flag", () =>
    expect(DeployApp.newStackConfig(~project, ~region="eu-west-1"))->toEqual([
      ("aws:region", "us-east-1"),
      ("platform:x", "y"),
      ("aws:region", "eu-west-1"),
      ("aws-native:region", "eu-west-1"),
      ("reventless:disposable", "true"),
    ])
  )

  testSync("the release download is named by the package and version", () =>
    expect(DeployApp.releaseUrl("3.0.0-alpha.346"))->toBe(
      "https://github.com/ReventlessDev/reventless-core/releases/download/%40reventlessdev%2Freventless-aws%403.0.0-alpha.346/reventless-layer.zip",
    )
  )

  testSync("a layer is marked with the release it was published for", () =>
    expect(DeployApp.layerDescription("3.0.0"))->toBe("reventless-aws@3.0.0")
  )

  testSync("sign-ins line up under each other", () =>
    expect(
      DeployApp.signInLines([
        {username: "admin@example.com", password: "", groups: ["Admin"]},
        {username: "a@example.com", password: "", groups: []},
      ]),
    )->toEqual(["    admin@example.com  [Admin]", "    a@example.com      []"])
  )
})
